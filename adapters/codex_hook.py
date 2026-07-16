#!/usr/bin/python3
"""Normalize a Codex hook event and forward metadata to agent-meong."""

from __future__ import annotations

import argparse
import copy
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import re
import shlex
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
LEGACY_HOOK_STATUS_MESSAGE = "agent-meong activity"
HOOK_OWNER = "dev.ailab.agent-meong"
HOOK_VERSION = 4
HOOK_DEFINITION_ID = f"{HOOK_OWNER}/v{HOOK_VERSION}"
OBSERVATION_SOURCE = "openai.codex"
OPAQUE_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
INSTANCE_ID_PATTERN = re.compile(r"^[0-9a-f]{24}$")
HOOK_STATUS_MESSAGE = (
    f"agent-meong activity [{HOOK_DEFINITION_ID}]"
)
VERSIONED_STATUS_PATTERN = re.compile(
    rf"^agent-meong activity \[{re.escape(HOOK_OWNER)}/v([1-9][0-9]*)\]$"
)
USER_HOOK_EVENTS = tuple(EVENT_KINDS)
CODEX_HOOK_EVENT_NAMES = frozenset({
    "SessionStart",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "UserPromptSubmit",
    "SubagentStart",
    "SubagentStop",
    "Stop",
})
CONFIG_WARNING_INLINE_HOOKS = "inline_hooks_present"
SYSTEM_CONFIG_PATH = Path("/etc/codex/config.toml")
SYSTEM_REQUIREMENTS_PATH = Path("/etc/codex/requirements.toml")


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
    actor_id = main_actor_id(raw_session_id)
    parent_actor_id = None
    agent_id = string_value(payload.get("agent_id"))
    if event_name in {"SubagentStart", "SubagentStop"} and agent_id is None:
        return None
    if agent_id is not None:
        # Codex includes this context on lifecycle and tool/prompt events
        # emitted inside a thread-spawned child. Keep every event for that
        # child on the same privacy-safe logical actor.
        actor_id = opaque_id("actor.agent", raw_session_id, agent_id)
        parent_actor_id = main_actor_id(raw_session_id)

    raw_turn_id = string_value(payload.get("turn_id"))
    scope_id = opaque_id("turn", raw_session_id, raw_turn_id) if raw_turn_id else None
    timestamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    observation: Dict[str, Any] = {
        "schemaVersion": 0,
        "eventId": normalized_event_id(payload, event_name, raw_session_id, event_id),
        "source": OBSERVATION_SOURCE,
        "sessionId": session_id,
        "actorId": actor_id,
        "occurredAt": timestamp.isoformat().replace("+00:00", "Z"),
        "kind": kind,
        "integrationVersion": HOOK_DEFINITION_ID,
        "integrationInstance": integration_instance_id(),
    }
    if parent_actor_id is not None:
        observation["parentActorId"] = parent_actor_id
    if scope_id is not None:
        observation["scopeId"] = scope_id

    tool_category = categorize_tool(payload.get("tool_name"))
    if event_name in {"PreToolUse", "PostToolUse", "PermissionRequest"}:
        observation["toolCategory"] = tool_category

    return observation


def main_actor_id(raw_session_id: str) -> str:
    return opaque_id("actor.main", raw_session_id)


def opaque_id(kind: str, *values: str) -> str:
    digest = hashlib.sha256("\0".join((kind, *values)).encode("utf-8")).hexdigest()
    return digest[:32]


def normalized_event_id(
    payload: Dict[str, Any],
    event_name: str,
    session_id: str,
    supplied_event_id: Optional[str],
) -> str:
    if supplied_event_id is None:
        return stable_event_id(payload, event_name, session_id)
    if OPAQUE_ID_PATTERN.fullmatch(supplied_event_id):
        return supplied_event_id
    return opaque_id("event.supplied", supplied_event_id)


def stable_event_id(payload: Dict[str, Any], event_name: str, session_id: str) -> str:
    turn_id = string_value(payload.get("turn_id"))
    agent_id = string_value(payload.get("agent_id"))
    tool_use_id = string_value(payload.get("tool_use_id"))
    stable = event_name in {"UserPromptSubmit", "Stop"} and turn_id is not None
    stable = stable or event_name in {"SubagentStart", "SubagentStop"} and agent_id is not None
    stable = stable or event_name in {"PreToolUse", "PostToolUse"} and tool_use_id is not None
    if not stable:
        return opaque_id("event.random", str(uuid.uuid4()))
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


def string_value(value: Any) -> Optional[str]:
    if not isinstance(value, (str, int)):
        return None
    result = str(value).strip()
    return result or None


