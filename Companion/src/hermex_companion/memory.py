"""Safe management of Hermes Agent's built-in MEMORY.md and USER.md."""

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
from typing import Iterator
from uuid import uuid4

from hermex_companion.memory_threats import first_threat

try:
    import fcntl
except ImportError:  # pragma: no cover - Companion's supported host is Linux.
    fcntl = None


ENTRY_DELIMITER = "\n§\n"
DEFAULT_MEMORY_CHAR_LIMIT = 2200
DEFAULT_USER_CHAR_LIMIT = 1375
MAX_MEMORY_OPERATIONS = 50
MAX_MEMORY_FILE_BYTES = 4 * 1_000_000


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
        self._directory_identity: tuple[int, int] | None = None
        if directory is not None:
            if not directory.is_absolute():
                raise ValueError("memory directory must be absolute")
            canonical = directory.resolve(strict=True)
            if not canonical.is_dir():
                raise ValueError("memory directory must be an existing directory")
            self._directory = canonical
            metadata = canonical.stat()
            self._directory_identity = (metadata.st_dev, metadata.st_ino)
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
        filename = self._filename(target)
        with self._file_lock(filename) as directory_fd:
            raw = self._read_raw(directory_fd, filename)
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
        filename = self._filename(target)
        with self._file_lock(filename) as directory_fd:
            raw = self._read_raw(directory_fd, filename)
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
            self._atomic_write(directory_fd, filename, serialized)
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
        filename = self._filename(target)
        with self._file_lock(filename) as directory_fd:
            snapshot = self._snapshot(
                target,
                self._read_raw(directory_fd, filename),
            )
            self._require_revision(snapshot, revision)
            self._atomic_write(directory_fd, filename, "")
            return self._snapshot(target, "")

    def _filename(self, target: str) -> str:
        if self._directory is None:
            raise MemoryError(
                409,
                "memory_not_configured",
                "The Hermes Agent host has not enabled built-in Memory access.",
            )
        if target == "memory":
            return "MEMORY.md"
        if target == "user":
            return "USER.md"
        raise MemoryError(
            404,
            "memory_target_not_found",
            "Only built-in MEMORY.md and USER.md are available.",
        )

    def _validated_directory_fd(self) -> int:
        if self._directory is None or self._directory_identity is None:
            raise MemoryError(
                409,
                "memory_not_configured",
                "The Hermes Agent host has not enabled built-in Memory access.",
            )
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor: int | None = None
        try:
            descriptor = os.open(self._directory, flags)
            metadata = os.fstat(descriptor)
        except OSError as error:
            if descriptor is not None:
                os.close(descriptor)
            raise MemoryError(
                409,
                "memory_directory_changed",
                "The built-in Memory directory is no longer available safely.",
            ) from error
        if (metadata.st_dev, metadata.st_ino) != self._directory_identity:
            os.close(descriptor)
            raise MemoryError(
                409,
                "memory_directory_changed",
                "The built-in Memory directory changed after Companion started.",
            )
        return descriptor

    @staticmethod
    def _read_raw(directory_fd: int, filename: str) -> str:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(filename, flags, dir_fd=directory_fd)
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
            if metadata.st_size > MAX_MEMORY_FILE_BYTES:
                raise MemoryError(
                    409,
                    "memory_file_too_large",
                    "The built-in Memory file exceeds the safe read limit.",
                )
            with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
                descriptor = -1
                content = handle.read(MAX_MEMORY_FILE_BYTES + 1)
                if len(content.encode("utf-8")) > MAX_MEMORY_FILE_BYTES:
                    raise MemoryError(
                        409,
                        "memory_file_too_large",
                        "The built-in Memory file exceeds the safe read limit.",
                    )
                return content
        except MemoryError:
            raise
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

    @contextmanager
    def _file_lock(self, filename: str) -> Iterator[int]:
        directory_fd = self._validated_directory_fd()
        lock_name = f"{filename}.lock"
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        descriptor: int | None = None
        try:
            descriptor = os.open(
                lock_name,
                flags,
                0o600,
                dir_fd=directory_fd,
            )
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise OSError("Memory lock is not a regular file")
        except OSError as error:
            if descriptor is not None:
                os.close(descriptor)
            os.close(directory_fd)
            raise MemoryError(
                409,
                "memory_lock_unsafe",
                "The built-in Memory lock could not be opened safely.",
            ) from error
        with os.fdopen(descriptor, "a+", encoding="utf-8") as handle:
            locked = False
            try:
                if fcntl is not None:
                    fcntl.flock(handle, fcntl.LOCK_EX)
                    locked = True
                yield directory_fd
            finally:
                if fcntl is not None and locked:
                    fcntl.flock(handle, fcntl.LOCK_UN)
                os.close(directory_fd)

    @staticmethod
    def _atomic_write(
        directory_fd: int,
        filename: str,
        content: str,
    ) -> None:
        temporary = f".hermes-nest-memory-{uuid4().hex}.tmp"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(
            temporary,
            flags,
            0o600,
            dir_fd=directory_fd,
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(
                temporary,
                filename,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            os.fsync(directory_fd)
        except BaseException:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            raise
