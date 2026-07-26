"""Safe management of Hermes Agent's built-in MEMORY.md and USER.md."""

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from typing import Iterator

from hermex_companion.memory_threats import first_threat

try:
    import fcntl
except ImportError:  # pragma: no cover - Companion's supported host is Linux.
    fcntl = None


ENTRY_DELIMITER = "\n§\n"
DEFAULT_MEMORY_CHAR_LIMIT = 2200
DEFAULT_USER_CHAR_LIMIT = 1375
MAX_MEMORY_OPERATIONS = 50


class MemoryError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True, slots=True)
class MemorySnapshot:
    target: str
    entries: tuple[str, ...]
    revision: str
    char_count: int
    char_limit: int

    def public_payload(self) -> dict[str, object]:
        return {
            "target": self.target,
            "entries": list(self.entries),
            "revision": self.revision,
            "char_count": self.char_count,
            "char_limit": self.char_limit,
        }


class MemoryAccess:
    def __init__(
        self,
        directory: Path | None = None,
        *,
        memory_char_limit: int = DEFAULT_MEMORY_CHAR_LIMIT,
        user_char_limit: int = DEFAULT_USER_CHAR_LIMIT,
    ) -> None:
        self._directory: Path | None = None
        if directory is not None:
            if not directory.is_absolute():
                raise ValueError("memory directory must be absolute")
            canonical = directory.resolve(strict=True)
            if not canonical.is_dir():
                raise ValueError("memory directory must be an existing directory")
            self._directory = canonical
        for name, value in (
            ("memory_char_limit", memory_char_limit),
            ("user_char_limit", user_char_limit),
        ):
            if type(value) is not int or not 1 <= value <= 1_000_000:
                raise ValueError(f"{name} must be an integer from 1 to 1000000")
        self._limits = {
            "memory": memory_char_limit,
            "user": user_char_limit,
        }

    @classmethod
    def from_config_file(cls, path: Path) -> "MemoryAccess":
        if not path.exists():
            return cls()
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("workspace configuration must be a JSON object")
        memory = payload.get("memory")
        if memory is None:
            return cls()
        if not isinstance(memory, dict):
            raise ValueError("memory configuration must be a JSON object")
        directory = memory.get("directory")
        if not isinstance(directory, str) or not directory:
            raise ValueError("memory directory must be a non-empty absolute path")
        return cls(
            Path(directory),
            memory_char_limit=memory.get(
                "memory_char_limit",
                DEFAULT_MEMORY_CHAR_LIMIT,
            ),
            user_char_limit=memory.get(
                "user_char_limit",
                DEFAULT_USER_CHAR_LIMIT,
            ),
        )

    @property
    def configured(self) -> bool:
        return self._directory is not None

    def read(self, target: str) -> MemorySnapshot:
        path = self._path(target)
        with self._file_lock(path):
            raw = self._read_raw(path)
            return self._snapshot(target, raw)

    def apply_operations(
        self,
        target: str,
        *,
        revision: object,
        operations: object,
    ) -> MemorySnapshot:
        if not isinstance(revision, str) or len(revision) != 64:
            raise MemoryError(
                400,
                "invalid_memory_revision",
                "A current Memory revision is required.",
            )
        if (
            not isinstance(operations, list)
            or not 1 <= len(operations) <= MAX_MEMORY_OPERATIONS
        ):
            raise MemoryError(
                400,
                "invalid_memory_operations",
                f"operations must contain 1 to {MAX_MEMORY_OPERATIONS} items.",
            )
        path = self._path(target)
        with self._file_lock(path):
            raw = self._read_raw(path)
            snapshot = self._snapshot(target, raw)
            self._require_revision(snapshot, revision)
            entries = list(dict.fromkeys(snapshot.entries))
            self._require_roundtrip(target, raw, entries)
            working = list(entries)
            for index, raw_operation in enumerate(operations):
                if not isinstance(raw_operation, dict):
                    raise self._operation_error(index, "must be an object")
                action = raw_operation.get("action")
                content = raw_operation.get("content")
                old_text = raw_operation.get("old_text")
                if action == "add":
                    normalized = self._validated_content(index, content)
                    if normalized not in working:
                        working.append(normalized)
                elif action == "replace":
                    needle = self._validated_old_text(index, old_text)
                    normalized = self._validated_content(index, content)
                    match = self._unique_match(index, working, needle)
                    working[match] = normalized
                elif action == "remove":
                    needle = self._validated_old_text(index, old_text)
                    match = self._unique_match(index, working, needle)
                    working.pop(match)
                else:
                    raise self._operation_error(
                        index,
                        "action must be add, replace, or remove",
                    )
            serialized = ENTRY_DELIMITER.join(working)
            if len(serialized) > self._limits[target]:
                raise MemoryError(
                    409,
                    "memory_limit_exceeded",
                    "The requested changes exceed the configured Memory limit.",
                )
            self._atomic_write(path, serialized)
            return self._snapshot(target, serialized)

    def reset(
        self,
        target: str,
        *,
        revision: object,
        confirmation: object,
    ) -> MemorySnapshot:
        expected = f"RESET {target.upper()}"
        if confirmation != expected:
            raise MemoryError(
                400,
                "memory_reset_confirmation_required",
                f"Confirmation must exactly match {expected}.",
            )
        if not isinstance(revision, str) or len(revision) != 64:
            raise MemoryError(
                400,
                "invalid_memory_revision",
                "A current Memory revision is required.",
            )
        path = self._path(target)
        with self._file_lock(path):
            snapshot = self._snapshot(target, self._read_raw(path))
            self._require_revision(snapshot, revision)
            self._atomic_write(path, "")
            return self._snapshot(target, "")

    def _path(self, target: str) -> Path:
        if self._directory is None:
            raise MemoryError(
                409,
                "memory_not_configured",
                "The Hermes Agent host has not enabled built-in Memory access.",
            )
        if target == "memory":
            return self._directory / "MEMORY.md"
        if target == "user":
            return self._directory / "USER.md"
        raise MemoryError(
            404,
            "memory_target_not_found",
            "Only built-in MEMORY.md and USER.md are available.",
        )

    @staticmethod
    def _read_raw(path: Path) -> str:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except FileNotFoundError:
            return ""
        except OSError as error:
            raise MemoryError(
                409,
                "memory_unreadable",
                "The built-in Memory file could not be read safely.",
            ) from error
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise OSError("Memory target is not a regular file")
            with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
                descriptor = -1
                return handle.read()
        except (OSError, UnicodeDecodeError) as error:
            raise MemoryError(
                409,
                "memory_unreadable",
                "The built-in Memory file could not be read safely.",
            ) from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _snapshot(self, target: str, raw: str) -> MemorySnapshot:
        entries = tuple(
            entry.strip()
            for entry in raw.split(ENTRY_DELIMITER)
            if entry.strip()
        )
        return MemorySnapshot(
            target=target,
            entries=entries,
            revision=hashlib.sha256(raw.encode("utf-8")).hexdigest(),
            char_count=len(ENTRY_DELIMITER.join(entries)) if entries else 0,
            char_limit=self._limits[target],
        )

    @staticmethod
    def _require_revision(snapshot: MemorySnapshot, revision: str) -> None:
        if snapshot.revision != revision:
            raise MemoryError(
                409,
                "memory_revision_conflict",
                "Memory changed on the server. Refresh before saving again.",
            )

    def _require_roundtrip(
        self,
        target: str,
        raw: str,
        entries: list[str],
    ) -> None:
        if (
            raw.strip() != ENTRY_DELIMITER.join(entries)
            or any(len(entry) > self._limits[target] for entry in entries)
        ):
            raise MemoryError(
                409,
                "memory_external_drift",
                "The Memory file contains external edits that cannot be safely rewritten.",
            )

    @staticmethod
    def _operation_error(index: int, detail: str) -> MemoryError:
        return MemoryError(
            400,
            "invalid_memory_operation",
            f"Operation {index + 1} {detail}.",
        )

    def _validated_content(self, index: int, value: object) -> str:
        if not isinstance(value, str) or not value.strip():
            raise self._operation_error(index, "requires non-empty content")
        content = value.strip()
        threat = first_threat(content)
        if threat is not None:
            raise MemoryError(
                400,
                "unsafe_memory_content",
                f"Memory content was rejected by the strict safety scanner ({threat}).",
            )
        return content

    def _validated_old_text(self, index: int, value: object) -> str:
        if not isinstance(value, str) or not value.strip():
            raise self._operation_error(index, "requires non-empty old_text")
        return value.strip()

    def _unique_match(
        self,
        index: int,
        entries: list[str],
        old_text: str,
    ) -> int:
        matches = [position for position, entry in enumerate(entries) if old_text in entry]
        if not matches:
            raise self._operation_error(index, "did not match an entry")
        if len({entries[position] for position in matches}) > 1:
            raise self._operation_error(index, "matched multiple entries")
        return matches[0]

    @staticmethod
    @contextmanager
    def _file_lock(path: Path) -> Iterator[None]:
        lock_path = path.with_suffix(path.suffix + ".lock")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(lock_path, flags, 0o600)
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise OSError("Memory lock is not a regular file")
        except OSError as error:
            raise MemoryError(
                409,
                "memory_lock_unsafe",
                "The built-in Memory lock could not be opened safely.",
            ) from error
        with os.fdopen(descriptor, "a+", encoding="utf-8") as handle:
            if fcntl is not None:
                fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                if fcntl is not None:
                    fcntl.flock(handle, fcntl.LOCK_UN)

    @staticmethod
    def _atomic_write(path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            dir=path.parent,
            prefix=".hermes-nest-memory-",
            suffix=".tmp",
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