def socket_path() -> str:
    return os.environ.get("AGENT_MEONG_SOCKET", f"/tmp/agent-meong-{os.getuid()}.sock")


def integration_instance_id() -> str:
    parent = Path(__file__).resolve().parent
    if parent.parent.name == "codex-hooks" and re.fullmatch(r"[0-9a-f]{24}", parent.name):
        try:
            value = _read_managed_text(parent / ".instance-id")
            if value is not None:
                candidate = value.strip()
                if INSTANCE_ID_PATTERN.fullmatch(candidate):
                    return candidate
        except (OSError, ValueError):
            # An installed adapter must remain privacy-safe even if its managed
            # directory is replaced with an unsafe filesystem entry.
            pass
    return "unscoped"


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
    try:
        canonical_codex_root = codex_root.resolve(strict=False)
    except RuntimeError as error:
        raise ValueError(f"{codex_root} contains a symlink loop") from error
    codex_identity = hashlib.sha256(
        os.fsencode(str(canonical_codex_root))
    ).hexdigest()[:24]
    return {
        "adapter": support / "codex-hooks" / codex_identity / "codex_hook.py",
        "instance": support / "codex-hooks" / codex_identity / ".instance-id",
        "legacyAdapter": support / "codex_hook.py",
        "hooks": codex_root / "hooks.json",
        "config": codex_root / "config.toml",
    }


def hook_handler(adapter_path: Path) -> Dict[str, Any]:
    return {
        "type": "command",
        "command": f"/usr/bin/python3 {shlex.quote(str(adapter_path))}",
        "timeout": 2,
        "statusMessage": HOOK_STATUS_MESSAGE,
    }


def is_agent_meong_handler(
    value: Any,
    *,
    expected_command: Optional[str] = None,
    legacy_command: Optional[str] = None,
) -> bool:
    """Return whether a handler is owned by agent-meong.

    Versioned handlers have an explicit namespaced marker. A pre-marker or
    otherwise drifted handler is considered ours only when its command exactly
    points at the expected installed adapter; legacy status text alone is not
    ownership.
    """
    if not isinstance(value, dict):
        return False
    status_message = value.get("statusMessage")
    marker_match = (
        VERSIONED_STATUS_PATTERN.fullmatch(status_message)
        if isinstance(status_message, str)
        else None
    )
    if marker_match is not None:
        return int(marker_match.group(1)) <= HOOK_VERSION
    command = value.get("command")
    return command in {
        candidate
        for candidate in (expected_command, legacy_command)
        if candidate is not None
    }


def contains_newer_agent_meong_handler(document: Dict[str, Any]) -> bool:
    for groups in document.get("hooks", {}).values():
        for group in groups:
            for handler in group.get("hooks", []):
                if not isinstance(handler, dict):
                    continue
                status_message = handler.get("statusMessage")
                marker_match = (
                    VERSIONED_STATUS_PATTERN.fullmatch(status_message)
                    if isinstance(status_message, str)
                    else None
                )
                if marker_match is not None and int(marker_match.group(1)) > HOOK_VERSION:
                    return True
    return False


def _resolved_regular_path(path: Path) -> tuple[Path, bool]:
    """Resolve a JSON path without ever opening a special file.

    A dangling symlink is a supported installation target. Existing targets must
    be regular files so a FIFO or device can never block the app.
    """
    try:
        info = path.lstat()
    except FileNotFoundError:
        try:
            return path.parent.resolve(strict=False) / path.name, False
        except RuntimeError as error:
            raise ValueError(f"{path} contains a symlink loop") from error
    if stat.S_ISLNK(info.st_mode):
        try:
            target = path.resolve(strict=False)
        except RuntimeError as error:
            raise ValueError(f"{path} contains a symlink loop") from error
        try:
            target_info = target.stat()
        except FileNotFoundError:
            return target, False
        if not stat.S_ISREG(target_info.st_mode):
            raise ValueError(f"{path} must point to a regular file")
        return target, True
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"{path} must be a regular file")
    try:
        return path.resolve(strict=True), True
    except RuntimeError as error:
        raise ValueError(f"{path} contains a symlink loop") from error


def _read_regular_text(path: Path) -> Optional[str]:
    target, exists = _resolved_regular_path(path)
    if not exists:
        return None
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(target, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"{path} must be a regular file")
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            descriptor = -1
            return handle.read()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _managed_root_for(path: Path) -> Path:
    """Return the app-owned root for one versioned Codex adapter file."""
    instance_directory = path.parent
    hooks_directory = instance_directory.parent
    managed_root = hooks_directory.parent
    if (
        path.name not in {"codex_hook.py", ".instance-id"}
        or INSTANCE_ID_PATTERN.fullmatch(instance_directory.name) is None
        or hooks_directory.name != "codex-hooks"
        or managed_root.name != "AgentMeong"
    ):
        raise ValueError(f"{path} is not an agent-meong managed adapter path")
    return managed_root


