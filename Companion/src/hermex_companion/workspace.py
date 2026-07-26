"""Server-authorized workspace roots exposed through safe App aliases."""

from dataclasses import dataclass
import json
import mimetypes
import os
from pathlib import Path
import re
import stat
from typing import BinaryIO, Iterable
from uuid import uuid4


_ROOT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
MAX_WORKSPACE_ROOTS = 32
_SENSITIVE_ENTRY_NAMES = frozenset(
    {
        ".env",
        ".netrc",
        ".npmrc",
        ".pgpass",
        ".pypirc",
        "authorized_keys",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "id_rsa",
    }
)
_SENSITIVE_DIRECTORY_NAMES = frozenset(
    {
        ".hermes-nest-attachments",
        ".aws",
        ".gnupg",
        ".hermes",
        ".kube",
        ".ssh",
    }
)
DEFAULT_DIRECTORY_PAGE_SIZE = 100
MAX_DIRECTORY_PAGE_SIZE = 200
MAX_PREVIEW_BYTES = 256 * 1024
MAX_UPLOAD_BYTES = 50 * 1024 * 1024
_UPLOAD_TEMP_PREFIX = ".hermes-nest-upload-"
_ATTACHMENT_DIRECTORY_NAME = ".hermes-nest-attachments"


def content_type_for_filename(filename: str) -> str:
    """Derive display metadata locally instead of trusting multipart headers."""
    return mimetypes.guess_type(filename)[0] or "application/octet-stream"


def _is_sensitive_entry(path: Path) -> bool:
    lowered = path.name.casefold()
    return (
        lowered.startswith(_UPLOAD_TEMP_PREFIX)
        or
        lowered in _SENSITIVE_ENTRY_NAMES
        or lowered in _SENSITIVE_DIRECTORY_NAMES
    )


def _has_sensitive_component(
    path: Path,
    *,
    allow_attachment_storage: bool = False,
) -> bool:
    return any(
        _is_sensitive_entry(Path(part))
        and not (
            allow_attachment_storage
            and part.casefold() == _ATTACHMENT_DIRECTORY_NAME
        )
        for part in path.parts
        if part not in {"", "."}
    )


