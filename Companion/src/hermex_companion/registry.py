"""Persistent pairing and device registry."""

from collections.abc import Callable
from dataclasses import dataclass
import hashlib
from pathlib import Path
import secrets
import sqlite3
import time
from uuid import uuid4

MAX_LISTED_DEVICES = 256


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

            PRAGMA user_version = 1;
            """
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