@contextlib.contextmanager
def _managed_directory_descriptor(
    directory: Path,
    managed_root: Path,
    *,
    create: bool,
):
    """Open an app-owned directory chain without following any component.

    The user's Application Support directory is the boundary supplied by the
    OS. Every component created and owned below ``AgentMeong`` is opened using
    ``O_NOFOLLOW`` and a parent descriptor, so a link swap cannot redirect a
    managed file operation outside that tree.
    """
    try:
        relative = directory.relative_to(managed_root)
    except ValueError as error:
        raise ValueError(f"{directory} is outside {managed_root}") from error

    base = managed_root.parent
    if create:
        base.mkdir(parents=True, exist_ok=True, mode=0o700)

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(base, flags)
    except FileNotFoundError:
        yield None
        return

    try:
        components = (managed_root.name, *relative.parts)
        for component in components:
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    yield None
                    return
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                try:
                    child = os.open(component, flags, dir_fd=descriptor)
                except OSError as error:
                    if error.errno in {errno.ELOOP, errno.ENOTDIR}:
                        raise ValueError(
                            f"{directory} contains an unsafe managed directory"
                        ) from error
                    raise
            except OSError as error:
                if error.errno in {errno.ELOOP, errno.ENOTDIR}:
                    raise ValueError(
                        f"{directory} contains an unsafe managed directory"
                    ) from error
                raise
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def _managed_entry_info(
    directory_descriptor: int,
    path: Path,
) -> Optional[os.stat_result]:
    try:
        info = os.stat(
            path.name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode):
        raise ValueError(f"{path} must not be a symlink")
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"{path} must be a regular file")
    return info


def _managed_file_exists(path: Path, *, create_parents: bool = False) -> bool:
    managed_root = _managed_root_for(path)
    with _managed_directory_descriptor(
        path.parent,
        managed_root,
        create=create_parents,
    ) as descriptor:
        if descriptor is None:
            return False
        return _managed_entry_info(descriptor, path) is not None


def _managed_file_snapshot(path: Path) -> Optional[tuple[bytes, int]]:
    managed_root = _managed_root_for(path)
    with _managed_directory_descriptor(
        path.parent,
        managed_root,
        create=False,
    ) as directory_descriptor:
        if directory_descriptor is None:
            return None
        info = _managed_entry_info(directory_descriptor, path)
        if info is None:
            return None
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path.name, flags, dir_fd=directory_descriptor)
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise ValueError(f"{path} must not be a symlink") from error
            raise
        try:
            opened_info = os.fstat(descriptor)
            if not stat.S_ISREG(opened_info.st_mode):
                raise ValueError(f"{path} must be a regular file")
            chunks = []
            while True:
                chunk = os.read(descriptor, 65_536)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks), stat.S_IMODE(opened_info.st_mode)
        finally:
            os.close(descriptor)


def _read_managed_text(path: Path) -> Optional[str]:
    snapshot = _managed_file_snapshot(path)
    return snapshot[0].decode("utf-8") if snapshot is not None else None


def _write_managed_bytes_atomic(path: Path, contents: bytes, mode: int) -> None:
    managed_root = _managed_root_for(path)
    with _managed_directory_descriptor(
        path.parent,
        managed_root,
        create=True,
    ) as directory_descriptor:
        assert directory_descriptor is not None
        _managed_entry_info(directory_descriptor, path)
        temporary_name = ""
        descriptor = -1
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        for _ in range(100):
            candidate = f".agent-meong-{uuid.uuid4().hex}"
            try:
                descriptor = os.open(
                    candidate,
                    flags,
                    mode,
                    dir_fd=directory_descriptor,
                )
                temporary_name = candidate
                break
            except FileExistsError:
                continue
        if descriptor < 0:
            raise FileExistsError(f"could not create a temporary file for {path}")
        try:
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = -1
                handle.write(contents)
                handle.flush()
                os.fchmod(handle.fileno(), mode)
            os.replace(
                temporary_name,
                path.name,
                src_dir_fd=directory_descriptor,
                dst_dir_fd=directory_descriptor,
            )
            temporary_name = ""
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            if temporary_name:
                try:
                    os.unlink(temporary_name, dir_fd=directory_descriptor)
                except FileNotFoundError:
                    pass


