"""Bounds and verified shapes for read-only Skills and Toolsets discovery."""

from hermex_companion.session_proxy_contract import GatewayProxyError


SKILLS_PATH = "/v1/skills"
TOOLSETS_PATH = "/v1/toolsets"
DISCOVERY_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
DISCOVERY_MAX_ROWS = 2_048
DISCOVERY_MAX_TOOLS_PER_TOOLSET = 512
NAME_MAX_LENGTH = 256
LABEL_MAX_LENGTH = 256
CATEGORY_MAX_LENGTH = 128
DESCRIPTION_MAX_LENGTH = 4_096
TOOL_NAME_MAX_LENGTH = 256


def is_skills_payload(payload: object) -> bool:
    if not _is_list_envelope(payload):
        return False
    return all(_is_skill(row) for row in payload["data"])


def is_toolsets_payload(payload: object) -> bool:
    if (
        not _is_list_envelope(payload)
        or payload.get("platform") != "api_server"
    ):
        return False
    return all(_is_toolset(row) for row in payload["data"])


async def read_bounded_discovery_response(response: object) -> bytes:
    content_length = getattr(response, "content_length", None)
    if (
        content_length is not None
        and content_length > DISCOVERY_MAX_RESPONSE_BYTES
    ):
        _too_large()

    body = bytearray()
    async for chunk in response.content.iter_chunked(64 * 1024):
        body.extend(chunk)
        if len(body) > DISCOVERY_MAX_RESPONSE_BYTES:
            _too_large()
    return bytes(body)


def _is_list_envelope(payload: object) -> bool:
    return (
        isinstance(payload, dict)
        and payload.get("object") == "list"
        and isinstance(payload.get("data"), list)
        and len(payload["data"]) <= DISCOVERY_MAX_ROWS
    )


def _is_skill(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    return (
        _is_required_string(value.get("name"), NAME_MAX_LENGTH)
        and _is_string(
            value.get("description"),
            DESCRIPTION_MAX_LENGTH,
            allow_layout_whitespace=True,
        )
        and _is_optional_string(value.get("category"), CATEGORY_MAX_LENGTH)
    )


def _is_toolset(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    tools = value.get("tools")
    if (
        not isinstance(tools, list)
        or len(tools) > DISCOVERY_MAX_TOOLS_PER_TOOLSET
        or any(
            not _is_required_string(tool, TOOL_NAME_MAX_LENGTH)
            for tool in tools
        )
        or tools != sorted(set(tools))
    ):
        return False
    return (
        _is_required_string(value.get("name"), NAME_MAX_LENGTH)
        and _is_string(value.get("label"), LABEL_MAX_LENGTH)
        and _is_string(
            value.get("description"),
            DESCRIPTION_MAX_LENGTH,
            allow_layout_whitespace=True,
        )
        and type(value.get("enabled")) is bool
        and type(value.get("configured")) is bool
    )


def _is_required_string(value: object, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and _is_string(value, maximum)
    )


def _is_optional_string(value: object, maximum: int) -> bool:
    return value is None or _is_string(value, maximum)


def _is_string(
    value: object,
    maximum: int,
    *,
    allow_layout_whitespace: bool = False,
) -> bool:
    allowed_controls = {9, 10, 13} if allow_layout_whitespace else set()
    return (
        isinstance(value, str)
        and len(value) <= maximum
        and not any(
            (
                ord(character) < 32
                and ord(character) not in allowed_controls
            )
            or ord(character) == 127
            for character in value
        )
    )


def _too_large() -> None:
    raise GatewayProxyError(
        502,
        "gateway_response_too_large",
        "The Hermes Gateway discovery response exceeded the response limit.",
    )
