#!/usr/bin/python3
"""Normalize a Codex hook event and forward metadata to agent-meong."""

from __future__ import annotations

import os
import stat
import sys


def _can_skip_inactive_delivery() -> bool:
    """Exit before loading the adapter when the local receiver is absent."""
    if __name__ != "__main__" or len(sys.argv) != 1:
        return False
    if (
        os.environ.get("AGENT_MEONG_E2E_DELIVERY_DIAGNOSTICS") == "1"
        or os.environ.get("AGENT_MEONG_E2E_REQUIRE_DELIVERY") == "1"
    ):
        return False
    path = os.environ.get(
        "AGENT_MEONG_SOCKET", f"/tmp/agent-meong-{os.getuid()}.sock"
    )
    try:
        endpoint = os.lstat(path)
    except OSError:
        return True
    return not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.getuid()


def _discard_inactive_payload() -> None:
    """Honor the hook stdin contract without parsing or retaining its payload."""
    try:
        while sys.stdin.buffer.read(65_536):
            pass
    except (OSError, ValueError):
        pass


if _can_skip_inactive_delivery():
    _discard_inactive_payload()
    raise SystemExit(0)

import contextlib
import ctypes
import errno
import hashlib
import json
import re
import socket
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, NamedTuple, Optional


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
HOOK_VERSION = 6
HOOK_DEFINITION_ID = f"{HOOK_OWNER}/v{HOOK_VERSION}"
OBSERVATION_SOURCE = "openai.codex"
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
RUNTIME_STATUS_READY = "ready"
RUNTIME_STATUS_REVIEW_REQUIRED = "review_required"
RUNTIME_STATUS_DISABLED = "disabled"
RUNTIME_STATUS_UNAVAILABLE = "unavailable"
RUNTIME_EVENT_NAMES = {
    "userPromptSubmit": "UserPromptSubmit",
    "preToolUse": "PreToolUse",
    "permissionRequest": "PermissionRequest",
    "postToolUse": "PostToolUse",
    "subagentStart": "SubagentStart",
    "subagentStop": "SubagentStop",
    "stop": "Stop",
}
RUNTIME_HASH_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
# Each app-server phase gets its own budget so a slow private bootstrap cannot
# consume the real hooks/list query's entire timeout. Two phases still finish
# within the macOS launcher's 40-second adapter deadline, including
# serialized product probes, scheduling slack, and a rare executable-validation
# retry on install.
RUNTIME_QUERY_TIMEOUT_SECONDS = 2.5
RUNTIME_MAX_OUTPUT_BYTES = 1_048_576


class _CodexRuntimeExecutable(NamedTuple):
    path: Path
    path_prefix: Optional[Path] = None


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

    # The same raw Codex identifiers can legitimately appear under two
    # CODEX_HOME values. Namespace every derived identifier by the opaque
    # installation instance so their actors and retry IDs never collide in the
    # shared receiver. The instance itself reveals no CODEX_HOME path.
    integration_instance = integration_instance_id()
    session_id = opaque_id("session", integration_instance, raw_session_id)
    actor_id = main_actor_id(integration_instance, raw_session_id)
    parent_actor_id = None
    agent_id = string_value(payload.get("agent_id"))
    if event_name in {"SubagentStart", "SubagentStop"} and agent_id is None:
        return None
    if agent_id is not None:
        # Codex includes this context on lifecycle and tool/prompt events
        # emitted inside a thread-spawned child. Keep every event for that
        # child on the same privacy-safe logical actor.
        actor_id = opaque_id(
            "actor.agent", integration_instance, raw_session_id, agent_id
        )
        parent_actor_id = main_actor_id(integration_instance, raw_session_id)

    raw_turn_id = string_value(payload.get("turn_id"))
    scope_id = (
        opaque_id("turn", integration_instance, raw_session_id, raw_turn_id)
        if raw_turn_id
        else None
    )
    timestamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    observation: Dict[str, Any] = {
        "schemaVersion": 0,
        "eventId": normalized_event_id(
            payload,
            event_name,
            integration_instance,
            raw_session_id,
            event_id,
        ),
        "source": OBSERVATION_SOURCE,
        "sessionId": session_id,
        "actorId": actor_id,
        "occurredAt": timestamp.isoformat().replace("+00:00", "Z"),
        "kind": kind,
        "integrationVersion": HOOK_DEFINITION_ID,
        "integrationInstance": integration_instance,
    }
    if parent_actor_id is not None:
        observation["parentActorId"] = parent_actor_id
    if scope_id is not None:
        observation["scopeId"] = scope_id

    tool_category = categorize_tool(payload.get("tool_name"))
    if event_name in {"PreToolUse", "PostToolUse", "PermissionRequest"}:
        observation["toolCategory"] = tool_category

    return observation