def _restore_managed_file(
    path: Path,
    snapshot: Optional[tuple[bytes, int]],
) -> None:
    if snapshot is not None:
        contents, mode = snapshot
        _write_managed_bytes_atomic(path, contents, mode)
        return
    managed_root = _managed_root_for(path)
    with _managed_directory_descriptor(
        path.parent,
        managed_root,
        create=False,
    ) as directory_descriptor:
        if directory_descriptor is None:
            return
        if _managed_entry_info(directory_descriptor, path) is not None:
            os.unlink(path.name, dir_fd=directory_descriptor)


def _delete_managed_file(path: Path) -> None:
    managed_root = _managed_root_for(path)
    with _managed_directory_descriptor(
        path.parent,
        managed_root,
        create=False,
    ) as directory_descriptor:
        if directory_descriptor is None:
            return
        if _managed_entry_info(directory_descriptor, path) is not None:
            os.unlink(path.name, dir_fd=directory_descriptor)


def _preflight_managed_paths(
    paths: Dict[str, Path],
    *,
    create_parents: bool,
) -> None:
    _managed_file_exists(paths["adapter"], create_parents=create_parents)
    _managed_file_exists(paths["instance"], create_parents=create_parents)


def _remove_empty_managed_directories(adapter_path: Path) -> None:
    managed_root = _managed_root_for(adapter_path)
    instance_directory = adapter_path.parent
    hooks_directory = instance_directory.parent
    with _managed_directory_descriptor(
        hooks_directory,
        managed_root,
        create=False,
    ) as hooks_descriptor:
        if hooks_descriptor is not None:
            try:
                os.rmdir(instance_directory.name, dir_fd=hooks_descriptor)
            except OSError:
                pass
    with _managed_directory_descriptor(
        managed_root,
        managed_root,
        create=False,
    ) as root_descriptor:
        if root_descriptor is not None:
            try:
                os.rmdir(hooks_directory.name, dir_fd=root_descriptor)
            except OSError:
                pass


def validate_hooks_document(document: Any, path: Path) -> Dict[str, Any]:
    label = str(path)
    if not isinstance(document, dict):
        raise ValueError(f"{label} must contain a JSON object")
    hooks = document.get("hooks")
    if hooks is None:
        document["hooks"] = {}
        return document
    if not isinstance(hooks, dict):
        raise ValueError(f"{label} hooks must contain a JSON object")
    for event_name, groups in hooks.items():
        if not isinstance(event_name, str) or not event_name:
            raise ValueError(f"{label} hook event names must be non-empty strings")
        if not isinstance(groups, list):
            raise ValueError(f"{label} {event_name} must contain a JSON array")
        for group_index, group in enumerate(groups):
            group_label = f"{label} {event_name}[{group_index}]"
            if not isinstance(group, dict):
                raise ValueError(f"{group_label} must contain a JSON object")
            if "matcher" in group and not isinstance(group["matcher"], str):
                raise ValueError(f"{group_label} matcher must be a string")
            handlers = group.get("hooks")
            if not isinstance(handlers, list):
                raise ValueError(f"{group_label} hooks must contain a JSON array")
            for handler_index, handler in enumerate(handlers):
                handler_label = f"{group_label}.hooks[{handler_index}]"
                if not isinstance(handler, dict):
                    raise ValueError(f"{handler_label} must contain a JSON object")
                handler_type = handler.get("type")
                if not isinstance(handler_type, str) or not handler_type:
                    raise ValueError(f"{handler_label} type must be a non-empty string")
                if handler_type == "command" and not isinstance(
                    handler.get("command"), str
                ):
                    raise ValueError(f"{handler_label} command must be a string")
                if "timeout" in handler and (
                    isinstance(handler["timeout"], bool)
                    or not isinstance(handler["timeout"], (int, float))
                ):
                    raise ValueError(f"{handler_label} timeout must be a number")
                if "statusMessage" in handler and not isinstance(
                    handler["statusMessage"], str
                ):
                    raise ValueError(f"{handler_label} statusMessage must be a string")
                if "async" in handler and not isinstance(handler["async"], bool):
                    raise ValueError(f"{handler_label} async must be a boolean")
    return document


def read_hooks_document(path: Path) -> Dict[str, Any]:
    contents = _read_regular_text(path)
    if contents is None:
        return {"hooks": {}}
    document = json.loads(contents)
    return validate_hooks_document(document, path)


