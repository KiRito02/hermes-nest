"""Persistent pairing and device registry."""

from collections.abc import Callable
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import secrets
import sqlite3
import time
from uuid import uuid4

MAX_LISTED_DEVICES = 256
MAX_PENDING_ATTACHMENTS = 10
MAX_PENDING_ATTACHMENT_BYTES = 200 * 1024 * 1024


class RegistryError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True)
class ClaimedDevice:
    id: str
    name: str
    credential: str


@dataclass(frozen=True)
class RegisteredDevice:
    id: str
    name: str
    created_at: int
    last_seen_at: int | None
    revoked_at: int | None


@dataclass(frozen=True)
class AttachmentRecord:
    id: str
    root_id: str
    relative_path: str
    name: str
    content_type: str
    size: int
    state: str
    file_device: int | None
    file_inode: int | None


@dataclass(frozen=True)
class ConsumedAttachmentRecord:
    id: str
    root_id: str
    relative_path: str
    name: str
    content_type: str
    size: int
    run_id: str
    prompt_fingerprint: str
    consumption_order: int | None
    message_id: str | None
    prior_message_id: int | None


def attachment_prompt_fingerprint(content: object) -> str:
    encoded = json.dumps(
        content,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class DeviceRegistry:
    """Hide pairing secrets, device credentials, and SQLite transactions."""

    def __init__(
        self,
        path: Path | str,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._clock = clock
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(path, timeout=5)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA foreign_keys = ON")
        self._connection.execute("PRAGMA busy_timeout = 5000")
        if path != ":memory:":
            self._connection.execute("PRAGMA journal_mode = WAL")
        self._initialize_schema()

    def close(self) -> None:
        self._connection.close()

    def create_pairing_secret(self, expires_in: int) -> str:
        if not 1 <= expires_in <= 3600:
            raise ValueError("expires_in must be between 1 and 3600 seconds")
        secret = secrets.token_urlsafe(32)
        created_at = int(self._clock())
        self._connection.execute(
            """
            INSERT INTO pairing_secrets (
                id, secret_hash, created_at, expires_at, consumed_at
            ) VALUES (?, ?, ?, ?, NULL)
            """,
            (
                str(uuid4()),
                self._digest(secret),
                created_at,
                created_at + expires_in,
            ),
        )
        self._connection.commit()
        return secret

    def claim_pairing_secret(self, secret: object, device_name: object) -> ClaimedDevice:
        normalized_secret = self._validate_secret(secret)
        normalized_name = self._validate_device_name(device_name)
        now = int(self._clock())

        self._connection.execute("BEGIN IMMEDIATE")
        try:
            pairing = self._connection.execute(
                """
                SELECT expires_at, consumed_at
                FROM pairing_secrets
                WHERE secret_hash = ?
                """,
                (self._digest(normalized_secret),),
            ).fetchone()
            if pairing is None:
                raise RegistryError(
                    401,
                    "pairing_secret_invalid",
                    "Pairing secret is invalid.",
                )
            if pairing["consumed_at"] is not None:
                raise RegistryError(
                    409,
                    "pairing_secret_used",
                    "Pairing secret has already been used.",
                )
            if pairing["expires_at"] <= now:
                raise RegistryError(
                    410,
                    "pairing_secret_expired",
                    "Pairing secret has expired.",
                )

            device_id = str(uuid4())
            credential = secrets.token_urlsafe(32)
            self._connection.execute(
                """
                INSERT INTO devices (
                    id, name, credential_hash, created_at, last_seen_at, revoked_at
                ) VALUES (?, ?, ?, ?, NULL, NULL)
                """,
                (
                    device_id,
                    normalized_name,
                    self._digest(credential),
                    now,
                ),
            )
            self._connection.execute(
                """
                UPDATE pairing_secrets
                SET consumed_at = ?
                WHERE secret_hash = ?
                """,
                (now, self._digest(normalized_secret)),
            )
            self._connection.commit()
            return ClaimedDevice(
                id=device_id,
                name=normalized_name,
                credential=credential,
            )
        except Exception:
            self._connection.rollback()
            raise

    def authenticate(self, credential: object) -> RegisteredDevice:
        if not isinstance(credential, str) or not credential or len(credential) > 512:
            raise RegistryError(
                401,
                "device_credential_invalid",
                "Device credential is invalid.",
            )
        device = self._connection.execute(
            """
            SELECT id, name, created_at, last_seen_at, revoked_at
            FROM devices
            WHERE credential_hash = ?
            """,
            (self._digest(credential),),
        ).fetchone()
        if device is None:
            raise RegistryError(
                401,
                "device_credential_invalid",
                "Device credential is invalid.",
            )
        if device["revoked_at"] is not None:
            raise RegistryError(
                403,
                "device_revoked",
                "Device credential has been revoked.",
            )

        last_seen_at = int(self._clock())
        self._connection.execute(
            "UPDATE devices SET last_seen_at = ? WHERE id = ?",
            (last_seen_at, device["id"]),
        )
        self._connection.commit()
        return RegisteredDevice(
            id=device["id"],
            name=device["name"],
            created_at=device["created_at"],
            last_seen_at=last_seen_at,
            revoked_at=None,
        )

    def list_devices(self) -> list[RegisteredDevice]:
        rows = self._connection.execute(
            """
            SELECT id, name, created_at, last_seen_at, revoked_at
            FROM devices
            ORDER BY created_at, id
            LIMIT ?
            """,
            (MAX_LISTED_DEVICES,),
        ).fetchall()
        return [
            RegisteredDevice(
                id=row["id"],
                name=row["name"],
                created_at=row["created_at"],
                last_seen_at=row["last_seen_at"],
                revoked_at=row["revoked_at"],
            )
            for row in rows
        ]

    def revoke_device(self, device_id: str) -> None:
        now = int(self._clock())
        cursor = self._connection.execute(
            """
            UPDATE devices
            SET revoked_at = COALESCE(revoked_at, ?)
            WHERE id = ?
            """,
            (now, device_id),
        )
        self._connection.commit()
        if cursor.rowcount == 0:
            raise RegistryError(
                404,
                "device_not_found",
                "Device was not found.",
            )

    def reserve_attachment(
        self,
        *,
        device_id: str,
        session_id: str,
        root_id: str,
        relative_path: str,
        name: str,
        content_type: str,
    ) -> str:
        attachment_id = str(uuid4())
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            pending_count = self._connection.execute(
                """
                SELECT COUNT(*) AS count
                FROM attachments
                WHERE device_id = ?
                  AND session_id = ?
                  AND state IN ('receiving', 'ready')
                """,
                (device_id, session_id),
            ).fetchone()["count"]
            if pending_count >= MAX_PENDING_ATTACHMENTS:
                raise RegistryError(
                    409,
                    "attachment_count_exceeded",
                    f"A session may have at most {MAX_PENDING_ATTACHMENTS} pending attachments.",
                )
            self._connection.execute(
                """
                INSERT INTO attachments (
                    id, device_id, session_id, root_id, relative_path, name,
                    content_type, size, state, created_at, consumed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'receiving', ?, NULL)
                """,
                (
                    attachment_id,
                    device_id,
                    session_id,
                    root_id,
                    relative_path,
                    name,
                    content_type,
                    int(self._clock()),
                ),
            )
            self._connection.commit()
            return attachment_id
        except Exception:
            self._connection.rollback()
            raise

    def add_attachment_bytes(self, attachment_id: str, byte_count: int) -> None:
        if byte_count <= 0:
            return
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            attachment = self._connection.execute(
                """
                SELECT device_id, session_id, state
                FROM attachments
                WHERE id = ?
                """,
                (attachment_id,),
            ).fetchone()
            if attachment is None or attachment["state"] != "receiving":
                raise RegistryError(
                    409,
                    "attachment_not_receiving",
                    "The attachment is not accepting bytes.",
                )
            pending_bytes = self._connection.execute(
                """
                SELECT COALESCE(SUM(size), 0) AS total
                FROM attachments
                WHERE device_id = ?
                  AND session_id = ?
                  AND state IN ('receiving', 'ready')
                """,
                (attachment["device_id"], attachment["session_id"]),
            ).fetchone()["total"]
            if pending_bytes + byte_count > MAX_PENDING_ATTACHMENT_BYTES:
                raise RegistryError(
                    413,
                    "attachment_bytes_exceeded",
                    "Pending attachments may not exceed 200 MiB per device and session.",
                )
            self._connection.execute(
                "UPDATE attachments SET size = size + ? WHERE id = ?",
                (byte_count, attachment_id),
            )
            self._connection.commit()
        except Exception:
            self._connection.rollback()
            raise

    def complete_attachment(
        self,
        attachment_id: str,
        *,
        file_device: int | None = None,
        file_inode: int | None = None,
    ) -> None:
        cursor = self._connection.execute(
            """
            UPDATE attachments
            SET state = 'ready', file_device = ?, file_inode = ?
            WHERE id = ? AND state = 'receiving'
            """,
            (file_device, file_inode, attachment_id),
        )
        self._connection.commit()
        if cursor.rowcount != 1:
            raise RegistryError(
                409,
                "attachment_not_receiving",
                "The attachment is not accepting bytes.",
            )

    def discard_attachment(self, attachment_id: str) -> None:
        self._connection.execute(
            "DELETE FROM attachments WHERE id = ? AND state = 'receiving'",
            (attachment_id,),
        )
        self._connection.commit()

    def list_ready_attachments(
        self,
        *,
        device_id: str,
        session_id: str,
    ) -> list[AttachmentRecord]:
        rows = self._connection.execute(
            """
            SELECT id, root_id, relative_path, name, content_type, size, state,
                   file_device, file_inode
            FROM attachments
            WHERE device_id = ? AND session_id = ? AND state = 'ready'
              AND run_claim IS NULL
            ORDER BY created_at, id
            LIMIT ?
            """,
            (device_id, session_id, MAX_PENDING_ATTACHMENTS),
        ).fetchall()
        return [
            AttachmentRecord(
                id=row["id"],
                root_id=row["root_id"],
                relative_path=row["relative_path"],
                name=row["name"],
                content_type=row["content_type"],
                size=row["size"],
                state=row["state"],
                file_device=row["file_device"],
                file_inode=row["file_inode"],
            )
            for row in rows
        ]

    def ready_attachment_for_device(
        self,
        *,
        device_id: str,
        attachment_id: str,
    ) -> AttachmentRecord:
        row = self._connection.execute(
            """
            SELECT id, root_id, relative_path, name, content_type, size, state,
                   file_device, file_inode
            FROM attachments
            WHERE id = ? AND device_id = ? AND state = 'ready'
              AND run_claim IS NULL
            """,
            (attachment_id, device_id),
        ).fetchone()
        if row is None:
            raise RegistryError(
                404,
                "attachment_not_found",
                "The pending attachment was not found.",
            )
        return AttachmentRecord(
            id=row["id"],
            root_id=row["root_id"],
            relative_path=row["relative_path"],
            name=row["name"],
            content_type=row["content_type"],
            size=row["size"],
            state=row["state"],
            file_device=row["file_device"],
            file_inode=row["file_inode"],
        )

    def delete_ready_attachment(
        self,
        *,
        device_id: str,
        attachment_id: str,
    ) -> None:
        cursor = self._connection.execute(
            """
            DELETE FROM attachments
            WHERE id = ? AND device_id = ? AND state = 'ready'
              AND run_claim IS NULL
            """,
            (attachment_id, device_id),
        )
        self._connection.commit()
        if cursor.rowcount != 1:
            raise RegistryError(
                404,
                "attachment_not_found",
                "The pending attachment was not found.",
            )

    def get_ready_attachments(
        self,
        *,
        device_id: str,
        session_id: str,
        attachment_ids: list[str],
    ) -> list[AttachmentRecord]:
        if not attachment_ids:
            return []
        placeholders = ",".join("?" for _ in attachment_ids)
        rows = self._connection.execute(
            f"""
            SELECT id, root_id, relative_path, name, content_type, size, state,
                   file_device, file_inode
            FROM attachments
            WHERE device_id = ?
              AND session_id = ?
              AND state = 'ready'
              AND run_claim IS NULL
              AND id IN ({placeholders})
            """,
            (device_id, session_id, *attachment_ids),
        ).fetchall()
        records = {
            row["id"]: AttachmentRecord(
                id=row["id"],
                root_id=row["root_id"],
                relative_path=row["relative_path"],
                name=row["name"],
                content_type=row["content_type"],
                size=row["size"],
                state=row["state"],
                file_device=row["file_device"],
                file_inode=row["file_inode"],
            )
            for row in rows
        }
        if len(records) != len(attachment_ids):
            raise RegistryError(
                409,
                "attachment_not_ready",
                "One or more attachments are missing, consumed, or owned by another device.",
            )
        return [records[attachment_id] for attachment_id in attachment_ids]

    def claim_ready_attachments(
        self,
        *,
        device_id: str,
        session_id: str,
        attachment_ids: list[str],
    ) -> tuple[str, list[AttachmentRecord]]:
        if not attachment_ids:
            return "", []
        claim = str(uuid4())
        placeholders = ",".join("?" for _ in attachment_ids)
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            rows = self._connection.execute(
                f"""
                SELECT id, root_id, relative_path, name, content_type, size,
                       state, file_device, file_inode
                FROM attachments
                WHERE device_id = ?
                  AND session_id = ?
                  AND state = 'ready'
                  AND run_claim IS NULL
                  AND id IN ({placeholders})
                """,
                (device_id, session_id, *attachment_ids),
            ).fetchall()
            records = {
                row["id"]: AttachmentRecord(
                    id=row["id"],
                    root_id=row["root_id"],
                    relative_path=row["relative_path"],
                    name=row["name"],
                    content_type=row["content_type"],
                    size=row["size"],
                    state=row["state"],
                    file_device=row["file_device"],
                    file_inode=row["file_inode"],
                )
                for row in rows
            }
            if len(records) != len(attachment_ids):
                raise RegistryError(
                    409,
                    "attachment_not_ready",
                    "One or more attachments are missing, consumed, claimed, or owned by another device.",
                )
            cursor = self._connection.execute(
                f"""
                UPDATE attachments
                SET run_claim = ?
                WHERE device_id = ?
                  AND session_id = ?
                  AND state = 'ready'
                  AND run_claim IS NULL
                  AND id IN ({placeholders})
                """,
                (claim, device_id, session_id, *attachment_ids),
            )
            if cursor.rowcount != len(attachment_ids):
                raise RegistryError(
                    409,
                    "attachment_not_ready",
                    "One or more attachments are no longer ready.",
                )
            self._connection.commit()
            return claim, [records[value] for value in attachment_ids]
        except Exception:
            self._connection.rollback()
            raise

    def release_attachment_claim(self, claim: str) -> None:
        if not claim:
            return
        self._connection.execute(
            """
            UPDATE attachments
            SET run_claim = NULL
            WHERE run_claim = ? AND state = 'ready'
            """,
            (claim,),
        )
        self._connection.commit()

    def consume_attachment_claim(
        self,
        *,
        claim: str,
        run_id: str,
        prompt_fingerprint: str,
        prior_message_id: int | None = None,
    ) -> None:
        if not claim:
            return
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            claimed = self._connection.execute(
                """
                SELECT DISTINCT session_id
                FROM attachments
                WHERE run_claim = ? AND state = 'ready'
                """,
                (claim,),
            ).fetchall()
            if len(claimed) != 1:
                raise RegistryError(
                    409,
                    "attachment_not_ready",
                    "The claimed attachments are no longer ready.",
                )
            session_id = claimed[0]["session_id"]
            consumption_order = self._next_consumption_order(session_id)
            cursor = self._connection.execute(
                """
                UPDATE attachments
                SET state = 'consumed', consumed_at = ?, run_id = ?,
                    prompt_fingerprint = ?, consumption_order = ?,
                    prior_message_id = ?, run_claim = NULL
                WHERE run_claim = ? AND state = 'ready'
                """,
                (
                    int(self._clock()),
                    run_id,
                    prompt_fingerprint,
                    consumption_order,
                    prior_message_id,
                    claim,
                ),
            )
            if cursor.rowcount == 0:
                raise RegistryError(
                    409,
                    "attachment_not_ready",
                    "The claimed attachments are no longer ready.",
                )
            self._connection.commit()
        except Exception:
            self._connection.rollback()
            raise

    def consume_attachments(
        self,
        *,
        device_id: str,
        session_id: str,
        attachment_ids: list[str],
        run_id: str,
        prompt_fingerprint: str,
        prior_message_id: int | None = None,
    ) -> None:
        if not attachment_ids:
            return
        placeholders = ",".join("?" for _ in attachment_ids)
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            consumption_order = self._next_consumption_order(session_id)
            cursor = self._connection.execute(
                f"""
                UPDATE attachments
                SET state = 'consumed', consumed_at = ?, run_id = ?,
                    prompt_fingerprint = ?, consumption_order = ?,
                    prior_message_id = ?
                WHERE device_id = ?
                  AND session_id = ?
                  AND state = 'ready'
                  AND id IN ({placeholders})
                """,
                (
                    int(self._clock()),
                    run_id,
                    prompt_fingerprint,
                    consumption_order,
                    prior_message_id,
                    device_id,
                    session_id,
                    *attachment_ids,
                ),
            )
            if cursor.rowcount != len(attachment_ids):
                raise RegistryError(
                    409,
                    "attachment_not_ready",
                    "One or more attachments are no longer ready.",
                )
            self._connection.commit()
        except Exception:
            self._connection.rollback()
            raise

    def list_consumed_attachments(
        self,
        *,
        session_id: str,
    ) -> list[ConsumedAttachmentRecord]:
        rows = self._connection.execute(
            """
            SELECT id, root_id, relative_path, name, content_type, size,
                   run_id, prompt_fingerprint, consumption_order, message_id,
                   prior_message_id
            FROM attachments
            WHERE session_id = ?
              AND state = 'consumed'
              AND run_id IS NOT NULL
              AND prompt_fingerprint IS NOT NULL
            ORDER BY
                CASE WHEN consumption_order IS NULL THEN 1 ELSE 0 END,
                consumption_order,
                consumed_at,
                rowid
            """,
            (session_id,),
        ).fetchall()
        return [
            ConsumedAttachmentRecord(
                id=row["id"],
                root_id=row["root_id"],
                relative_path=row["relative_path"],
                name=row["name"],
                content_type=row["content_type"],
                size=row["size"],
                run_id=row["run_id"],
                prompt_fingerprint=row["prompt_fingerprint"],
                consumption_order=row["consumption_order"],
                message_id=row["message_id"],
                prior_message_id=row["prior_message_id"],
            )
            for row in rows
        ]

    def bind_consumed_attachments_to_message(
        self,
        *,
        session_id: str,
        attachment_ids: list[str],
        message_id: str,
    ) -> None:
        if not attachment_ids or not message_id or len(message_id) > 128:
            return
        placeholders = ",".join("?" for _ in attachment_ids)
        self._connection.execute(
            f"""
            UPDATE attachments
            SET message_id = ?
            WHERE session_id = ?
              AND state = 'consumed'
              AND message_id IS NULL
              AND id IN ({placeholders})
            """,
            (message_id, session_id, *attachment_ids),
        )
        self._connection.commit()

    def consumed_attachment_for_download(
        self,
        *,
        attachment_id: str,
    ) -> AttachmentRecord:
        row = self._connection.execute(
            """
            SELECT id, root_id, relative_path, name, content_type, size, state,
                   file_device, file_inode
            FROM attachments
            WHERE id = ? AND state = 'consumed'
            """,
            (attachment_id,),
        ).fetchone()
        if row is None:
            raise RegistryError(
                404,
                "attachment_not_found",
                "The consumed attachment was not found.",
            )
        return AttachmentRecord(
            id=row["id"],
            root_id=row["root_id"],
            relative_path=row["relative_path"],
            name=row["name"],
            content_type=row["content_type"],
            size=row["size"],
            state=row["state"],
            file_device=row["file_device"],
            file_inode=row["file_inode"],
        )

    def _next_consumption_order(self, session_id: str) -> int:
        row = self._connection.execute(
            """
            SELECT COALESCE(MAX(consumption_order), 0) + 1 AS next_order
            FROM attachments
            WHERE session_id = ?
            """,
            (session_id,),
        ).fetchone()
        return int(row["next_order"])

    def _initialize_schema(self) -> None:
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS pairing_secrets (
                id TEXT PRIMARY KEY,
                secret_hash TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                consumed_at INTEGER
            );

            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                credential_hash TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL,
                last_seen_at INTEGER,
                revoked_at INTEGER
            );

            CREATE TABLE IF NOT EXISTS attachments (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                session_id TEXT NOT NULL,
                root_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                name TEXT NOT NULL,
                content_type TEXT NOT NULL,
                size INTEGER NOT NULL CHECK (size >= 0),
                state TEXT NOT NULL CHECK (
                    state IN ('receiving', 'ready', 'consumed')
                ),
                run_claim TEXT,
                created_at INTEGER NOT NULL,
                consumed_at INTEGER,
                run_id TEXT,
                prompt_fingerprint TEXT,
                consumption_order INTEGER,
                message_id TEXT,
                prior_message_id INTEGER,
                file_device INTEGER,
                file_inode INTEGER
            );

            CREATE INDEX IF NOT EXISTS attachments_pending
            ON attachments (device_id, session_id, state);

            PRAGMA user_version = 8;
            """
        )
        attachment_columns = {
            row["name"]
            for row in self._connection.execute(
                "PRAGMA table_info(attachments)"
            ).fetchall()
        }
        if "run_id" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN run_id TEXT"
            )
        if "prompt_fingerprint" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN prompt_fingerprint TEXT"
            )
        if "file_device" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN file_device INTEGER"
            )
        if "file_inode" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN file_inode INTEGER"
            )
        if "run_claim" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN run_claim TEXT"
            )
        if "consumption_order" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN consumption_order INTEGER"
            )
        if "message_id" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN message_id TEXT"
            )
        if "prior_message_id" not in attachment_columns:
            self._connection.execute(
                "ALTER TABLE attachments ADD COLUMN prior_message_id INTEGER"
            )
        self._connection.commit()

    @staticmethod
    def _digest(value: str) -> str:
        return hashlib.sha256(value.encode("utf-8")).hexdigest()

    @staticmethod
    def _validate_secret(value: object) -> str:
        if not isinstance(value, str) or not value or len(value) > 512:
            raise RegistryError(
                400,
                "invalid_request",
                "Pairing secret is required.",
            )
        return value

    @staticmethod
    def _validate_device_name(value: object) -> str:
        if not isinstance(value, str):
            raise RegistryError(
                400,
                "invalid_request",
                "Device name is required.",
            )
        normalized = value.strip()
        if (
            not normalized
            or len(normalized) > 80
            or any(ord(character) < 32 for character in normalized)
        ):
            raise RegistryError(
                400,
                "invalid_request",
                "Device name must contain 1 to 80 printable characters.",
            )
        return normalized
