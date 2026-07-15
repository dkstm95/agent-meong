#!/usr/bin/python3
"""Normalize a Codex hook event and forward metadata to agent-meong."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import socket
import stat
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
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
HOOK_STATUS_MESSAGE = "agent-meong activity"
USER_HOOK_EVENTS = tuple(EVENT_KINDS)


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


def user_paths(
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
) -> Dict[str, Path]:
    root = (home or Path.home()).expanduser()
    support = root / "Library" / "Application Support" / "AgentMeong"
    configured_codex_home = os.environ.get("CODEX_HOME") if home is None else None
    codex_root = (
        codex_home.expanduser()
        if codex_home is not None
        else Path(configured_codex_home).expanduser()
        if configured_codex_home
        else root / ".codex"
    )
    return {
        "adapter": support / "codex_hook.py",
        "hooks": codex_root / "hooks.json",
    }


def hook_handler(adapter_path: Path) -> Dict[str, Any]:
    return {
        "type": "command",
        "command": f"/usr/bin/python3 {shlex.quote(str(adapter_path))}",
        "timeout": 2,
        "statusMessage": HOOK_STATUS_MESSAGE,
    }


def is_agent_meong_handler(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and value.get("type") == "command"
        and value.get("statusMessage") == HOOK_STATUS_MESSAGE
    )


def read_hooks_document(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {"hooks": {}}
    with path.open(encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict):
        raise ValueError("~/.codex/hooks.json must contain a JSON object")
    hooks = document.get("hooks")
    if hooks is None:
        document["hooks"] = {}
    elif not isinstance(hooks, dict):
        raise ValueError("~/.codex/hooks.json hooks must contain a JSON object")
    return document


def remove_agent_meong_handlers(document: Dict[str, Any]) -> bool:
    hooks = document.setdefault("hooks", {})
    changed = False
    for event_name, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            handlers = group["hooks"]
            kept_handlers = [handler for handler in handlers if not is_agent_meong_handler(handler)]
            if len(kept_handlers) != len(handlers):
                changed = True
            if kept_handlers:
                next_group = dict(group)
                next_group["hooks"] = kept_handlers
                kept_groups.append(next_group)
        if kept_groups:
            hooks[event_name] = kept_groups
        else:
            hooks.pop(event_name, None)
    return changed


def write_json_atomic(path: Path, document: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    existing_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-meong-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(temporary_path, existing_mode)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def copy_adapter_atomic(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".codex-hook-", dir=destination.parent)
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    try:
        shutil.copyfile(source, temporary_path)
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def install_user_hook(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
    source: Optional[Path] = None,
) -> str:
    paths = user_paths(home, codex_home)
    source_path = (source or Path(__file__)).resolve()
    document = read_hooks_document(paths["hooks"])
    remove_agent_meong_handlers(document)
    handler = hook_handler(paths["adapter"])
    hooks = document["hooks"]
    for event_name in USER_HOOK_EVENTS:
        groups = hooks.setdefault(event_name, [])
        if not isinstance(groups, list):
            raise ValueError(f"~/.codex/hooks.json {event_name} must contain a JSON array")
        groups.append({"hooks": [dict(handler)]})
    copy_adapter_atomic(source_path, paths["adapter"])
    write_json_atomic(paths["hooks"], document)
    return user_hook_status(home=home, codex_home=codex_home, source=source_path)


def uninstall_user_hook(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
) -> str:
    paths = user_paths(home, codex_home)
    if paths["hooks"].exists():
        document = read_hooks_document(paths["hooks"])
        if remove_agent_meong_handlers(document):
            write_json_atomic(paths["hooks"], document)
    paths["adapter"].unlink(missing_ok=True)
    try:
        paths["adapter"].parent.rmdir()
    except OSError:
        pass
    return user_hook_status(home=home, codex_home=codex_home)


def user_hook_status(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
    source: Optional[Path] = None,
) -> str:
    paths = user_paths(home, codex_home)
    try:
        document = read_hooks_document(paths["hooks"])
    except (json.JSONDecodeError, OSError, ValueError):
        return "invalid"
    expected_command = hook_handler(paths["adapter"])["command"]
    installed_events = set()
    found_managed_handler = False
    managed_handler_count = 0
    for event_name, groups in document["hooks"].items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            handlers = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(handlers, list):
                continue
            for handler in handlers:
                if not is_agent_meong_handler(handler):
                    continue
                found_managed_handler = True
                managed_handler_count += 1
                if handler.get("command") == expected_command:
                    installed_events.add(event_name)
    source_path = (source or Path(__file__)).resolve()
    adapter_matches = (
        paths["adapter"].is_file()
        and hashlib.sha256(paths["adapter"].read_bytes()).digest()
        == hashlib.sha256(source_path.read_bytes()).digest()
    )
    if (
        adapter_matches
        and installed_events == set(USER_HOOK_EVENTS)
        and managed_handler_count == len(USER_HOOK_EVENTS)
    ):
        return "installed"
    if paths["adapter"].exists() or found_managed_handler:
        return "needs_repair"
    return "not_installed"


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
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--install", action="store_true")
    action.add_argument("--uninstall", action="store_true")
    action.add_argument("--status", action="store_true")
    return parser.parse_args()


def run() -> int:
    args = parse_args()
    try:
        if args.install:
            print(json.dumps({"status": install_user_hook()}))
            return 0
        if args.uninstall:
            print(json.dumps({"status": uninstall_user_hook()}))
            return 0
        if args.status:
            print(json.dumps({"status": user_hook_status()}))
            return 0
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(json.dumps({"status": "error", "message": str(error)}))
        return 1
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