def remove_agent_meong_handlers(
    document: Dict[str, Any],
    *,
    expected_command: str,
    legacy_command: Optional[str] = None,
) -> bool:
    hooks = document.setdefault("hooks", {})
    changed = False
    for event_name, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        kept_groups = []
        event_changed = False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            handlers = group["hooks"]
            kept_handlers = [
                handler
                for handler in handlers
                if not is_agent_meong_handler(
                    handler,
                    expected_command=expected_command,
                    legacy_command=legacy_command,
                )
            ]
            removed_owned_handler = len(kept_handlers) != len(handlers)
            if removed_owned_handler:
                changed = True
                event_changed = True
            if not removed_owned_handler:
                kept_groups.append(group)
            elif kept_handlers:
                next_group = dict(group)
                next_group["hooks"] = kept_handlers
                kept_groups.append(next_group)
        if not event_changed:
            continue
        if kept_groups:
            hooks[event_name] = kept_groups
        else:
            hooks.pop(event_name, None)
    return changed


def write_json_atomic(path: Path, document: Dict[str, Any]) -> None:
    target, exists = _resolved_regular_path(path)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    existing_mode = stat.S_IMODE(target.stat().st_mode) if exists else 0o600
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".agent-meong-", dir=target.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(temporary_path, existing_mode)
        os.replace(temporary_path, target)
    finally:
        temporary_path.unlink(missing_ok=True)


def write_private_text_atomic(path: Path, contents: str) -> None:
    _write_managed_bytes_atomic(path, f"{contents}\n".encode("utf-8"), 0o600)


def installed_instance_id(path: Path) -> Optional[str]:
    contents = _read_managed_text(path)
    if contents is None:
        return None
    candidate = contents.strip()
    return candidate if INSTANCE_ID_PATTERN.fullmatch(candidate) else None


def ensure_instance_id(path: Path) -> str:
    existing = installed_instance_id(path)
    if existing is not None:
        return existing
    value = uuid.uuid4().hex[:24]
    write_private_text_atomic(path, value)
    return value


@contextlib.contextmanager
def hooks_write_lock(path: Path):
    """Serialize agent-meong read/modify/write cycles for one hooks path."""
    lock_identity_path, _ = _resolved_regular_path(path)
    identity = hashlib.sha256(
        os.fsencode(str(lock_identity_path.absolute()))
    ).hexdigest()[:24]
    lock_path = Path(tempfile.gettempdir()) / f"agent-meong-hooks-{identity}.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        lock_info = os.fstat(descriptor)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid():
            raise ValueError(f"unsafe hook lock file: {lock_path}")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def copy_adapter_atomic(source: Path, destination: Path) -> None:
    _write_managed_bytes_atomic(destination, source.read_bytes(), 0o600)


_TOML_TABLE = re.compile(r"^\s*\[\s*([A-Za-z0-9_.-]+)\s*\]\s*(?:#.*)?$")
_TOML_ARRAY_TABLE = re.compile(
    r"^\s*\[\[\s*([A-Za-z0-9_.-]+)\s*\]\]\s*(?:#.*)?$"
)
_TOML_BOOLEAN = re.compile(
    r"^\s*([A-Za-z0-9_-]+)\s*=\s*(true|false)\s*(?:#.*)?$",
    re.IGNORECASE,
)
_TOML_DOTTED_FEATURE_BOOLEAN = re.compile(
    r"^\s*features\s*\.\s*(hooks|codex_hooks)\s*=\s*(true|false)\s*(?:#.*)?$",
    re.IGNORECASE,
)
_TOML_INLINE_FEATURES = re.compile(
    r"^\s*features\s*=\s*\{\s*(.*?)\s*\}\s*(?:#.*)?$",
    re.IGNORECASE,
)
_TOML_INLINE_BOOLEAN = re.compile(
    r"(?:^|,)\s*(hooks|codex_hooks)\s*=\s*(true|false)\s*(?=,|$)",
    re.IGNORECASE,
)
_TOML_INLINE_HOOKS = re.compile(r"^\s*hooks\s*=\s*\{", re.IGNORECASE)
_TOML_HOOK_EVENT_ASSIGNMENT = re.compile(
    rf"^\s*({'|'.join(CODEX_HOOK_EVENT_NAMES)})\s*=",
)
_TOML_DOTTED_HOOK_EVENT = re.compile(
    rf"^\s*hooks\.({'|'.join(CODEX_HOOK_EVENT_NAMES)})\s*=",
)


def _is_hook_event_table(table: str) -> bool:
    parts = table.split(".")
    return len(parts) >= 2 and parts[0] == "hooks" and parts[1] in CODEX_HOOK_EVENT_NAMES


