"""Verified Gateway model-picker surface exposed through Companion."""

from collections.abc import Sequence

from hermex_companion.session_proxy_contract import GatewayProxyError


MODEL_OPTIONS_PATH = "/api/model/options"
MODEL_OPTIONS_BOOL_VALUES = frozenset(
    {"0", "1", "false", "no", "off", "on", "true", "yes"}
)
MODEL_OPTIONS_TIMEOUT_SECONDS = 30.0
REASONING_EFFORTS = frozenset(
    {"none", "minimal", "low", "medium", "high", "xhigh"}
)
MODEL_ID_MAX_LENGTH = 200
PROVIDER_ID_MAX_LENGTH = 80


def validated_model_options_query(
    query_items: Sequence[tuple[str, str]],
) -> list[tuple[str, str]]:
    if not query_items:
        return []
    if (
        len(query_items) != 1
        or query_items[0][0] != "refresh"
        or query_items[0][1].strip().lower()
        not in MODEL_OPTIONS_BOOL_VALUES
    ):
        raise GatewayProxyError(
            400,
            "invalid_query",
            "Model options accept only one explicit refresh boolean.",
        )
    return list(query_items)


def is_model_options_payload(payload: object) -> bool:
    """Check stable identity fields while tolerating additive picker metadata."""
    if not isinstance(payload, dict):
        return False
    providers = payload.get("providers")
    if not isinstance(providers, list):
        return False
    if not _is_optional_bounded_string(payload.get("model")):
        return False
    if not _is_optional_bounded_string(payload.get("provider")):
        return False

    for provider in providers:
        if not isinstance(provider, dict):
            return False
        slug = provider.get("slug")
        models = provider.get("models")
        if (
            not isinstance(slug, str)
            or not slug
            or len(slug) > 128
            or not isinstance(models, list)
        ):
            return False
        if any(
            not isinstance(model, str)
            or not model
            or len(model) > 512
            for model in models
        ):
            return False
    return True


def validate_model_lock_payload(payload: object) -> None:
    if not isinstance(payload, dict) or set(payload) not in (
        {"model", "provider"},
        {"model", "provider", "model_options"},
    ):
        _invalid_model_selection()
    if not _is_required_selection_string(
        payload.get("model"),
        maximum=MODEL_ID_MAX_LENGTH,
    ):
        _invalid_model_selection()
    if not _is_required_selection_string(
        payload.get("provider"),
        maximum=PROVIDER_ID_MAX_LENGTH,
    ):
        _invalid_model_selection()

    options = payload.get("model_options")
    if options is None:
        return
    if (
        not isinstance(options, dict)
        or set(options) != {"reasoning", "reasoning_effort"}
        or options.get("reasoning_effort") not in REASONING_EFFORTS
    ):
        _invalid_model_selection()
    effort = options["reasoning_effort"]
    reasoning = options.get("reasoning")
    if (
        not isinstance(reasoning, dict)
        or set(reasoning) != {"enabled", "effort"}
        or reasoning.get("effort") != effort
        or type(reasoning.get("enabled")) is not bool
        or reasoning["enabled"] != (effort != "none")
    ):
        _invalid_model_selection()


def is_model_lock_payload(
    payload: object,
    *,
    session_id: str,
) -> bool:
    if (
        not isinstance(payload, dict)
        or payload.get("object") != "hermes.session.model_lock"
        or payload.get("session_id") != session_id
        or not isinstance(payload.get("runtime"), dict)
    ):
        return False
    runtime = payload["runtime"]
    return (
        _is_required_selection_string(
            runtime.get("model"),
            maximum=MODEL_ID_MAX_LENGTH,
        )
        and _is_required_selection_string(
            runtime.get("provider"),
            maximum=PROVIDER_ID_MAX_LENGTH,
        )
    )


def _is_optional_bounded_string(value: object) -> bool:
    return value is None or (
        isinstance(value, str) and len(value) <= 512
    )


def _is_required_selection_string(
    value: object,
    *,
    maximum: int,
) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and len(value) <= maximum
        and not any(
            ord(character) < 32 or ord(character) == 127
            for character in value
        )
    )


def _invalid_model_selection() -> None:
    raise GatewayProxyError(
        400,
        "invalid_model_selection",
        "The model selection is invalid.",
    )
