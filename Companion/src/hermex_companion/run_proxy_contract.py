"""Bounds and verified shapes for Gateway-compatible Runs proxying."""

from dataclasses import dataclass
from enum import Enum
from urllib.parse import quote

from hermex_companion.session_proxy_contract import GatewayProxyError


RUNS_PATH = "/v1/runs"
RUN_REQUEST_MAX_BODY_BYTES = 2 * 1024 * 1024
RUN_ID_MAX_LENGTH = 256
APPROVAL_CHOICES = frozenset({"once", "session", "always", "deny"})


class RunPayloadKind(Enum):
    STARTED = "started"
    STATUS = "status"
    STOPPING = "stopping"
    APPROVAL_RESPONSE = "approval_response"


@dataclass(frozen=True)
class RunOperationContract:
    path: str
    success_statuses: frozenset[int]
    payload_kind: RunPayloadKind


def run_request_contract(
    method: str,
    *,
    run_id: str | None,
    action: str | None,
) -> RunOperationContract:
    if run_id is None:
        if method == "POST" and action is None:
            return RunOperationContract(
                RUNS_PATH,
                frozenset({202}),
                RunPayloadKind.STARTED,
            )
        raise ValueError("Unsupported run request")

    encoded_id = quote(validated_run_id(run_id), safe="")
    resource_path = f"{RUNS_PATH}/{encoded_id}"
    if action is None and method == "GET":
        return RunOperationContract(
            resource_path,
            frozenset({200}),
            RunPayloadKind.STATUS,
        )
    if action == "stop" and method == "POST":
        return RunOperationContract(
            f"{resource_path}/stop",
            frozenset({200}),
            RunPayloadKind.STOPPING,
        )
    if action == "approval" and method == "POST":
        return RunOperationContract(
            f"{resource_path}/approval",
            frozenset({200}),
            RunPayloadKind.APPROVAL_RESPONSE,
        )
    raise ValueError("Unsupported run request")


def run_events_path(run_id: str) -> str:
    return f"{RUNS_PATH}/{quote(validated_run_id(run_id), safe='')}/events"


def is_run_payload(payload: object, kind: RunPayloadKind) -> bool:
    if not isinstance(payload, dict):
        return False
    run_id = payload.get("run_id")
    if not isinstance(run_id, str) or not run_id:
        return False
    if kind is RunPayloadKind.APPROVAL_RESPONSE:
        resolved = payload.get("resolved")
        return (
            payload.get("object") == "hermes.run.approval_response"
            and payload.get("choice") in APPROVAL_CHOICES
            and isinstance(resolved, int)
            and not isinstance(resolved, bool)
            and resolved > 0
        )
    status = payload.get("status")
    if not isinstance(status, str) or not status:
        return False
    if kind is RunPayloadKind.STARTED:
        return status == "started"
    if kind is RunPayloadKind.STATUS:
        return payload.get("object") == "hermes.run"
    if kind is RunPayloadKind.STOPPING:
        return status == "stopping"
    return False


def validate_approval_payload(payload: object) -> None:
    if not isinstance(payload, dict) or set(payload) != {"choice"}:
        raise GatewayProxyError(
            400,
            "invalid_approval_request",
            "An approval request must contain only a choice.",
        )
    if payload.get("choice") not in APPROVAL_CHOICES:
        raise GatewayProxyError(
            400,
            "invalid_approval_choice",
            "The approval choice is invalid.",
        )


def validated_run_id(run_id: str) -> str:
    if (
        not run_id
        or len(run_id) > RUN_ID_MAX_LENGTH
        or "/" in run_id
        or "\\" in run_id
        or any(
            ord(character) < 32 or ord(character) == 127
            for character in run_id
        )
    ):
        raise GatewayProxyError(
            400,
            "invalid_run_id",
            "The run ID is invalid.",
        )
    return run_id