def _hook_settings(path: Path) -> Dict[str, Any]:
    """Conservatively recognize only canonical hook-related TOML settings.

    This intentionally is not a general TOML parser. Unrecognized syntax is
    ignored instead of guessing, which prevents comments, quoted strings, or
    unrelated nested tables from disabling a working connection.
    """
    contents = _read_regular_text(path)
    if contents is None:
        return {"hooksEnabled": None, "managedOnly": None, "inlineHooks": False}

    table: Optional[str] = None
    canonical_hooks_enabled: Optional[bool] = None
    deprecated_hooks_enabled: Optional[bool] = None
    managed_only: Optional[bool] = None
    inline_hooks = False
    for line in contents.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        dotted_feature_match = _TOML_DOTTED_FEATURE_BOOLEAN.fullmatch(line)
        if table is None and dotted_feature_match:
            key = dotted_feature_match.group(1).lower()
            value = dotted_feature_match.group(2).lower() == "true"
            if key == "hooks":
                canonical_hooks_enabled = value
            else:
                deprecated_hooks_enabled = value
            continue
        inline_features_match = _TOML_INLINE_FEATURES.fullmatch(line)
        if table is None and inline_features_match:
            for inline_boolean in _TOML_INLINE_BOOLEAN.finditer(
                inline_features_match.group(1)
            ):
                key = inline_boolean.group(1).lower()
                value = inline_boolean.group(2).lower() == "true"
                if key == "hooks":
                    canonical_hooks_enabled = value
                else:
                    deprecated_hooks_enabled = value
            continue
        table_match = _TOML_ARRAY_TABLE.fullmatch(line)
        if table_match:
            table = table_match.group(1)
            if _is_hook_event_table(table):
                inline_hooks = True
            continue
        table_match = _TOML_TABLE.fullmatch(line)
        if table_match:
            table = table_match.group(1)
            if _is_hook_event_table(table):
                inline_hooks = True
            continue
        if table == "hooks" and _TOML_HOOK_EVENT_ASSIGNMENT.match(line):
            inline_hooks = True
            continue
        if table is None and _TOML_DOTTED_HOOK_EVENT.match(line):
            inline_hooks = True
            continue
        boolean_match = _TOML_BOOLEAN.fullmatch(line)
        if boolean_match:
            key = boolean_match.group(1)
            value = boolean_match.group(2).lower() == "true"
            if table == "features" and key == "hooks":
                canonical_hooks_enabled = value
            elif table == "features" and key == "codex_hooks":
                deprecated_hooks_enabled = value
            elif table is None and key == "allow_managed_hooks_only":
                managed_only = value
            continue
        if table is None and _TOML_INLINE_HOOKS.match(line):
            inline_hooks = any(
                re.search(rf"\b{re.escape(event_name)}\s*=", line)
                for event_name in CODEX_HOOK_EVENT_NAMES
            )

    return {
        "hooksEnabled": (
            canonical_hooks_enabled
            if canonical_hooks_enabled is not None
            else deprecated_hooks_enabled
        ),
        "managedOnly": managed_only,
        "inlineHooks": inline_hooks,
    }


def _diagnostics_from_settings(settings: Dict[str, Any]) -> Dict[str, Any]:
    blocking_status = None
    if settings["hooksEnabled"] is False:
        blocking_status = "hooks_disabled"
    elif settings["managedOnly"] is True:
        blocking_status = "managed_hooks_only"
    warnings = (
        [CONFIG_WARNING_INLINE_HOOKS]
        if settings["inlineHooks"]
        else []
    )
    return {"blockingStatus": blocking_status, "warnings": warnings}


def config_hook_diagnostics(path: Path) -> Dict[str, Any]:
    settings = _hook_settings(path)
    # Codex defines allow_managed_hooks_only only in requirements.toml. A
    # similarly named key in an ordinary config is not an effective policy.
    settings["managedOnly"] = None
    return _diagnostics_from_settings(settings)


def effective_hook_diagnostics(
    config_path: Path,
    requirements_path: Optional[Path] = None,
    system_config_path: Path = SYSTEM_CONFIG_PATH,
) -> Dict[str, Any]:
    """Apply readable system requirements over ordinary user hook settings.

    Cloud and MDM policy remain Codex-owned security boundaries; a real event is
    still the only connection confirmation. The public Unix requirements file
    is safe to inspect and prevents a known local policy from looking installed.
    """
    if requirements_path is None:
        requirements_path = SYSTEM_REQUIREMENTS_PATH
        test_requirements = os.environ.get("AGENT_MEONG_E2E_REQUIREMENTS_PATH")
        if test_requirements and os.environ.get("AGENT_MEONG_E2E_REPORT"):
            requirements_path = Path(test_requirements)

    user = _hook_settings(config_path)
    system = _hook_settings(system_config_path)
    requirements = _hook_settings(requirements_path)
    ordinary = {
        "hooksEnabled": (
            user["hooksEnabled"]
            if user["hooksEnabled"] is not None
            else system["hooksEnabled"]
        ),
        "inlineHooks": user["inlineHooks"] or system["inlineHooks"],
    }
    effective = {
        "hooksEnabled": (
            requirements["hooksEnabled"]
            if requirements["hooksEnabled"] is not None
            else ordinary["hooksEnabled"]
        ),
        "managedOnly": requirements["managedOnly"],
        "inlineHooks": ordinary["inlineHooks"],
    }
    return _diagnostics_from_settings(effective)