def main_actor_id(integration_instance: str, raw_session_id: str) -> str:
    return opaque_id("actor.main", integration_instance, raw_session_id)


def opaque_id(kind: str, *values: str) -> str:
    digest = hashlib.sha256("\0".join((kind, *values)).encode("utf-8")).hexdigest()
    return digest[:32]


def normalized_event_id(
    payload: Dict[str, Any],
    event_name: str,
    integration_instance: str,
    raw_session_id: str,
    supplied_event_id: Optional[str],
) -> str:
    if supplied_event_id is None:
        return stable_event_id(
            payload, event_name, integration_instance, raw_session_id
        )
    return opaque_id("event.supplied", integration_instance, supplied_event_id)


def stable_event_id(
    payload: Dict[str, Any],
    event_name: str,
    integration_instance: str,
    raw_session_id: str,
) -> str:
    turn_id = string_value(payload.get("turn_id"))
    agent_id = string_value(payload.get("agent_id"))
    tool_use_id = string_value(payload.get("tool_use_id"))
    stable = event_name in {"UserPromptSubmit", "Stop"} and turn_id is not None
    stable = stable or event_name in {"SubagentStart", "SubagentStop"} and agent_id is not None
    stable = stable or event_name in {"PreToolUse", "PostToolUse"} and tool_use_id is not None
    if not stable:
        return opaque_id("event.random", integration_instance, str(uuid.uuid4()))
    parts = [
        integration_instance,
        raw_session_id,
        turn_id or "",
        agent_id or "",
        tool_use_id or "",
        event_name,
    ]
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
        "forwarder": (
            support / "codex-hooks" / codex_identity / "codex_hook_forwarder"
        ),
        "instance": support / "codex-hooks" / codex_identity / ".instance-id",
        "legacyAdapter": support / "codex_hook.py",
        "hooks": codex_root / "hooks.json",
        "config": codex_root / "config.toml",
    }


def hook_handler(forwarder_path: Path) -> Dict[str, Any]:
    import shlex

    return {
        "type": "command",
        "command": shlex.quote(str(forwarder_path)),
        "timeout": 2,
        "statusMessage": HOOK_STATUS_MESSAGE,
    }


def legacy_python_command(adapter_path: Path) -> str:
    """Return the exact command used by v1-v5 Python hook definitions."""
    import shlex

    return f"/usr/bin/python3 {shlex.quote(str(adapter_path))}"


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
        path.name not in {"codex_hook.py", "codex_hook_forwarder", ".instance-id"}
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
        base_info = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(base_info.st_mode)
            or base_info.st_uid != os.getuid()
            or stat.S_IMODE(base_info.st_mode) & 0o022
        ):
            raise ValueError(f"{base} is not a private user-owned directory")
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
            child_info = os.fstat(child)
            if (
                not stat.S_ISDIR(child_info.st_mode)
                or child_info.st_uid != os.getuid()
                or stat.S_IMODE(child_info.st_mode) & 0o022
            ):
                os.close(child)
                raise ValueError(
                    f"{directory} contains a non-private managed directory"
                )
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
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
        raise ValueError(f"{path} must be a private user-owned file")
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
            if (
                opened_info.st_uid != os.getuid()
                or stat.S_IMODE(opened_info.st_mode) & 0o022
            ):
                raise ValueError(f"{path} must be a private user-owned file")
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
                os.fsync(handle.fileno())
            os.replace(
                temporary_name,
                path.name,
                src_dir_fd=directory_descriptor,
                dst_dir_fd=directory_descriptor,
            )
            temporary_name = ""
            os.fsync(directory_descriptor)
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
    _managed_file_exists(paths["forwarder"], create_parents=create_parents)
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


