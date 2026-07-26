"""Bounds and verified shapes for Gateway-compatible Runs proxying."""

from dataclasses import dataclass
from enum import Enum
from urllib.parse import quote

from hermex_companion.session_proxy_contract import GatewayProxyError


RUNS_PATH = "/v1/runs"
RUN_REQUEST_MAX_BODY_BYTES = 2 * 1024 * 1024
RUN_ID_MAX_LENGTH = 256


class RunPayloadKind(Enum):
    STARTED = "started"
    STATUS = "status"
    STOPPING = "stopping"


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
    raise ValueError("Unsupported run request")


def run_events_path(run_id: str) -> str:
    return f"{RUNS_PATH}/{quote(validated_run_id(run_id), safe='')}/events"


def is_run_payload(payload: object, kind: RunPayloadKind) -> bool:
    if not isinstance(payload, dict):
        return False
    run_id = payload.get("run_id")
    status = payload.get("status")
    if (
        not isinstance(run_id, str)
        or not run_id
        or not isinstance(status, str)
        or not status
    ):
        return False
    if kind is RunPayloadKind.STARTED:
        return status == "started"
    if kind is RunPayloadKind.STATUS:
        return payload.get("object") == "hermes.run"
    if kind is RunPayloadKind.STOPPING:
        return status == "stopping"
    return False


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