def status_result(
    status: str,
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
) -> Dict[str, Any]:
    paths = user_paths(home, codex_home)
    diagnostics = effective_hook_diagnostics(paths["config"])
    unmanaged_status = user_hook_status(
        home=home,
        codex_home=codex_home,
        diagnose_config=False,
    )
    try:
        instance_id = installed_instance_id(paths["instance"])
    except (OSError, ValueError):
        instance_id = None
    result: Dict[str, Any] = {
        "status": status,
        "definitionId": HOOK_DEFINITION_ID,
        "instanceId": instance_id,
        "managedHookPresent": unmanaged_status in {
            "installed", "needs_repair", "newer_version"
        },
    }
    if status == "newer_version":
        result["message"] = (
            "A newer agent-meong hook is installed; this version did not "
            "change or remove it. / 더 새로운 agent-meong hook이 설치되어 있어 "
            "현재 버전으로 변경하거나 제거하지 않았습니다."
        )
    warnings = diagnostics["warnings"]
    if warnings:
        result["warnings"] = warnings
    return result


def install_user_hook(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
    source: Optional[Path] = None,
) -> str:
    paths = user_paths(home, codex_home)
    blocking_status = effective_hook_diagnostics(paths["config"])["blockingStatus"]
    if blocking_status is not None:
        return blocking_status
    source_path = (source or Path(__file__)).resolve()
    handler = hook_handler(paths["adapter"])
    legacy_command = hook_handler(paths["legacyAdapter"])["command"]
    # An existing symlink or special file must abort before hooks.json changes.
    # Do not create empty managed directories until the hook document itself is
    # known to be valid.
    _preflight_managed_paths(paths, create_parents=False)
    with hooks_write_lock(paths["hooks"]):
        document = read_hooks_document(paths["hooks"])
        if contains_newer_agent_meong_handler(document):
            return "newer_version"
        remove_agent_meong_handlers(
            document,
            expected_command=handler["command"],
            legacy_command=legacy_command,
        )
        hooks = document["hooks"]
        for event_name in USER_HOOK_EVENTS:
            groups = hooks.setdefault(event_name, [])
            groups.append({"hooks": [dict(handler)]})
        _preflight_managed_paths(paths, create_parents=True)
        adapter_snapshot = _managed_file_snapshot(paths["adapter"])
        instance_snapshot = _managed_file_snapshot(paths["instance"])
        try:
            copy_adapter_atomic(source_path, paths["adapter"])
            ensure_instance_id(paths["instance"])
            _preflight_managed_paths(paths, create_parents=False)
            write_json_atomic(paths["hooks"], document)
        except Exception:
            _restore_managed_file(paths["adapter"], adapter_snapshot)
            _restore_managed_file(paths["instance"], instance_snapshot)
            raise
    return user_hook_status(home=home, codex_home=codex_home, source=source_path)


def uninstall_user_hook(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
) -> str:
    paths = user_paths(home, codex_home)
    expected_command = hook_handler(paths["adapter"])["command"]
    legacy_command = hook_handler(paths["legacyAdapter"])["command"]
    # Reject unsafe managed entries before removing their live hook commands.
    _preflight_managed_paths(paths, create_parents=False)
    with hooks_write_lock(paths["hooks"]):
        _, hooks_exist = _resolved_regular_path(paths["hooks"])
        if hooks_exist:
            document = read_hooks_document(paths["hooks"])
            if contains_newer_agent_meong_handler(document):
                return "newer_version"
        else:
            document = {"hooks": {}}
        next_document = copy.deepcopy(document)
        changed = remove_agent_meong_handlers(
            next_document,
            expected_command=expected_command,
            legacy_command=legacy_command,
        )
        _preflight_managed_paths(paths, create_parents=False)
        # Commit the hook removal before deleting its command target. If this
        # process is interrupted, the only safe residue is an inert adapter;
        # never leave a live hook pointing at a missing executable.
        if changed:
            write_json_atomic(paths["hooks"], next_document)
        _delete_managed_file(paths["adapter"])
        _delete_managed_file(paths["instance"])
    _remove_empty_managed_directories(paths["adapter"])
    return user_hook_status(
        home=home,
        codex_home=codex_home,
        diagnose_config=False,
    )