def reconcile_agent_meong_handlers(
    document: Dict[str, Any],
    *,
    handler: Dict[str, Any],
    legacy_command: Optional[str] = None,
) -> bool:
    """Install one canonical handler per event without moving its stable slot.

    Codex identifies user hook definitions partly by their position within an
    event. Removing an existing agent-meong group and appending its replacement
    would therefore also change the positional keys of every user group that
    followed it. For each supported event, keep the first group whose handlers
    are all owned by agent-meong as the deterministic anchor and replace that
    group in place.

    Other owned occurrences are duplicates. Remove only their owned handlers,
    preserving unrelated handlers, group metadata, and order. A mixed group is
    never treated as the anchor because replacing it wholesale could discard a
    user's matcher or handlers; when no dedicated anchor exists, preserve the
    remaining groups and append a new canonical group. Owned handlers attached
    to unsupported events are removed without otherwise changing those events.
    """
    hooks = document.setdefault("hooks", {})
    changed = False
    expected_command = str(handler["command"])
    supported_events = set(USER_HOOK_EVENTS)

    for event_name, groups in list(hooks.items()):
        anchor_index: Optional[int] = None
        if event_name in supported_events:
            for group_index, group in enumerate(groups):
                handlers = group.get("hooks", [])
                if handlers and all(
                    is_agent_meong_handler(
                        candidate,
                        expected_command=expected_command,
                        legacy_command=legacy_command,
                    )
                    for candidate in handlers
                ):
                    anchor_index = group_index
                    break

        next_groups = []
        event_changed = False
        for group_index, group in enumerate(groups):
            handlers = group.get("hooks", [])
            owned = [
                is_agent_meong_handler(
                    candidate,
                    expected_command=expected_command,
                    legacy_command=legacy_command,
                )
                for candidate in handlers
            ]
            if group_index == anchor_index:
                canonical_group = {"hooks": [dict(handler)]}
                next_groups.append(canonical_group)
                if group != canonical_group:
                    event_changed = True
                continue
            if not any(owned):
                next_groups.append(group)
                continue

            kept_handlers = [
                candidate
                for candidate, is_owned in zip(handlers, owned)
                if not is_owned
            ]
            event_changed = True
            if kept_handlers:
                next_group = dict(group)
                next_group["hooks"] = kept_handlers
                next_groups.append(next_group)

        if event_name in supported_events and anchor_index is None:
            next_groups.append({"hooks": [dict(handler)]})
            event_changed = True

        if not event_changed:
            continue
        changed = True
        if next_groups:
            hooks[event_name] = next_groups
        else:
            hooks.pop(event_name, None)

    for event_name in USER_HOOK_EVENTS:
        if event_name in hooks:
            continue
        hooks[event_name] = [{"hooks": [dict(handler)]}]
        changed = True
    return changed


class AtomicReplaceCommittedError(OSError):
    """Durability failed after the replacement became logically visible."""


def write_json_atomic(path: Path, document: Dict[str, Any]) -> None:
    import tempfile

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
            handle.flush()
            os.fchmod(handle.fileno(), existing_mode)
            os.fsync(handle.fileno())
        os.replace(temporary_path, target)
        try:
            directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            directory_flags |= getattr(os, "O_DIRECTORY", 0)
            directory_descriptor = os.open(target.parent, directory_flags)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        except OSError as error:
            raise AtomicReplaceCommittedError(
                "The hook configuration was replaced but its directory was not synchronized"
            ) from error
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
    snapshot = _managed_file_snapshot(path)
    if snapshot is not None:
        contents, mode = snapshot
        candidate = contents.decode("utf-8").strip()
        if INSTANCE_ID_PATTERN.fullmatch(candidate):
            if mode != 0o600:
                write_private_text_atomic(path, candidate)
            return candidate
    value = uuid.uuid4().hex[:24]
    write_private_text_atomic(path, value)
    return value


@contextlib.contextmanager
def hooks_write_lock(path: Path):
    """Serialize agent-meong read/modify/write cycles for one hooks path."""
    import fcntl
    import tempfile

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


def copy_forwarder_atomic(source: Path, destination: Path) -> None:
    _write_managed_bytes_atomic(destination, source.read_bytes(), 0o700)


def prewarm_forwarder(path: Path) -> None:
    """Pay macOS's first executable-validation cost outside the hook timeout."""
    import subprocess

    for attempt in range(2):
        try:
            completed = subprocess.run(
                [str(path), "--print"],
                input=b"{}\n",
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
                close_fds=True,
            )
        except subprocess.TimeoutExpired as error:
            if attempt == 0:
                continue
            raise OSError(
                "The installed native Codex forwarder did not start in time"
            ) from error
        if completed.returncode == 0:
            return
        raise OSError("The installed native Codex forwarder did not start")


