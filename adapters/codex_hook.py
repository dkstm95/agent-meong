#!/usr/bin/python3
"""Normalize a Codex hook event and forward metadata to agent-meong."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import sys
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Optional


EVENT_KINDS = {
    "UserPromptSubmit": "turn.started",
    "PreToolUse": "tool.started",
    "PermissionRequest": "approval.waiting",
    "PostToolUse": "tool.finished",
    "SubagentStart": "agent.started",
    "SubagentStop": "agent.finished",
    "Stop": "turn.stopping",
}


def normalize(
    payload: Dict[str, Any],
    *,
    now: Optional[datetime] = None,
    event_id: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    event_name = str(payload.get("hook_event_name") or "")
    kind = EVENT_KINDS.get(event_name)
    raw_session_id = string_value(payload.get("session_id"))
    if kind is None or raw_session_id is None:
        return None

    session_id = opaque_id("session", raw_session_id)
    actor_id = main_actor_id(session_id)
    parent_actor_id = None
    if event_name in {"SubagentStart", "SubagentStop"}:
        agent_id = string_value(payload.get("agent_id"))
        if agent_id is None:
            return None
        actor_id = f"codex:{session_id}:agent:{opaque_id('agent', raw_session_id, agent_id)}"
        parent_actor_id = main_actor_id(session_id)

    raw_turn_id = string_value(payload.get("turn_id"))
    scope_id = opaque_id("turn", raw_session_id, raw_turn_id) if raw_turn_id else None
    timestamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    observation: Dict[str, Any] = {
        "schemaVersion": 0,
        "eventId": event_id or stable_event_id(payload, event_name, raw_session_id),
        "source": "codex",
        "sessionId": session_id,
        "actorId": actor_id,
        "occurredAt": timestamp.isoformat().replace("+00:00", "Z"),
        "kind": kind,
    }
    if parent_actor_id is not None:
        observation["parentActorId"] = parent_actor_id
    if scope_id is not None:
        observation["scopeId"] = scope_id

    tool_category = categorize_tool(payload.get("tool_name"))
    if event_name in {"PreToolUse", "PostToolUse", "PermissionRequest"}:
        observation["toolCategory"] = tool_category

    if event_name in {"SubagentStop", "Stop"}:
        outcome = terminal_outcome(payload)
        if outcome is not None:
            observation["outcome"] = outcome
    return observation


def main_actor_id(session_id: str) -> str:
    return f"codex:{session_id}:main"


def opaque_id(kind: str, *values: str) -> str:
    digest = hashlib.sha256("\0".join((kind, *values)).encode("utf-8")).hexdigest()
    return f"{kind[:1]}_{digest[:16]}"


def stable_event_id(payload: Dict[str, Any], event_name: str, session_id: str) -> str:
    turn_id = string_value(payload.get("turn_id"))
    agent_id = string_value(payload.get("agent_id"))
    tool_use_id = string_value(payload.get("tool_use_id"))
    stable = event_name in {"UserPromptSubmit", "Stop"} and turn_id is not None
    stable = stable or event_name in {"SubagentStart", "SubagentStop"} and agent_id is not None
    stable = stable or event_name in {"PreToolUse", "PostToolUse"} and tool_use_id is not None
    if not stable:
        return str(uuid.uuid4())
    parts = [session_id, turn_id or "", agent_id or "", tool_use_id or "", event_name]
    return opaque_id("event", *parts)


def categorize_tool(value: Any) -> str:
    name = str(value or "").lower()
    if any(token in name for token in ("bash", "shell", "exec", "terminal")):
        return "shell"
    if any(token in name for token in ("apply_patch", "edit", "write")):
        return "edit"
    if any(token in name for token in ("browser", "chrome", "web")):
        return "browser"
    if any(token in name for token in ("search", "find", "grep", "read")):
        return "search"
    return "other"


def terminal_outcome(payload: Dict[str, Any]) -> Optional[str]:
    outcome = str(payload.get("outcome") or "").lower()
    if outcome in {"failure", "failed", "error"} or payload.get("error"):
        return "failure"
    if outcome in {"cancelled", "canceled"}:
        return "cancelled"
    return "success" if outcome == "success" else None


def string_value(value: Any) -> Optional[str]:
    if not isinstance(value, (str, int)):
        return None
    result = str(value).strip()
    return result or None


def socket_path() -> str:
    return os.environ.get("AGENT_MEONG_SOCKET", f"/tmp/agent-meong-{os.getuid()}.sock")


def send(observation: Dict[str, Any]) -> bool:
    message = json.dumps(observation, separators=(",", ":")).encode("utf-8") + b"\n"
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.15)
    try:
        client.connect(socket_path())
        client.sendall(message)
        return True
    except OSError:
        return False
    finally:
        client.close()


def read_payload() -> Optional[Dict[str, Any]]:
    try:
        value = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--print", action="store_true", dest="print_only")
    return parser.parse_args()


def run() -> int:
    args = parse_args()
    payload = read_payload()
    observation = normalize(payload) if payload is not None else None
    if observation is None:
        return 0
    if args.print_only:
        print(json.dumps(observation, separators=(",", ":")))
    else:
        send(observation)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