def user_hook_status(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
    source: Optional[Path] = None,
    diagnose_config: bool = True,
) -> str:
    paths = user_paths(home, codex_home)
    if diagnose_config:
        blocking_status = effective_hook_diagnostics(paths["config"])["blockingStatus"]
        if blocking_status is not None:
            return blocking_status
    try:
        document = read_hooks_document(paths["hooks"])
    except (json.JSONDecodeError, OSError, ValueError):
        return "invalid"
    if contains_newer_agent_meong_handler(document):
        return "newer_version"
    expected_handler = hook_handler(paths["adapter"])
    expected_command = expected_handler["command"]
    legacy_command = hook_handler(paths["legacyAdapter"])["command"]
    exact_events = set()
    found_managed_handler = False
    managed_handler_count = 0
    for event_name, groups in document["hooks"].items():
        for group in groups:
            handlers = group["hooks"]
            for handler in handlers:
                if not is_agent_meong_handler(
                    handler,
                    expected_command=expected_command,
                    legacy_command=legacy_command,
                ):
                    continue
                found_managed_handler = True
                managed_handler_count += 1
            if group == {"hooks": [expected_handler]}:
                exact_events.add(event_name)
    source_path = (source or Path(__file__)).resolve()
    try:
        adapter_snapshot = _managed_file_snapshot(paths["adapter"])
        instance_snapshot = _managed_file_snapshot(paths["instance"])
        instance_matches = installed_instance_id(paths["instance"]) is not None
    except (OSError, ValueError):
        return "invalid"
    adapter_matches = (
        adapter_snapshot is not None
        and hashlib.sha256(adapter_snapshot[0]).digest()
        == hashlib.sha256(source_path.read_bytes()).digest()
    )
    if (
        adapter_matches
        and instance_matches
        and exact_events == set(USER_HOOK_EVENTS)
        and managed_handler_count == len(USER_HOOK_EVENTS)
    ):
        return "installed"
    if adapter_snapshot is not None or instance_snapshot is not None or found_managed_handler:
        return "needs_repair"
    return "not_installed"


def send(observation: Dict[str, Any]) -> bool:
    path = socket_path()
    try:
        endpoint = os.lstat(path)
    except OSError:
        return delivery_failed("endpoint_missing")
    if not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.getuid():
        return delivery_failed("unsafe_endpoint")

    message = json.dumps(observation, separators=(",", ":")).encode("utf-8") + b"\n"
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.15)
    try:
        client.connect(path)
        if peer_effective_uid(client) != os.getuid():
            return delivery_failed("peer_mismatch")
        client.sendall(message)
        return True
    except OSError:
        return delivery_failed("connect_failed")
    finally:
        client.close()


def delivery_failed(reason: str) -> bool:
    if os.environ.get("AGENT_MEONG_E2E_DELIVERY_DIAGNOSTICS") == "1":
        print(f"agent-meong delivery failed: {reason}", file=sys.stderr)
    return False


def peer_effective_uid(client: socket.socket) -> Optional[int]:
    """Return the connected Unix peer's effective uid, failing closed."""
    try:
        getpeereid = ctypes.CDLL(None, use_errno=True).getpeereid
    except (AttributeError, OSError):
        return None
    user_id = ctypes.c_uint()
    group_id = ctypes.c_uint()
    getpeereid.argtypes = (
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_uint),
        ctypes.POINTER(ctypes.c_uint),
    )
    getpeereid.restype = ctypes.c_int
    if getpeereid(client.fileno(), ctypes.byref(user_id), ctypes.byref(group_id)) != 0:
        return None
    return int(user_id.value)


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
            status = install_user_hook()
            print(json.dumps(status_result(status)))
            return 0
        if args.uninstall:
            status = uninstall_user_hook()
            print(json.dumps(status_result(status)))
            return 0
        if args.status:
            status = user_hook_status()
            print(json.dumps(status_result(status)))
            return 0
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(
            json.dumps({"status": "error", "message": str(error)}),
            file=sys.stderr,
        )
        return 1
    payload = read_payload()
    observation = normalize(payload) if payload is not None else None
    if observation is None:
        return 0
    if args.print_only:
        print(json.dumps(observation, separators=(",", ":")))
    else:
        delivered = send(observation)
        if (
            os.environ.get("AGENT_MEONG_E2E_REQUIRE_DELIVERY") == "1"
            and not delivered
        ):
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