def forwarder_source_path(source: Optional[Path] = None) -> Path:
    """Locate the signed/built native event forwarder on management paths."""
    explicit = source or (
        Path(value).expanduser()
        if (value := os.environ.get("AGENT_MEONG_FORWARDER_SOURCE"))
        else None
    )
    module_path = Path(__file__).resolve()
    candidates = [
        module_path.parent.parent / "Helpers/codex_hook_forwarder",
        explicit,
    ]
    for candidate in candidates:
        if candidate is None:
            continue
        try:
            path = candidate.resolve(strict=True)
            metadata = path.stat()
        except (OSError, RuntimeError):
            continue
        if stat.S_ISREG(metadata.st_mode) and os.access(path, os.X_OK):
            return path
    raise ValueError(
        "The native Codex forwarder is missing; rebuild or reinstall agent-meong. / "
        "native Codex forwarder가 없습니다. agent-meong을 다시 build하거나 설치하세요."
    )


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


def _runtime_result(status: str, events: Any = ()) -> Dict[str, Any]:
    event_set = {
        event_name
        for event_name in events
        if event_name in USER_HOOK_EVENTS
    }
    return {
        "runtimeStatus": status,
        "runtimeProblemEvents": [
            event_name
            for event_name in USER_HOOK_EVENTS
            if event_name in event_set
        ],
    }


def _e2e_codex_binary_override() -> Optional[Path]:
    """Return the test-only app-server executable override.

    The production app never accepts a general executable override. Requiring
    E2E report mode prevents ordinary isolated-HOME checks from accidentally
    invoking an executable supplied through their environment.
    """
    value = os.environ.get("AGENT_MEONG_E2E_CODEX_BIN")
    if not value or not os.environ.get("AGENT_MEONG_E2E_REPORT"):
        return None
    return Path(value).expanduser()


def _runtime_probe_allowed(
    *,
    home_was_explicit: bool,
    codex_home_was_explicit: bool,
) -> bool:
    import pwd

    if _e2e_codex_binary_override() is not None:
        return True
    if os.environ.get("AGENT_MEONG_RUNTIME_DIAGNOSTICS") != "1":
        return False
    if home_was_explicit or codex_home_was_explicit:
        return False
    try:
        environment_home = Path.home().resolve(strict=False)
        account_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=False)
    except (KeyError, OSError, RuntimeError):
        return False
    return environment_home == account_home


def _validated_codex_binary(candidate: Path) -> Optional[Path]:
    try:
        resolved = candidate.expanduser().resolve(strict=True)
        info = resolved.stat()
    except (OSError, RuntimeError):
        return None
    if not stat.S_ISREG(info.st_mode) or not os.access(resolved, os.X_OK):
        return None
    if info.st_uid not in {0, os.getuid()} or info.st_mode & 0o022:
        return None
    return resolved


def _nvm_version_key(path: Path) -> tuple[int, int, int, str]:
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", path.parent.parent.name)
    if match is None:
        return (0, 0, 0, path.parent.parent.name)
    return (*map(int, match.groups()), path.parent.parent.name)


def _validated_codex_runtime_executable(
    candidate: Path,
) -> Optional[_CodexRuntimeExecutable]:
    validated = _validated_codex_binary(candidate)
    if validated is None:
        return None
    candidate_directory = candidate.expanduser().parent.resolve(strict=False)
    node = _validated_codex_binary(candidate_directory / "node")
    return _CodexRuntimeExecutable(
        path=validated,
        path_prefix=candidate_directory if node is not None else None,
    )


def _codex_runtime_binaries(home: Path) -> list[_CodexRuntimeExecutable]:
    import shutil

    override = _e2e_codex_binary_override()
    if override is not None:
        validated = _validated_codex_runtime_executable(override)
        return [validated] if validated is not None else []

    # ChatGPT and Codex update independently. Keep one executable from each
    # product so an installed-but-older first app cannot hide a compatible
    # second app. Prefer the system install over a duplicate user install of
    # the same product, matching LaunchServices' usual application ordering.
    app_candidate_groups = (
        (
            Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
            home / "Applications/ChatGPT.app/Contents/Resources/codex",
        ),
        (
            Path("/Applications/Codex.app/Contents/Resources/codex"),
            home / "Applications/Codex.app/Contents/Resources/codex",
        ),
    )
    cli_candidates = []
    path_command = shutil.which("codex")
    if path_command:
        cli_candidates.append(Path(path_command))
    cli_candidates.extend((
        home / ".local/bin/codex",
        home / ".codex/bin/codex",
        Path("/opt/homebrew/bin/codex"),
        Path("/usr/local/bin/codex"),
    ))
    nvm_candidates = sorted(
        (home / ".nvm/versions/node").glob("*/bin/codex"),
        key=_nvm_version_key,
        reverse=True,
    )
    cli_candidates.extend(nvm_candidates)

    selected = []
    for candidates in (*app_candidate_groups, cli_candidates):
        for candidate in candidates:
            validated = _validated_codex_runtime_executable(candidate)
            if validated is not None:
                selected.append(validated)
                break
    unique = []
    seen = set()
    for candidate in selected:
        identity = (
            os.fsencode(candidate.path),
            os.fsencode(candidate.path_prefix) if candidate.path_prefix else None,
        )
        if identity in seen:
            continue
        seen.add(identity)
        unique.append(candidate)
    return unique