class WorkspaceError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class WorkspaceUpload:
    def __init__(
        self,
        *,
        root_id: str,
        root_path: Path,
        directory: Path,
        filename: str,
    ) -> None:
        self.root_id = root_id
        self.name = filename
        relative_directory = directory.relative_to(root_path)
        safe_suffix = Path(filename).suffix
        if (
            len(safe_suffix) > 16
            or re.fullmatch(r"\.[A-Za-z0-9]+", safe_suffix) is None
        ):
            safe_suffix = ""
        self._storage_name = f"{uuid4().hex}{safe_suffix.lower()}"
        self.relative_path = (
            relative_directory
            / _ATTACHMENT_DIRECTORY_NAME
            / self._storage_name
        ).as_posix()
        flags = os.O_RDONLY
        flags |= getattr(os, "O_DIRECTORY", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        selected_directory_fd = os.open(directory, flags)
        try:
            try:
                os.mkdir(
                    _ATTACHMENT_DIRECTORY_NAME,
                    0o700,
                    dir_fd=selected_directory_fd,
                )
            except FileExistsError:
                pass
            attachment_metadata = os.stat(
                _ATTACHMENT_DIRECTORY_NAME,
                dir_fd=selected_directory_fd,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(attachment_metadata.st_mode):
                raise WorkspaceError(
                    409,
                    "attachment_storage_unsafe",
                    "The attachment storage directory is not safe.",
                )
            self._directory_fd = os.open(
                _ATTACHMENT_DIRECTORY_NAME,
                flags,
                dir_fd=selected_directory_fd,
            )
        finally:
            os.close(selected_directory_fd)
        self._temp_name = f"{_UPLOAD_TEMP_PREFIX}{uuid4().hex}.part"
        self._file: BinaryIO | None = None
        self._published = False
        self.published_device: int | None = None
        self.published_inode: int | None = None
        try:
            try:
                os.stat(
                    self._storage_name,
                    dir_fd=self._directory_fd,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            else:
                raise WorkspaceError(
                    409,
                    "upload_collision",
                    "A file with that name already exists.",
                )
            file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            file_flags |= getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(
                self._temp_name,
                file_flags,
                0o600,
                dir_fd=self._directory_fd,
            )
            self._file = os.fdopen(fd, "wb", buffering=0)
        except Exception:
            os.close(self._directory_fd)
            raise

    def write(self, chunk: bytes) -> None:
        if self._file is None:
            raise RuntimeError("upload is closed")
        self._file.write(chunk)

    def commit(self) -> None:
        if self._file is None:
            raise RuntimeError("upload is closed")
        self._file.flush()
        os.fsync(self._file.fileno())
        self._file.close()
        self._file = None
        try:
            os.link(
                self._temp_name,
                self._storage_name,
                src_dir_fd=self._directory_fd,
                dst_dir_fd=self._directory_fd,
                follow_symlinks=False,
            )
        except FileExistsError:
            raise WorkspaceError(
                409,
                "upload_collision",
                "A file with that name already exists.",
            ) from None
        os.unlink(self._temp_name, dir_fd=self._directory_fd)
        metadata = os.stat(
            self._storage_name,
            dir_fd=self._directory_fd,
            follow_symlinks=False,
        )
        self.published_device = metadata.st_dev
        self.published_inode = metadata.st_ino
        os.fsync(self._directory_fd)
        self._published = True
        os.close(self._directory_fd)

    def abort(self) -> None:
        if self._file is not None:
            self._file.close()
            self._file = None
        if not self._published:
            try:
                os.unlink(self._temp_name, dir_fd=self._directory_fd)
            except FileNotFoundError:
                pass
        try:
            os.close(self._directory_fd)
        except OSError:
            pass


@dataclass(frozen=True, slots=True)
class WorkspaceRoot:
    id: str
    name: str
    path: Path
    writable: bool = False

    def __post_init__(self) -> None:
        if not self.path.is_absolute():
            raise ValueError("workspace root paths must be absolute")

    def public_payload(self, *, attachable: bool) -> dict[str, object]:
        return {
            "id": self.id,
            "name": self.name,
            "writable": self.writable,
            "attachable": attachable,
        }


class WorkspaceAccess:
    def __init__(
        self,
        roots: Iterable[WorkspaceRoot] = (),
        *,
        agent_working_directory: Path | None = None,
    ) -> None:
        configured_roots = tuple(roots)
        if len(configured_roots) > MAX_WORKSPACE_ROOTS:
            raise ValueError(
                f"at most {MAX_WORKSPACE_ROOTS} workspace roots may be configured"
            )
        seen_ids: set[str] = set()
        canonical_roots: list[WorkspaceRoot] = []
        root_identities: dict[str, tuple[int, int]] = {}
        for root in configured_roots:
            if not _ROOT_ID_PATTERN.fullmatch(root.id):
                raise ValueError("workspace root IDs must be safe lowercase aliases")
            if root.id in seen_ids:
                raise ValueError("workspace root IDs must be unique")
            seen_ids.add(root.id)
            if (
                not root.name
                or len(root.name) > 80
                or any(ord(character) < 32 for character in root.name)
            ):
                raise ValueError("workspace root names must be 1 to 80 safe characters")
            if type(root.writable) is not bool:
                raise ValueError("workspace root writable must be a boolean")
            canonical_root = root.path.resolve(strict=True)
            if not canonical_root.is_dir():
                raise ValueError("workspace root paths must be existing directories")
            metadata = canonical_root.stat()
            canonical_roots.append(
                WorkspaceRoot(
                    id=root.id,
                    name=root.name,
                    path=canonical_root,
                    writable=root.writable,
                )
            )
            root_identities[root.id] = (metadata.st_dev, metadata.st_ino)
        self._roots = tuple(canonical_roots)
        self._root_identities = root_identities
        self._agent_working_directory = (
            agent_working_directory.resolve(strict=True)
            if agent_working_directory is not None
            else None
        )
        if (
            self._agent_working_directory is not None
            and not self._agent_working_directory.is_dir()
        ):
            raise ValueError("agent working directory must be an existing directory")

    @classmethod
    def from_config_file(cls, path: Path) -> "WorkspaceAccess":
        if not path.exists():
            return cls()
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("workspace configuration must be a JSON object")
        raw_roots = payload.get("roots", [])
        if not isinstance(raw_roots, list):
            raise ValueError("workspace configuration roots must be a list")
        roots = []
        for item in raw_roots:
            if not isinstance(item, dict):
                raise ValueError("each workspace root must be a JSON object")
            root_id = item.get("id")
            name = item.get("name")
            raw_path = item.get("path")
            writable = item.get("writable", False)
            if (
                not isinstance(root_id, str)
                or not isinstance(name, str)
                or not isinstance(raw_path, str)
                or type(writable) is not bool
            ):
                raise ValueError(
                    "workspace root id, name, path, and writable fields are invalid"
                )
            roots.append(
                WorkspaceRoot(
                    id=root_id,
                    name=name,
                    path=Path(raw_path),
                    writable=writable,
                )
            )
        raw_agent_directory = payload.get("agent_working_directory")
        if raw_agent_directory is not None and (
            not isinstance(raw_agent_directory, str)
            or not raw_agent_directory
        ):
            raise ValueError(
                "agent working directory must be a non-empty absolute path"
            )
        agent_directory = (
            Path(raw_agent_directory)
            if raw_agent_directory is not None
            else None
        )
        if agent_directory is not None and not agent_directory.is_absolute():
            raise ValueError("agent working directory must be absolute")
        return cls(roots, agent_working_directory=agent_directory)

    def public_roots(self) -> list[dict[str, object]]:
        payloads = []
        for root in self._roots:
            root_path = self._validated_root_path(root)
            attachable = False
            if self._agent_working_directory is not None:
                attachable = (
                    root_path == self._agent_working_directory
                    or self._agent_working_directory in root_path.parents
                )
            payloads.append(root.public_payload(attachable=attachable))
        return payloads

    def _validated_root_path(self, root: WorkspaceRoot) -> Path:
        try:
            root_path = root.path.resolve(strict=True)
            metadata = root_path.stat()
        except OSError as error:
            raise WorkspaceError(
                409,
                "workspace_root_changed",
                "The authorized workspace root is no longer available.",
            ) from error
        if (metadata.st_dev, metadata.st_ino) != self._root_identities[root.id]:
            raise WorkspaceError(
                409,
                "workspace_root_changed",
                "The authorized workspace root changed after Companion started.",
            )
        return root_path

    def agent_reference(self, root_id: str, relative_path: str) -> str:
        if self._agent_working_directory is None:
            raise WorkspaceError(
                409,
                "attachment_agent_path_unavailable",
                "The server has not configured an Agent working directory.",
            )
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None:
            raise WorkspaceError(
                404,
                "workspace_root_not_found",
                "The requested workspace root is not authorized.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_path)
        if (
            not relative_path
            or requested.is_absolute()
            or _has_sensitive_component(
                requested,
                allow_attachment_storage=True,
            )
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        path = (root_path / requested).resolve(strict=True)
        if path != root_path and root_path not in path.parents:
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        if not stat.S_ISREG(path.stat().st_mode):
            raise WorkspaceError(
                400,
                "workspace_file_required",
                "Attachments require a regular file.",
            )
        try:
            relative = path.relative_to(self._agent_working_directory)
        except ValueError:
            raise WorkspaceError(
                409,
                "attachment_agent_path_unavailable",
                "The selected root is outside the configured Agent working directory.",
            ) from None
        return relative.as_posix()

    def preview_file(
        self,
        root_id: str,
        relative_path: str,
    ) -> dict[str, object]:
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None:
            raise WorkspaceError(
                404,
                "workspace_root_not_found",
                "The requested workspace root is not authorized.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_path)
        if (
            not relative_path
            or requested.is_absolute()
            or _has_sensitive_component(requested)
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        path = (root_path / requested).resolve(strict=True)
        if path != root_path and root_path not in path.parents:
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise WorkspaceError(
                400,
                "workspace_file_required",
                "File preview requires a regular file.",
            )
        with path.open("rb") as handle:
            raw = handle.read(MAX_PREVIEW_BYTES + 1)
        truncated = len(raw) > MAX_PREVIEW_BYTES
        preview = raw[:MAX_PREVIEW_BYTES]
        content_type = content_type_for_filename(path.name)
        try:
            content = preview.decode("utf-8")
        except UnicodeDecodeError:
            content = None
        return {
            "root_id": root.id,
            "path": path.relative_to(root_path).as_posix(),
            "name": path.name,
            "kind": "text" if content is not None else "binary",
            "content_type": content_type,
            "size": metadata.st_size,
            "truncated": truncated,
            "content": content,
        }

    def download_file(self, root_id: str, relative_path: str) -> Path:
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None:
            raise WorkspaceError(
                404,
                "workspace_root_not_found",
                "The requested workspace root is not authorized.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_path)
        if (
            not relative_path
            or requested.is_absolute()
            or _has_sensitive_component(requested)
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        path = (root_path / requested).resolve(strict=True)
        if path != root_path and root_path not in path.parents:
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        if not stat.S_ISREG(path.stat().st_mode):
            raise WorkspaceError(
                400,
                "workspace_file_required",
                "File download requires a regular file.",
            )
        return path

    def begin_upload(
        self,
        root_id: str,
        relative_directory: str,
        filename: str,
    ) -> WorkspaceUpload:
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None:
            raise WorkspaceError(
                404,
                "workspace_root_not_found",
                "The requested workspace root is not authorized.",
            )
        if not root.writable:
            raise WorkspaceError(
                403,
                "workspace_root_read_only",
                "The requested workspace root does not allow uploads.",
            )
        if (
            not filename
            or filename in {".", ".."}
            or "/" in filename
            or "\\" in filename
            or any(ord(character) < 32 for character in filename)
            or len(filename.encode("utf-8")) > 240
            or _is_sensitive_entry(Path(filename))
        ):
            raise WorkspaceError(
                400,
                "invalid_upload_filename",
                "The upload filename is not allowed.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_directory)
        if requested.is_absolute() or any(
            _is_sensitive_entry(Path(part))
            for part in requested.parts
            if part not in {"", "."}
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        directory = (root_path / requested).resolve(strict=True)
        if directory != root_path and root_path not in directory.parents:
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        if not stat.S_ISDIR(directory.stat().st_mode):
            raise WorkspaceError(
                400,
                "workspace_directory_required",
                "Uploads require an existing destination directory.",
            )
        return WorkspaceUpload(
            root_id=root.id,
            root_path=root_path,
            directory=directory,
            filename=filename,
        )

    def remove_uploaded_file(
        self,
        root_id: str,
        relative_path: str,
        *,
        expected_device: int | None,
        expected_inode: int | None,
    ) -> None:
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None or not root.writable:
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The pending attachment path is no longer authorized.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_path)
        if (
            not relative_path
            or requested.is_absolute()
            or _has_sensitive_component(
                requested,
                allow_attachment_storage=True,
            )
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The pending attachment path is no longer authorized.",
            )
        try:
            path = (root_path / requested).resolve(strict=True)
        except FileNotFoundError:
            # The user may have removed the staged file directly on the host.
            # Clearing its pending registry record is still safe and recoverable.
            return
        metadata = path.stat()
        if root_path not in path.parents or not stat.S_ISREG(metadata.st_mode):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The pending attachment path is no longer authorized.",
            )
        if (
            expected_device is None
            or expected_inode is None
            or metadata.st_dev != expected_device
            or metadata.st_ino != expected_inode
        ):
            raise WorkspaceError(
                409,
                "attachment_file_changed",
                "The uploaded file changed after publication and was not removed.",
            )
        path.unlink()

    def uploaded_file(
        self,
        root_id: str,
        relative_path: str,
        *,
        expected_device: int | None,
        expected_inode: int | None,
    ) -> Path:
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None:
            raise WorkspaceError(
                404,
                "workspace_root_not_found",
                "The attachment root is no longer authorized.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_path)
        if (
            not relative_path
            or requested.is_absolute()
            or _has_sensitive_component(
                requested,
                allow_attachment_storage=True,
            )
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The attachment path is no longer authorized.",
            )
        try:
            path = (root_path / requested).resolve(strict=True)
        except FileNotFoundError:
            raise WorkspaceError(
                404,
                "attachment_file_not_found",
                "The attachment file is no longer available.",
            ) from None
        metadata = path.stat()
        if root_path not in path.parents or not stat.S_ISREG(metadata.st_mode):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The attachment path is no longer authorized.",
            )
        if (
            expected_device is None
            or expected_inode is None
            or metadata.st_dev != expected_device
            or metadata.st_ino != expected_inode
        ):
            raise WorkspaceError(
                409,
                "attachment_file_changed",
                "The attachment file changed after publication.",
            )
        return path

    def list_directory(
        self,
        root_id: str,
        relative_path: str = "",
        *,
        limit: int = DEFAULT_DIRECTORY_PAGE_SIZE,
        cursor: int = 0,
    ) -> dict[str, object]:
        root = next((root for root in self._roots if root.id == root_id), None)
        if root is None:
            raise WorkspaceError(
                404,
                "workspace_root_not_found",
                "The requested workspace root is not authorized.",
            )
        root_path = self._validated_root_path(root)
        requested = Path(relative_path)
        if requested.is_absolute() or any(
            _is_sensitive_entry(Path(part))
            for part in requested.parts
            if part not in {"", "."}
        ):
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        directory = (root_path / requested).resolve(strict=True)
        if directory != root_path and root_path not in directory.parents:
            raise WorkspaceError(
                403,
                "workspace_path_forbidden",
                "The requested path is outside the authorized root.",
            )
        entries = []
        for child in directory.iterdir():
            if _is_sensitive_entry(child) or child.is_symlink():
                continue
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError:
                continue
            is_directory = stat.S_ISDIR(metadata.st_mode)
            if not is_directory and not stat.S_ISREG(metadata.st_mode):
                continue
            entries.append(
                {
                    "name": child.name,
                    "path": child.relative_to(root_path).as_posix(),
                    "kind": "directory" if is_directory else "file",
                    "size": None if is_directory else metadata.st_size,
                }
            )
        entries.sort(key=lambda entry: (entry["kind"] != "directory", entry["name"]))
        page = entries[cursor:cursor + limit]
        next_offset = cursor + len(page)
        return {
            "root_id": root.id,
            "path": "" if directory == root_path else directory.relative_to(root_path).as_posix(),
            "entries": page,
            "next_cursor": str(next_offset) if next_offset < len(entries) else None,
        }
