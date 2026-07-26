"""Bounds and verified shapes for Gateway-compatible session proxying."""

from collections.abc import Sequence
from dataclasses import dataclass
from enum import Enum
import re
from urllib.parse import quote


SESSION_LIST_PATH = "/api/sessions"
SESSION_LIST_QUERY_FIELDS = frozenset(
    {"limit", "offset", "source", "include_children"}
)
SESSION_LIST_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
SESSION_REQUEST_MAX_BODY_BYTES = 16 * 1024
SESSION_ID_MAX_LENGTH = 256
SESSION_LIST_BOOL_VALUES = frozenset(
    {"0", "1", "false", "no", "off", "on", "true", "yes"}
)


@dataclass(frozen=True)
class GatewayProxyResponse:
    status: int
    body: bytes


class SessionPayloadKind(Enum):
    SESSION = "session"
    DELETED = "deleted"
    MESSAGES = "messages"


@dataclass(frozen=True)
class SessionOperationContract:
    path: str
    success_statuses: frozenset[int]
    payload_kind: SessionPayloadKind


class GatewayProxyError(Exception):
    """Bounded App-facing classification for a failed Gateway request."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def validated_session_list_query(
    query_items: Sequence[tuple[str, str]],
) -> list[tuple[str, str]]:
    if len(query_items) > len(SESSION_LIST_QUERY_FIELDS):
        raise GatewayProxyError(
            400,
            "invalid_query",
            "The session-list query contains unsupported or repeated fields.",
        )

    seen: set[str] = set()
    validated: list[tuple[str, str]] = []
    for name, value in query_items:
        if name not in SESSION_LIST_QUERY_FIELDS or name in seen:
            raise GatewayProxyError(
                400,
                "invalid_query",
                "The session-list query contains unsupported or repeated fields.",
            )
        seen.add(name)

        if name == "limit":
            _validate_bounded_integer(name, value, maximum=200)
        elif name == "offset":
            _validate_bounded_integer(name, value, maximum=1_000_000)
        elif name == "include_children":
            if value.strip().lower() not in SESSION_LIST_BOOL_VALUES:
                raise GatewayProxyError(
                    400,
                    "invalid_query",
                    "include_children must be an explicit boolean value.",
                )
        elif (
            len(value) > 128
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
        ):
            raise GatewayProxyError(
                400,
                "invalid_query",
                "source exceeds the supported query bounds.",
            )

        validated.append((name, value))
    return validated


def is_session_list_payload(payload: object) -> bool:
    if not isinstance(payload, dict):
        return False
    if (
        payload.get("object") != "list"
        or not isinstance(payload.get("data"), list)
        or type(payload.get("limit")) is not int
        or type(payload.get("offset")) is not int
        or type(payload.get("has_more")) is not bool
    ):
        return False
    return all(isinstance(session, dict) for session in payload["data"])


def session_request_contract(
    method: str,
    *,
    session_id: str | None,
    action: str | None,
) -> SessionOperationContract:
    if session_id is None:
        if method == "POST" and action is None:
            return SessionOperationContract(
                SESSION_LIST_PATH,
                frozenset({201}),
                SessionPayloadKind.SESSION,
            )
        raise ValueError("Unsupported session request")

    encoded_id = quote(_validated_session_id(session_id), safe="")
    resource_path = f"{SESSION_LIST_PATH}/{encoded_id}"
    if action is None:
        if method == "GET":
            return SessionOperationContract(
                resource_path,
                frozenset({200}),
                SessionPayloadKind.SESSION,
            )
        if method == "PATCH":
            return SessionOperationContract(
                resource_path,
                frozenset({200}),
                SessionPayloadKind.SESSION,
            )
        if method == "DELETE":
            return SessionOperationContract(
                resource_path,
                frozenset({200}),
                SessionPayloadKind.DELETED,
            )
    elif action == "messages" and method == "GET":
        return SessionOperationContract(
            f"{resource_path}/messages",
            frozenset({200}),
            SessionPayloadKind.MESSAGES,
        )
    elif action == "fork" and method == "POST":
        return SessionOperationContract(
            f"{resource_path}/fork",
            frozenset({201}),
            SessionPayloadKind.SESSION,
        )
    raise ValueError("Unsupported session request")


async def read_bounded_session_response(response: object) -> bytes:
    content_length = getattr(response, "content_length", None)
    if (
        content_length is not None
        and content_length > SESSION_LIST_MAX_RESPONSE_BYTES
    ):
        raise GatewayProxyError(
            502,
            "gateway_response_too_large",
            "The Hermes Gateway session response exceeded the response limit.",
        )

    body = bytearray()
    async for chunk in response.content.iter_chunked(64 * 1024):
        body.extend(chunk)
        if len(body) > SESSION_LIST_MAX_RESPONSE_BYTES:
            raise GatewayProxyError(
                502,
                "gateway_response_too_large",
                "The Hermes Gateway session response exceeded the response limit.",
            )
    return bytes(body)


def is_session_payload(payload: object, kind: SessionPayloadKind) -> bool:
    if not isinstance(payload, dict):
        return False
    if kind is SessionPayloadKind.SESSION:
        return (
            payload.get("object") == "hermes.session"
            and isinstance(payload.get("session"), dict)
        )
    if kind is SessionPayloadKind.DELETED:
        return (
            payload.get("object") == "hermes.session.deleted"
            and isinstance(payload.get("id"), str)
            and type(payload.get("deleted")) is bool
        )
    if kind is SessionPayloadKind.MESSAGES:
        return (
            payload.get("object") == "list"
            and isinstance(payload.get("session_id"), str)
            and isinstance(payload.get("data"), list)
            and all(isinstance(message, dict) for message in payload["data"])
        )
    return False


def sanitized_gateway_error(payload: object) -> dict[str, object] | None:
    if not isinstance(payload, dict) or not isinstance(payload.get("error"), dict):
        return None
    error = payload["error"]
    code = error.get("code")
    message = error.get("message")
    if (
        not isinstance(code, str)
        or re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) is None
        or not isinstance(message, str)
        or len(message) > 512
        or any(ord(character) < 32 and character not in "\t" for character in message)
        or any(ord(character) == 127 for character in message)
    ):
        return None
    return {"error": {"code": code, "message": message}}


def _validated_session_id(session_id: str) -> str:
    if (
        not session_id
        or len(session_id) > SESSION_ID_MAX_LENGTH
        or "/" in session_id
        or "\\" in session_id
        or any(ord(character) < 32 or ord(character) == 127 for character in session_id)
    ):
        raise GatewayProxyError(
            400,
            "invalid_session_id",
            "The session ID is invalid.",
        )
    return session_id


def _validate_bounded_integer(name: str, value: str, *, maximum: int) -> None:
    if not value.isascii() or not value.isdecimal():
        raise GatewayProxyError(
            400,
            "invalid_query",
            f"{name} must be a non-negative integer.",
        )
    parsed = int(value)
    if parsed > maximum:
        raise GatewayProxyError(
            400,
            "invalid_query",
            f"{name} exceeds the supported query bound.",
        )