def _write_app_server_message(process: Any, message: Dict[str, Any]) -> bool:
    if process.stdin is None:
        return False
    try:
        process.stdin.write(
            json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
        )
        process.stdin.flush()
        return True
    except (BrokenPipeError, OSError):
        return False


def _read_app_server_response(
    process: Any,
    selector: Any,
    state: Dict[str, Any],
    request_id: int,
    deadline: float,
) -> Optional[Dict[str, Any]]:
    import time

    if process.stdout is None:
        return None
    buffer = state["buffer"]
    while True:
        newline = buffer.find(b"\n")
        while newline >= 0:
            line = bytes(buffer[:newline])
            del buffer[:newline + 1]
            if line:
                try:
                    value = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    value = None
                if isinstance(value, dict) and value.get("id") == request_id:
                    return value
            newline = buffer.find(b"\n")

        remaining = deadline - time.monotonic()
        if remaining <= 0 or process.poll() is not None:
            return None
        if not selector.select(remaining):
            return None
        try:
            chunk = os.read(process.stdout.fileno(), 65_536)
        except OSError:
            return None
        if not chunk:
            return None
        state["bytes"] += len(chunk)
        if state["bytes"] > RUNTIME_MAX_OUTPUT_BYTES:
            return None
        buffer.extend(chunk)


def _stop_app_server(process: Any) -> None:
    import subprocess

    if process.stdin is not None:
        with contextlib.suppress(OSError):
            process.stdin.close()
    try:
        if process.poll() is None:
            with contextlib.suppress(OSError):
                process.terminate()
            try:
                process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(OSError):
                    process.kill()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=0.25)
    finally:
        if process.stdout is not None:
            with contextlib.suppress(OSError):
                process.stdout.close()


