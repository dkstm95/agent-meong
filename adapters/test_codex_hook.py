import importlib.util
import json
import pathlib
import tempfile
import unittest
from datetime import datetime, timezone


MODULE_PATH = pathlib.Path(__file__).with_name("codex_hook.py")
SPEC = importlib.util.spec_from_file_location("codex_hook", MODULE_PATH)
CODEX_HOOK = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CODEX_HOOK)


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 7, 14, 10, 0, tzinfo=timezone.utc)

    def normalize(self, **values):
        payload = {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-a",
            "turn_id": "turn-a",
        }
        payload.update(values)
        return CODEX_HOOK.normalize(payload, now=self.now, event_id="event-a")

    def normalize_stable(self, **values):
        payload = {
            "hook_event_name": "PreToolUse",
            "session_id": "session-a",
            "turn_id": "turn-a",
            "tool_use_id": "tool-a",
        }
        payload.update(values)
        return CODEX_HOOK.normalize(payload, now=self.now)

    def test_main_turn_uses_stable_logical_actor(self):
        event = self.normalize()
        self.assertEqual(event["kind"], "turn.started")
        session_id = CODEX_HOOK.opaque_id("session", "session-a")
        self.assertEqual(event["actorId"], f"codex:{session_id}:main")
        self.assertEqual(event["scopeId"], CODEX_HOOK.opaque_id("turn", "session-a", "turn-a"))
        self.assertNotIn("parentActorId", event)

    def test_subagent_points_to_main_turn(self):
        event = self.normalize(hook_event_name="SubagentStart", agent_id="agent-a")
        session_id = CODEX_HOOK.opaque_id("session", "session-a")
        agent_id = CODEX_HOOK.opaque_id("agent", "session-a", "agent-a")
        self.assertEqual(event["kind"], "agent.started")
        self.assertEqual(event["actorId"], f"codex:{session_id}:agent:{agent_id}")
        self.assertEqual(event["parentActorId"], f"codex:{session_id}:main")

    def test_tool_turn_ids_do_not_create_duplicate_main_actors(self):
        first = self.normalize(hook_event_name="PreToolUse", turn_id="tool-turn-a")
        second = self.normalize(hook_event_name="PreToolUse", turn_id="tool-turn-b")
        self.assertEqual(first["actorId"], second["actorId"])

    def test_only_tool_category_is_retained(self):
        event = self.normalize(
            hook_event_name="PreToolUse",
            tool_name="apply_patch",
            tool_input={"path": "/private/file", "content": "secret"},
        )
        self.assertEqual(event["toolCategory"], "edit")
        self.assertNotIn("tool_input", event)

    def test_permission_becomes_attention(self):
        event = self.normalize(hook_event_name="PermissionRequest", tool_name="Bash")
        self.assertEqual(event["kind"], "approval.waiting")
        self.assertEqual(event["toolCategory"], "shell")

    def test_terminal_failure_is_preserved(self):
        event = self.normalize(hook_event_name="Stop", outcome="failure")
        self.assertEqual(event["kind"], "turn.stopping")
        self.assertEqual(event["outcome"], "failure")

    def test_plain_stop_does_not_claim_success(self):
        event = self.normalize(hook_event_name="Stop")
        self.assertNotIn("outcome", event)

    def test_stable_source_ids_deduplicate_retries(self):
        first = self.normalize_stable()
        second = self.normalize_stable()
        self.assertEqual(first["eventId"], second["eventId"])

    def test_distinct_tools_get_distinct_event_ids(self):
        first = self.normalize_stable(tool_use_id="tool-a")
        second = self.normalize_stable(tool_use_id="tool-b")
        self.assertNotEqual(first["eventId"], second["eventId"])

    def test_raw_source_identifiers_are_not_forwarded(self):
        event = self.normalize(hook_event_name="SubagentStart", agent_id="agent-a")
        serialized = str(event)
        self.assertNotIn("session-a", serialized)
        self.assertNotIn("turn-a", serialized)
        self.assertNotIn("agent-a", serialized)

    def test_unknown_event_is_ignored(self):
        event = self.normalize(hook_event_name="Unknown")
        self.assertIsNone(event)

    def test_user_install_preserves_existing_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            hooks_path = home / ".codex" / "hooks.json"
            hooks_path.parent.mkdir()
            original_handler = {"type": "command", "command": "existing-command"}
            hooks_path.write_text(json.dumps({
                "custom": "preserved",
                "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [original_handler]}]},
            }))

            status = CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertEqual(status, "installed")
            installed = json.loads(hooks_path.read_text())
            self.assertEqual(installed["custom"], "preserved")
            self.assertEqual(installed["hooks"]["PreToolUse"][0]["hooks"], [original_handler])
            for event_name in CODEX_HOOK.USER_HOOK_EVENTS:
                handlers = [
                    handler
                    for group in installed["hooks"][event_name]
                    for handler in group["hooks"]
                    if CODEX_HOOK.is_agent_meong_handler(handler)
                ]
                self.assertEqual(len(handlers), 1)
            self.assertEqual(
                CODEX_HOOK.user_paths(home)["adapter"].read_bytes(),
                MODULE_PATH.read_bytes(),
            )

    def test_reinstall_replaces_managed_handlers_without_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            installed = json.loads(CODEX_HOOK.user_paths(home)["hooks"].read_text())
            managed_count = sum(
                CODEX_HOOK.is_agent_meong_handler(handler)
                for groups in installed["hooks"].values()
                for group in groups
                for handler in group.get("hooks", [])
            )
            self.assertEqual(managed_count, len(CODEX_HOOK.USER_HOOK_EVENTS))

    def test_uninstall_preserves_unrelated_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            hooks_path = CODEX_HOOK.user_paths(home)["hooks"]
            installed = json.loads(hooks_path.read_text())
            installed["hooks"]["Stop"].append({
                "hooks": [{"type": "command", "command": "existing-stop"}]
            })
            hooks_path.write_text(json.dumps(installed))

            status = CODEX_HOOK.uninstall_user_hook(home=home)

            self.assertEqual(status, "not_installed")
            remaining = json.loads(hooks_path.read_text())
            self.assertEqual(
                remaining["hooks"]["Stop"],
                [{"hooks": [{"type": "command", "command": "existing-stop"}]}],
            )
            self.assertFalse(CODEX_HOOK.user_paths(home)["adapter"].exists())

    def test_invalid_user_hooks_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            hooks_path = home / ".codex" / "hooks.json"
            hooks_path.parent.mkdir()
            hooks_path.write_text("not-json")

            with self.assertRaises(json.JSONDecodeError):
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertEqual(hooks_path.read_text(), "not-json")
            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "invalid")

    def test_partial_user_install_is_reported_for_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            hooks_path = CODEX_HOOK.user_paths(home)["hooks"]
            installed = json.loads(hooks_path.read_text())
            installed["hooks"].pop("Stop")
            hooks_path.write_text(json.dumps(installed))

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "needs_repair")


if __name__ == "__main__":
    unittest.main()