def _run_codex_hooks_list(
    binary: Path,
    *,
    environment: Dict[str, str],
    probe_cwd: Path,
    probe_log: Path,
    deadline: float,
) -> Optional[Dict[str, Any]]:
    import selectors
    import subprocess

    process: Any = None
    selector: Any = None
    try:
        process = subprocess.Popen(
            [
                str(binary),
                "app-server",
                "-c",
                "analytics.enabled=false",
                "-c",
                "log_dir=" + json.dumps(str(probe_log)),
                "--listen",
                "stdio://",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=probe_cwd,
            env=environment,
            bufsize=0,
            close_fds=True,
        )
        if process.stdout is None:
            return None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        state: Dict[str, Any] = {"buffer": bytearray(), "bytes": 0}
        if not _write_app_server_message(process, {
            "method": "initialize",
            "id": 1,
            "params": {
                "clientInfo": {
                    "name": "agent_meong_hook_diagnostics",
                    "title": "agent-meong hook diagnostics",
                    "version": str(HOOK_VERSION),
                }
            },
        }):
            return None
        initialized = _read_app_server_response(
            process, selector, state, 1, deadline
        )
        if initialized is None or "error" in initialized:
            return None
        if not _write_app_server_message(
            process, {"method": "initialized", "params": {}}
        ):
            return None
        if not _write_app_server_message(process, {
            "method": "hooks/list",
            "id": 2,
            "params": {"cwds": [str(probe_cwd)]},
        }):
            return None
        response = _read_app_server_response(process, selector, state, 2, deadline)
        if response is None or "error" in response:
            return None
        result = response.get("result")
        return result if isinstance(result, dict) else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    finally:
        if selector is not None:
            selector.close()
        if process is not None:
            _stop_app_server(process)


def _runtime_process_environment(
    *,
    home: Path,
    executable: _CodexRuntimeExecutable,
) -> Dict[str, str]:
    """Build the least-privilege environment for read-only Codex diagnostics."""
    source = os.environ
    environment = {
        key: source[key]
        for key in ("PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_OSS_BASE_URL")
        if source.get(key)
    }
    environment.update({
        key: value
        for key, value in source.items()
        if key.startswith("LC_") and value
    })
    if _e2e_codex_binary_override() is not None:
        environment.update({
            key: value
            for key, value in source.items()
            if key.startswith("AGENT_MEONG_E2E_")
        })
    if executable.path_prefix is not None:
        environment["PATH"] = os.pathsep.join((
            str(executable.path_prefix),
            environment.get("PATH", "/usr/bin:/bin"),
        )).rstrip(os.pathsep)
    else:
        environment.setdefault("PATH", "/usr/bin:/bin")
    environment["HOME"] = str(home)
    return environment


def _query_codex_runtime_hooks(
    binary: Any,
    *,
    home: Path,
    codex_home: Path,
) -> Optional[Dict[str, Any]]:
    """Read Codex hook metadata without changing trust or user task state."""
    import subprocess
    import tempfile
    import time

    probe_home: Any = None
    try:
        probe_home = tempfile.TemporaryDirectory(
            prefix="agent-meong-codex-runtime-"
        )
        probe_root = Path(probe_home.name).resolve(strict=True)
        bootstrap_home = probe_root / "bootstrap-home"
        bootstrap_cwd = probe_root / "bootstrap-cwd"
        probe_cwd = probe_root / "cwd"
        probe_log = probe_root / "log"
        sqlite_home = probe_root / "state"
        for directory in (
            bootstrap_home,
            bootstrap_cwd,
            probe_cwd,
            probe_log,
            sqlite_home,
        ):
            directory.mkdir(mode=0o700)

        executable = (
            binary
            if isinstance(binary, _CodexRuntimeExecutable)
            else _CodexRuntimeExecutable(path=Path(binary))
        )
        environment = _runtime_process_environment(
            home=home,
            executable=executable,
        )
        environment["CODEX_SQLITE_HOME"] = str(sqlite_home)
        environment["RUST_LOG"] = "error"
        # A fresh state directory normally backfills the real Codex session
        # store before initialize responds. Bootstrap that private database
        # against an empty CODEX_HOME first. The real hooks/config can then be
        # inspected through the same official read-only protocol without
        # opening, copying, or modifying the user's Codex state database.
        bootstrap_environment = environment.copy()
        bootstrap_environment["CODEX_HOME"] = str(bootstrap_home)
        if _run_codex_hooks_list(
            executable.path,
            environment=bootstrap_environment,
            probe_cwd=bootstrap_cwd,
            probe_log=probe_log,
            deadline=time.monotonic() + RUNTIME_QUERY_TIMEOUT_SECONDS,
        ) is None:
            return None

        runtime_environment = environment.copy()
        runtime_environment["CODEX_HOME"] = str(codex_home)
        return _run_codex_hooks_list(
            executable.path,
            environment=runtime_environment,
            probe_cwd=probe_cwd,
            probe_log=probe_log,
            deadline=time.monotonic() + RUNTIME_QUERY_TIMEOUT_SECONDS,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    finally:
        if probe_home is not None:
            probe_home.cleanup()


def _runtime_paths_match(left: Any, right: Path) -> bool:
    if not isinstance(left, str) or not left:
        return False
    try:
        return Path(left).resolve(strict=False) == right.resolve(strict=False)
    except (OSError, RuntimeError):
        return False


def _classify_runtime_hooks(
    payload: Dict[str, Any],
    paths: Dict[str, Path],
) -> Dict[str, Any]:
    data = payload.get("data")
    if not isinstance(data, list):
        return _runtime_result(RUNTIME_STATUS_UNAVAILABLE, USER_HOOK_EVENTS)

    expected_command = hook_handler(paths["forwarder"])["command"]
    by_event: Dict[str, list[Dict[str, Any]]] = {
        event_name: [] for event_name in USER_HOOK_EVENTS
    }
    for item in data:
        if not isinstance(item, dict) or not isinstance(item.get("hooks"), list):
            continue
        for hook in item["hooks"]:
            if not isinstance(hook, dict) or hook.get("source") != "user":
                continue
            event_name = RUNTIME_EVENT_NAMES.get(hook.get("eventName"))
            if event_name not in by_event:
                continue
            if (
                hook.get("command") != expected_command
                and hook.get("statusMessage") != HOOK_STATUS_MESSAGE
            ):
                continue
            by_event[event_name].append(hook)

    unavailable = set()
    disabled = set()
    review = set()
    for event_name, hooks in by_event.items():
        if len(hooks) != 1:
            unavailable.add(event_name)
            continue
        hook = hooks[0]
        structurally_valid = (
            hook.get("handlerType") == "command"
            and hook.get("command") == expected_command
            and hook.get("timeoutSec") == 2
            and hook.get("statusMessage") == HOOK_STATUS_MESSAGE
            and hook.get("matcher") is None
            and hook.get("pluginId") is None
            and hook.get("isManaged") is False
            and _runtime_paths_match(hook.get("sourcePath"), paths["hooks"])
            and isinstance(hook.get("currentHash"), str)
            and RUNTIME_HASH_PATTERN.fullmatch(hook["currentHash"]) is not None
        )
        if not structurally_valid:
            unavailable.add(event_name)
            continue
        if hook.get("enabled") is not True:
            disabled.add(event_name)
            continue
        trust_status = hook.get("trustStatus")
        if trust_status in {"untrusted", "modified"}:
            review.add(event_name)
        elif trust_status != "trusted":
            unavailable.add(event_name)

    if unavailable:
        return _runtime_result(RUNTIME_STATUS_UNAVAILABLE, unavailable)
    if disabled:
        return _runtime_result(RUNTIME_STATUS_DISABLED, disabled)
    if review:
        return _runtime_result(RUNTIME_STATUS_REVIEW_REQUIRED, review)
    return _runtime_result(RUNTIME_STATUS_READY)


def runtime_hook_diagnostics(
    status: str,
    *,
    paths: Dict[str, Path],
    home: Path,
    allow_probe: bool,
) -> Dict[str, Any]:
    if status in {"hooks_disabled", "managed_hooks_only"}:
        return _runtime_result(RUNTIME_STATUS_DISABLED, USER_HOOK_EVENTS)
    if status != "installed":
        return _runtime_result(RUNTIME_STATUS_UNAVAILABLE)
    if not allow_probe:
        return _runtime_result(RUNTIME_STATUS_UNAVAILABLE, USER_HOOK_EVENTS)

    binaries = _codex_runtime_binaries(home)
    if not binaries:
        return _runtime_result(RUNTIME_STATUS_UNAVAILABLE, USER_HOOK_EVENTS)
    # Independently updated app and CLI binaries can race when two app-server
    # probes read the same user CODEX_HOME at once. That turns a trusted hook
    # into a false "unavailable" result. Keep the bounded probes serialized;
    # at most three candidates each receive two 2.5-second phases.
    payloads = [
        _query_codex_runtime_hooks(
            binary,
            home=home,
            codex_home=paths["hooks"].parent,
        )
        for binary in binaries
    ]
    results = []
    for payload in payloads:
        results.append(
            _classify_runtime_hooks(payload, paths)
            if payload is not None
            else _runtime_result(RUNTIME_STATUS_UNAVAILABLE, USER_HOOK_EVENTS)
        )

    usable_results = [
        result
        for result in results
        if result["runtimeStatus"] != RUNTIME_STATUS_UNAVAILABLE
    ]
    if not usable_results:
        return _runtime_result(RUNTIME_STATUS_UNAVAILABLE, USER_HOOK_EVENTS)
    statuses = {result["runtimeStatus"] for result in usable_results}
    for candidate in (
        RUNTIME_STATUS_DISABLED,
        RUNTIME_STATUS_REVIEW_REQUIRED,
    ):
        if candidate in statuses:
            problems = {
                event_name
                for result in usable_results
                if result["runtimeStatus"] == candidate
                for event_name in result["runtimeProblemEvents"]
            }
            return _runtime_result(candidate, problems)
    return _runtime_result(RUNTIME_STATUS_READY)


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
    result.update(runtime_hook_diagnostics(
        status,
        paths=paths,
        home=(home or Path.home()).expanduser(),
        allow_probe=(
            _runtime_probe_allowed(
                home_was_explicit=home is not None,
                codex_home_was_explicit=codex_home is not None,
            )
        ),
    ))
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
    forwarder_source: Optional[Path] = None,
) -> str:
    paths = user_paths(home, codex_home)
    blocking_status = effective_hook_diagnostics(paths["config"])["blockingStatus"]
    if blocking_status is not None:
        return blocking_status
    source_path = (source or Path(__file__)).resolve()
    native_source_path = forwarder_source_path(forwarder_source)
    handler = hook_handler(paths["forwarder"])
    legacy_command = legacy_python_command(paths["legacyAdapter"])
    # An existing symlink or special file must abort before hooks.json changes.
    # Do not create empty managed directories until the hook document itself is
    # known to be valid.
    _preflight_managed_paths(paths, create_parents=False)
    with hooks_write_lock(paths["hooks"]):
        document = read_hooks_document(paths["hooks"])
        if contains_newer_agent_meong_handler(document):
            return "newer_version"
        hooks_changed = reconcile_agent_meong_handlers(
            document,
            handler=handler,
            legacy_command=legacy_command,
        )
        _preflight_managed_paths(paths, create_parents=True)
        adapter_snapshot = _managed_file_snapshot(paths["adapter"])
        forwarder_snapshot = _managed_file_snapshot(paths["forwarder"])
        instance_snapshot = _managed_file_snapshot(paths["instance"])
        try:
            copy_adapter_atomic(source_path, paths["adapter"])
            copy_forwarder_atomic(native_source_path, paths["forwarder"])
            ensure_instance_id(paths["instance"])
            prewarm_forwarder(paths["forwarder"])
            _preflight_managed_paths(paths, create_parents=False)
            if hooks_changed:
                write_json_atomic(paths["hooks"], document)
        except AtomicReplaceCommittedError:
            # hooks.json already points at the new command. Keep every target
            # in place even though the durability warning must reach the
            # caller; rolling them back would create a live missing command.
            raise
        except Exception:
            _restore_managed_file(paths["adapter"], adapter_snapshot)
            _restore_managed_file(paths["forwarder"], forwarder_snapshot)
            _restore_managed_file(paths["instance"], instance_snapshot)
            raise
    return user_hook_status(
        home=home,
        codex_home=codex_home,
        source=source_path,
        forwarder_source=native_source_path,
    )


def uninstall_user_hook(
    *,
    home: Optional[Path] = None,
    codex_home: Optional[Path] = None,
) -> str:
    import copy

    paths = user_paths(home, codex_home)
    expected_command = hook_handler(paths["forwarder"])["command"]
    legacy_command = legacy_python_command(paths["legacyAdapter"])
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
        _delete_managed_file(paths["forwarder"])
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
    forwarder_source: Optional[Path] = None,
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
    expected_handler = hook_handler(paths["forwarder"])
    expected_command = expected_handler["command"]
    legacy_command = legacy_python_command(paths["legacyAdapter"])
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
        forwarder_snapshot = _managed_file_snapshot(paths["forwarder"])
        instance_snapshot = _managed_file_snapshot(paths["instance"])
        instance_matches = (
            installed_instance_id(paths["instance"]) is not None
            and instance_snapshot is not None
            and instance_snapshot[1] == 0o600
        )
    except (OSError, ValueError):
        return "invalid"
    adapter_matches = (
        adapter_snapshot is not None
        and adapter_snapshot[1] == 0o600
        and hashlib.sha256(adapter_snapshot[0]).digest()
        == hashlib.sha256(source_path.read_bytes()).digest()
    )
    try:
        native_source_path = forwarder_source_path(forwarder_source)
        forwarder_matches = (
            forwarder_snapshot is not None
            and forwarder_snapshot[1] == 0o700
            and hashlib.sha256(forwarder_snapshot[0]).digest()
            == hashlib.sha256(native_source_path.read_bytes()).digest()
        )
    except (OSError, ValueError):
        forwarder_matches = False
    if (
        adapter_matches
        and forwarder_matches
        and instance_matches
        and exact_events == set(USER_HOOK_EVENTS)
        and managed_handler_count == len(USER_HOOK_EVENTS)
    ):
        return "installed"
    if (
        adapter_snapshot is not None
        or forwarder_snapshot is not None
        or instance_snapshot is not None
        or found_managed_handler
    ):
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


class _HookArguments(NamedTuple):
    print_only: bool
    install: bool
    uninstall: bool
    status: bool


def parse_args() -> Any:
    arguments = sys.argv[1:]
    if not arguments:
        return _HookArguments(False, False, False, False)
    if arguments == ["--print"]:
        return _HookArguments(True, False, False, False)

    # Management and invalid invocations are cold paths. Keep argparse's
    # established validation and diagnostics without loading it for every
    # observed lifecycle event.
    import argparse

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
