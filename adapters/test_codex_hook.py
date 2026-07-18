import importlib.util
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
from datetime import datetime, timezone


MODULE_PATH = pathlib.Path(__file__).with_name("codex_hook.py")
SPEC = importlib.util.spec_from_file_location("codex_hook", MODULE_PATH)
CODEX_HOOK = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CODEX_HOOK)


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 7, 14, 10, 0, tzinfo=timezone.utc)
        self.forwarder_environment = mock.patch.dict(
            os.environ,
            {"AGENT_MEONG_FORWARDER_SOURCE": "/usr/bin/true"},
        )
        self.forwarder_environment.start()
        self.addCleanup(self.forwarder_environment.stop)

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

    def test_forwarder_prewarm_retries_one_validation_timeout(self):
        completed = subprocess.CompletedProcess(["forwarder"], 0)
        timeout = subprocess.TimeoutExpired(["forwarder"], 5)
        with mock.patch(
            "subprocess.run",
            side_effect=[timeout, completed],
        ) as run:
            CODEX_HOOK.prewarm_forwarder(pathlib.Path("/tmp/forwarder"))
        self.assertEqual(run.call_count, 2)

    def test_forwarder_prewarm_fails_closed_after_second_timeout(self):
        timeouts = [
            subprocess.TimeoutExpired(["forwarder"], 5),
            subprocess.TimeoutExpired(["forwarder"], 5),
        ]
        with mock.patch("subprocess.run", side_effect=timeouts) as run:
            with self.assertRaisesRegex(OSError, "did not start in time"):
                CODEX_HOOK.prewarm_forwarder(pathlib.Path("/tmp/forwarder"))
        self.assertEqual(run.call_count, 2)

    def runtime_hooks_payload(
        self,
        home,
        *,
        trust=None,
        disabled=(),
        missing=(),
        changes=None,
    ):
        paths = CODEX_HOOK.user_paths(home)
        trust = trust or {}
        changes = changes or {}
        runtime_names = {
            lifecycle_name: runtime_name
            for runtime_name, lifecycle_name in CODEX_HOOK.RUNTIME_EVENT_NAMES.items()
        }
        hooks = []
        for index, event_name in enumerate(CODEX_HOOK.USER_HOOK_EVENTS):
            if event_name in missing:
                continue
            hook = {
                "key": f"user:{runtime_names[event_name]}:0:0",
                "eventName": runtime_names[event_name],
                "handlerType": "command",
                "matcher": None,
                "command": CODEX_HOOK.hook_handler(paths["forwarder"])["command"],
                "timeoutSec": 2,
                "statusMessage": CODEX_HOOK.HOOK_STATUS_MESSAGE,
                "sourcePath": str(paths["hooks"]),
                "source": "user",
                "pluginId": None,
                "displayOrder": index,
                "enabled": event_name not in disabled,
                "isManaged": False,
                "currentHash": "sha256:" + format(index + 1, "064x"),
                "trustStatus": trust.get(event_name, "trusted"),
            }
            hook.update(changes.get(event_name, {}))
            hooks.append(hook)
        return {
            "data": [{
                "cwd": "/private/tmp",
                "hooks": hooks,
                "warnings": [],
                "errors": [],
            }]
        }

    def test_main_turn_uses_stable_logical_actor(self):
        event = self.normalize()
        self.assertEqual(event["kind"], "turn.started")
        self.assertEqual(
            event["actorId"],
            CODEX_HOOK.main_actor_id("unscoped", "session-a"),
        )
        self.assertEqual(
            event["scopeId"],
            CODEX_HOOK.opaque_id("turn", "unscoped", "session-a", "turn-a"),
        )
        self.assertNotIn("parentActorId", event)

    def test_subagent_points_to_main_turn(self):
        event = self.normalize(hook_event_name="SubagentStart", agent_id="agent-a")
        self.assertEqual(event["kind"], "agent.started")
        self.assertEqual(
            event["actorId"],
            CODEX_HOOK.opaque_id(
                "actor.agent", "unscoped", "session-a", "agent-a"
            ),
        )
        self.assertEqual(
            event["parentActorId"],
            CODEX_HOOK.main_actor_id("unscoped", "session-a"),
        )

    def test_subagent_tool_and_prompt_events_keep_the_lifecycle_actor(self):
        started = self.normalize(hook_event_name="SubagentStart", agent_id="agent-a")
        tool = self.normalize(
            hook_event_name="PreToolUse",
            agent_id="agent-a",
            tool_name="Bash",
            tool_use_id="tool-a",
        )
        prompt = self.normalize(
            hook_event_name="UserPromptSubmit",
            agent_id="agent-a",
        )

        for event in (tool, prompt):
            self.assertEqual(event["actorId"], started["actorId"])
            self.assertEqual(event["parentActorId"], started["parentActorId"])

    def test_observation_identifiers_use_one_fixed_opaque_digest_grammar(self):
        event = self.normalize(hook_event_name="SubagentStart", agent_id="agent-a")
        for key in ("eventId", "sessionId", "actorId", "parentActorId", "scopeId"):
            self.assertRegex(event[key], r"^[0-9a-f]{32}$", key)
        self.assertNotIn("main", event["actorId"])
        self.assertNotIn("agent", event["actorId"])
        self.assertNotIn("codex", event["actorId"])

    def test_source_and_integration_metadata_are_bounded_and_namespaced(self):
        event = self.normalize()
        namespace_pattern = r"^[a-z][a-z0-9-]{0,15}(\.[a-z][a-z0-9-]{0,15}){1,3}$"
        integration_pattern = (
            r"^[a-z][a-z0-9-]{0,15}"
            r"(\.[a-z][a-z0-9-]{0,15}){1,3}/v[1-9][0-9]{0,8}$"
        )
        self.assertRegex(event["source"], namespace_pattern)
        self.assertLessEqual(len(event["source"]), 64)
        self.assertRegex(event["integrationVersion"], integration_pattern)
        self.assertLessEqual(len(event["integrationVersion"]), 64)
        self.assertRegex(event["integrationInstance"], r"^(unscoped|[0-9a-f]{24,64})$")
        self.assertLessEqual(len(event["integrationInstance"]), 64)
        self.assertEqual(event["source"], "openai.codex")
        self.assertEqual(event["integrationVersion"], "dev.ailab.agent-meong/v6")

    def test_supplied_nonopaque_event_id_is_hashed_before_forwarding(self):
        event = self.normalize()
        self.assertRegex(event["eventId"], r"^[0-9a-f]{32}$")
        self.assertNotEqual(event["eventId"], "event-a")

    def test_supplied_event_id_is_namespaced_by_integration_instance(self):
        with mock.patch.object(
            CODEX_HOOK, "integration_instance_id", return_value="a" * 24
        ):
            first = self.normalize()
        with mock.patch.object(
            CODEX_HOOK, "integration_instance_id", return_value="b" * 24
        ):
            second = self.normalize()

        for key in ("eventId", "sessionId", "actorId", "scopeId"):
            self.assertNotEqual(first[key], second[key], key)

    def test_random_event_id_uses_opaque_digest_grammar(self):
        event = CODEX_HOOK.normalize(
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "session-a",
                "tool_name": "Bash",
            },
            now=self.now,
        )
        self.assertRegex(event["eventId"], r"^[0-9a-f]{32}$")

    def test_breaking_actor_identity_change_bumps_hook_definition(self):
        self.assertEqual(CODEX_HOOK.HOOK_VERSION, 6)
        self.assertEqual(CODEX_HOOK.HOOK_DEFINITION_ID, "dev.ailab.agent-meong/v6")

    def test_runtime_hook_diagnostics_classify_only_owned_lifecycle_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            payload = self.runtime_hooks_payload(home)
            payload["data"][0]["hooks"].append({
                "eventName": "stop",
                "source": "project",
                "command": "raw prompt /private/user/path",
                "statusMessage": "unrelated hook",
            })
            payload["data"][0]["warnings"] = [
                "raw prompt and response must not cross the diagnostic boundary"
            ]

            result = CODEX_HOOK._classify_runtime_hooks(payload, paths)

            self.assertEqual(result, {
                "runtimeStatus": "ready",
                "runtimeProblemEvents": [],
                "otherPendingHookCount": 0,
            })
            serialized = json.dumps(result)
            self.assertNotIn("prompt", serialized)
            self.assertNotIn("/private/user/path", serialized)

    def test_runtime_hook_diagnostics_count_other_pending_hooks_without_details(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            payload = self.runtime_hooks_payload(home)
            payload["data"][0]["hooks"].extend([
                {
                    "key": "user:stop:8:0",
                    "eventName": "stop",
                    "source": "user",
                    "command": "private command /Users/someone/secret",
                    "statusMessage": CODEX_HOOK.HOOK_STATUS_MESSAGE,
                    "trustStatus": "untrusted",
                },
                {
                    "key": "user:stop:9:0",
                    "eventName": "stop",
                    "source": "user",
                    "command": "another private command",
                    "statusMessage": "another integration",
                    "trustStatus": "trusted",
                },
            ])

            result = CODEX_HOOK._classify_runtime_hooks(payload, paths)

            self.assertEqual(result["otherPendingHookCount"], 1)
            serialized = json.dumps(result)
            self.assertNotIn("private command", serialized)
            self.assertNotIn("/Users/someone/secret", serialized)
            self.assertNotIn(CODEX_HOOK.HOOK_STATUS_MESSAGE, serialized)

    def test_runtime_hook_diagnostics_report_review_disabled_and_missing_events(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)

            review = CODEX_HOOK._classify_runtime_hooks(
                self.runtime_hooks_payload(
                    home,
                    trust={"UserPromptSubmit": "modified", "Stop": "untrusted"},
                ),
                paths,
            )
            self.assertEqual(review, {
                "runtimeStatus": "review_required",
                "runtimeProblemEvents": ["UserPromptSubmit", "Stop"],
                "otherPendingHookCount": 0,
            })

            disabled = CODEX_HOOK._classify_runtime_hooks(
                self.runtime_hooks_payload(home, disabled={"PermissionRequest"}),
                paths,
            )
            self.assertEqual(disabled, {
                "runtimeStatus": "disabled",
                "runtimeProblemEvents": ["PermissionRequest"],
                "otherPendingHookCount": 0,
            })

            missing = CODEX_HOOK._classify_runtime_hooks(
                self.runtime_hooks_payload(home, missing={"SubagentStart"}),
                paths,
            )
            self.assertEqual(missing, {
                "runtimeStatus": "unavailable",
                "runtimeProblemEvents": ["SubagentStart"],
                "otherPendingHookCount": 0,
            })

            malformed = CODEX_HOOK._classify_runtime_hooks(
                self.runtime_hooks_payload(
                    home,
                    changes={"SubagentStop": {"currentHash": "not-a-hash"}},
                ),
                paths,
            )
            self.assertEqual(malformed, {
                "runtimeStatus": "unavailable",
                "runtimeProblemEvents": ["SubagentStop"],
                "otherPendingHookCount": 0,
            })

    def test_explicit_home_status_does_not_discover_real_codex(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            with mock.patch.object(
                CODEX_HOOK,
                "_codex_runtime_binaries",
                side_effect=AssertionError("real Codex discovery must stay disabled"),
            ):
                result = CODEX_HOOK.status_result("installed", home=home)

            self.assertEqual(result["runtimeStatus"], "unavailable")
            self.assertEqual(
                result["runtimeProblemEvents"],
                list(CODEX_HOOK.USER_HOOK_EVENTS),
            )

    def test_runtime_probe_requires_explicit_diagnostics_opt_in(self):
        environment = dict(os.environ)
        environment.pop("AGENT_MEONG_RUNTIME_DIAGNOSTICS", None)
        environment.pop("AGENT_MEONG_E2E_CODEX_BIN", None)
        environment.pop("AGENT_MEONG_E2E_REPORT", None)
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertFalse(CODEX_HOOK._runtime_probe_allowed(
                home_was_explicit=False,
                codex_home_was_explicit=False,
            ))

        environment["AGENT_MEONG_RUNTIME_DIAGNOSTICS"] = "1"
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertTrue(CODEX_HOOK._runtime_probe_allowed(
                home_was_explicit=False,
                codex_home_was_explicit=False,
            ))

    def test_runtime_discovery_keeps_chatgpt_codex_and_cli_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            chatgpt = (
                home
                / "Applications/ChatGPT.app/Contents/Resources/codex"
            )
            codex_app = home / "Applications/Codex.app/Contents/Resources/codex"
            cli = home / ".local/bin/codex"
            available = {chatgpt, codex_app, cli}

            def validate(candidate):
                if candidate not in available:
                    return None
                return CODEX_HOOK._CodexRuntimeExecutable(candidate)

            with (
                mock.patch("shutil.which", return_value=None),
                mock.patch.object(
                    CODEX_HOOK,
                    "_validated_codex_runtime_executable",
                    side_effect=validate,
                ),
            ):
                binaries = CODEX_HOOK._codex_runtime_binaries(home)

            self.assertEqual(
                binaries,
                [
                    CODEX_HOOK._CodexRuntimeExecutable(chatgpt),
                    CODEX_HOOK._CodexRuntimeExecutable(codex_app),
                    CODEX_HOOK._CodexRuntimeExecutable(cli),
                ],
            )

    def test_runtime_diagnostics_ignore_one_incompatible_codex_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            payload = self.runtime_hooks_payload(home)
            with mock.patch.object(
                CODEX_HOOK,
                "_codex_runtime_binaries",
                return_value=[pathlib.Path("/old-codex"), pathlib.Path("/new-codex")],
            ):
                with mock.patch.object(
                    CODEX_HOOK,
                    "_query_codex_runtime_hooks",
                    side_effect=[None, payload],
                ):
                    result = CODEX_HOOK.runtime_hook_diagnostics(
                        "installed",
                        paths=paths,
                        home=home,
                        allow_probe=True,
                    )

            self.assertEqual(result, {
                "runtimeStatus": "ready",
                "runtimeProblemEvents": [],
                "otherPendingHookCount": 0,
            })

    def test_nvm_runtime_probe_preserves_validated_node_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            nvm_bin = home / ".nvm/versions/node/v22.1.0/bin"
            nvm_bin.mkdir(parents=True)
            target = root / "codex.js"
            target.write_text("#!/usr/bin/env node\n", encoding="utf-8")
            target.chmod(0o700)
            (nvm_bin / "codex").symlink_to(target)
            node = nvm_bin / "node"
            node.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            node.chmod(0o700)

            executable = CODEX_HOOK._validated_codex_runtime_executable(
                nvm_bin / "codex"
            )
            self.assertIsNotNone(executable)
            self.assertEqual(executable.path, target.resolve())
            self.assertEqual(executable.path_prefix, nvm_bin.resolve())

            with mock.patch.object(
                CODEX_HOOK,
                "_run_codex_hooks_list",
                return_value={},
            ) as run_hooks_list:
                result = CODEX_HOOK._query_codex_runtime_hooks(
                    executable,
                    home=home,
                    codex_home=home / ".codex",
                )

            self.assertEqual(result, {})
            self.assertEqual(run_hooks_list.call_count, 2)
            for call in run_hooks_list.call_args_list:
                self.assertEqual(call.args[0], target.resolve())
                self.assertEqual(
                    call.kwargs["environment"]["PATH"].split(os.pathsep)[0],
                    str(nvm_bin.resolve()),
                )

    def test_runtime_diagnostics_reports_only_highest_severity_events(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            payloads = {
                pathlib.Path("/app-codex"): self.runtime_hooks_payload(
                    home,
                    disabled={"PermissionRequest"},
                ),
                pathlib.Path("/cli-codex"): self.runtime_hooks_payload(
                    home,
                    trust={"Stop": "untrusted"},
                ),
            }
            with (
                mock.patch.object(
                    CODEX_HOOK,
                    "_codex_runtime_binaries",
                    return_value=list(payloads),
                ),
                mock.patch.object(
                    CODEX_HOOK,
                    "_query_codex_runtime_hooks",
                    side_effect=lambda binary, **_: payloads[binary],
                ),
            ):
                result = CODEX_HOOK.runtime_hook_diagnostics(
                    "installed",
                    paths=paths,
                    home=home,
                    allow_probe=True,
                )

            self.assertEqual(result, {
                "runtimeStatus": "disabled",
                "runtimeProblemEvents": ["PermissionRequest"],
                "otherPendingHookCount": 0,
            })

    def test_e2e_fake_app_server_reports_ready_without_mutating_trust(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            fake = root / "fake-codex"
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            payload = self.runtime_hooks_payload(home)
            payload["data"][0]["warnings"] = ["raw response must stay private"]
            probe_capture = root / "probe.json"
            user_state = home / ".codex/state_5.sqlite"
            user_state.write_text("must stay untouched", encoding="utf-8")
            fake.write_text(
                "#!/usr/bin/python3\n"
                "import json, os, stat, sys\n"
                "for line in sys.stdin:\n"
                "    request = json.loads(line)\n"
                "    if request.get('method') == 'initialize':\n"
                "        result = {'userAgent': 'fake', 'codexHome': os.environ['CODEX_HOME']}\n"
                "    elif request.get('method') == 'hooks/list':\n"
                "        codex_home = os.environ['CODEX_HOME']\n"
                "        sqlite_home = os.environ['CODEX_SQLITE_HOME']\n"
                "        log_argument = next(value for value in sys.argv if value.startswith('log_dir='))\n"
                "        log_home = json.loads(log_argument.split('=', 1)[1])\n"
                "        capture = {\n"
                "            'codexHome': codex_home,\n"
                "            'codexHomeHasHooks': os.path.isfile(os.path.join(codex_home, 'hooks.json')),\n"
                "            'cwd': os.getcwd(),\n"
                "            'cwdMode': stat.S_IMODE(os.stat(os.getcwd()).st_mode),\n"
                "            'logHome': log_home,\n"
                "            'logMode': stat.S_IMODE(os.stat(log_home).st_mode),\n"
                "            'sqliteHome': sqlite_home,\n"
                "            'sqliteMode': stat.S_IMODE(os.stat(sqlite_home).st_mode),\n"
                "            'requestedCwds': request.get('params', {}).get('cwds'),\n"
                "            'secretCanaryPresent': 'SECRET_CANARY' in os.environ,\n"
                "        }\n"
                "        with open(os.environ['AGENT_MEONG_E2E_PROBE_CAPTURE'], 'a') as handle:\n"
                "            handle.write(json.dumps(capture) + '\\n')\n"
                "        result = json.loads(os.environ['AGENT_MEONG_E2E_HOOK_LIST_RESULT'])\n"
                "    else:\n"
                "        continue\n"
                "    print(json.dumps({'id': request['id'], 'result': result}), flush=True)\n",
                encoding="utf-8",
            )
            fake.chmod(0o700)
            environment = {
                "AGENT_MEONG_E2E_CODEX_BIN": str(fake),
                "AGENT_MEONG_E2E_REPORT": str(root / "report.jsonl"),
                "AGENT_MEONG_E2E_HOOK_LIST_RESULT": json.dumps(payload),
                "AGENT_MEONG_E2E_PROBE_CAPTURE": str(probe_capture),
                "SECRET_CANARY": "must-not-reach-codex",
            }
            # This fixture verifies isolation and privacy, not the production
            # latency budget. Keep host load from turning Python process startup
            # into a false behavioral failure; the actual CLI acceptance uses
            # the production timeout unchanged.
            with (
                mock.patch.dict(os.environ, environment, clear=False),
                mock.patch.object(
                    CODEX_HOOK,
                    "RUNTIME_QUERY_TIMEOUT_SECONDS",
                    10.0,
                ),
            ):
                result = CODEX_HOOK.status_result("installed", home=home)

            self.assertEqual(result["runtimeStatus"], "ready")
            self.assertEqual(result["runtimeProblemEvents"], [])
            self.assertNotIn("raw response", json.dumps(result))
            self.assertFalse((home / ".codex/hooks.state.json").exists())
            self.assertEqual(user_state.read_text(encoding="utf-8"), "must stay untouched")
            captures = [json.loads(line) for line in probe_capture.read_text().splitlines()]
            self.assertEqual(len(captures), 2)
            self.assertFalse(captures[0]["codexHomeHasHooks"])
            self.assertTrue(captures[1]["codexHomeHasHooks"])
            self.assertEqual(
                pathlib.Path(captures[1]["codexHome"]).resolve(strict=False),
                (home / ".codex").resolve(strict=False),
            )
            self.assertEqual(captures[0]["sqliteHome"], captures[1]["sqliteHome"])
            for capture in captures:
                self.assertEqual(capture["cwdMode"], 0o700)
                self.assertEqual(capture["logMode"], 0o700)
                self.assertEqual(capture["sqliteMode"], 0o700)
                self.assertFalse(capture["secretCanaryPresent"])
                self.assertEqual(len(capture["requestedCwds"]), 1)
                self.assertEqual(
                    pathlib.Path(capture["requestedCwds"][0]).resolve(strict=False),
                    pathlib.Path(capture["cwd"]).resolve(strict=False),
                )
                self.assertFalse(pathlib.Path(capture["cwd"]).exists())
                self.assertFalse(pathlib.Path(capture["logHome"]).exists())
                self.assertFalse(pathlib.Path(capture["sqliteHome"]).exists())

    def test_runtime_candidates_are_serialized_to_avoid_codex_home_races(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            paths = CODEX_HOOK.user_paths(home)
            payload = self.runtime_hooks_payload(home)
            binaries = [pathlib.Path("/app-codex"), pathlib.Path("/cli-codex")]
            calls = []

            def query(binary, **_):
                calls.append((binary, threading.current_thread()))
                return payload

            with (
                mock.patch.object(
                    CODEX_HOOK,
                    "_codex_runtime_binaries",
                    return_value=binaries,
                ),
                mock.patch.object(
                    CODEX_HOOK,
                    "_query_codex_runtime_hooks",
                    side_effect=query,
                ),
            ):
                result = CODEX_HOOK.runtime_hook_diagnostics(
                    "installed",
                    paths=paths,
                    home=home,
                    allow_probe=True,
                )

            self.assertEqual(result, {
                "runtimeStatus": "ready",
                "runtimeProblemEvents": [],
                "otherPendingHookCount": 0,
            })
            self.assertEqual([binary for binary, _ in calls], binaries)
            self.assertTrue(all(
                thread is threading.current_thread()
                for _, thread in calls
            ))

    def test_adapter_and_demo_fixture_follow_the_committed_protocol_schema(self):
        root = MODULE_PATH.parent.parent
        schema = json.loads((root / "protocol/event-v0.schema.json").read_text())
        fixtures = json.loads(
            (root / "protocol/fixtures/demo-observations.json").read_text()
        )
        adapter_events = [
            self.normalize(),
            self.normalize(hook_event_name="SubagentStart", agent_id="agent-a"),
        ]
        required = set(schema["required"])
        properties = schema["properties"]
        self.assertFalse(schema["additionalProperties"])

        for event in [*adapter_events, *fixtures]:
            self.assertTrue(required.issubset(event))
            self.assertTrue(set(event).issubset(properties))
            for key, value in event.items():
                rule = properties[key]
                if "const" in rule:
                    self.assertEqual(value, rule["const"], key)
                if "enum" in rule:
                    self.assertIn(value, rule["enum"], key)
                if rule.get("type") == "string":
                    self.assertIsInstance(value, str, key)
                    self.assertGreaterEqual(len(value), rule.get("minLength", 0), key)
                    self.assertLessEqual(len(value), rule.get("maxLength", len(value)), key)
                    if pattern := rule.get("pattern"):
                        self.assertIsNotNone(re.fullmatch(pattern, value), key)

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

    def test_nonstandard_terminal_outcome_is_ignored(self):
        event = self.normalize(
            hook_event_name="Stop",
            outcome="failure",
            error="not part of the Codex Stop contract",
        )
        self.assertEqual(event["kind"], "turn.stopping")
        self.assertNotIn("outcome", event)

    def test_plain_stop_does_not_claim_success(self):
        event = self.normalize(hook_event_name="Stop")
        self.assertNotIn("outcome", event)

    def test_documented_stop_payload_does_not_invent_outcome(self):
        event = self.normalize(
            hook_event_name="Stop",
            turn_id="turn-a",
            stop_hook_active=False,
            last_assistant_message="sensitive response",
        )
        self.assertEqual(event["kind"], "turn.stopping")
        self.assertNotIn("outcome", event)
        self.assertNotIn("last_assistant_message", str(event))

    def test_documented_subagent_stop_payload_does_not_invent_outcome(self):
        event = self.normalize(
            hook_event_name="SubagentStop",
            agent_id="agent-a",
            agent_type="worker",
            agent_transcript_path="/private/transcript.jsonl",
            stop_hook_active=False,
            last_assistant_message="sensitive response",
        )
        self.assertEqual(event["kind"], "agent.finished")
        self.assertNotIn("outcome", event)
        self.assertNotIn("transcript", str(event))
        self.assertNotIn("sensitive response", str(event))

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

    def test_identical_raw_ids_are_distinct_across_codex_homes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            first_codex_home = root / "codex-a"
            second_codex_home = root / "codex-b"
            self.assertEqual(
                CODEX_HOOK.install_user_hook(
                    home=home,
                    codex_home=first_codex_home,
                    source=MODULE_PATH,
                ),
                "installed",
            )
            self.assertEqual(
                CODEX_HOOK.install_user_hook(
                    home=home,
                    codex_home=second_codex_home,
                    source=MODULE_PATH,
                ),
                "installed",
            )
            first_adapter = CODEX_HOOK.user_paths(
                home, first_codex_home
            )["adapter"]
            second_adapter = CODEX_HOOK.user_paths(
                home, second_codex_home
            )["adapter"]
            payload = {
                "hook_event_name": "SubagentStart",
                "session_id": "shared-session",
                "turn_id": "shared-turn",
                "agent_id": "shared-agent",
            }

            def observation(adapter, codex_home):
                environment = dict(os.environ)
                environment.update({
                    "HOME": str(home),
                    "CODEX_HOME": str(codex_home),
                })
                completed = subprocess.run(
                    [sys.executable, str(adapter), "--print"],
                    input=json.dumps(payload),
                    text=True,
                    capture_output=True,
                    check=True,
                    env=environment,
                )
                return json.loads(completed.stdout)

            first = observation(first_adapter, first_codex_home)
            first_retry = observation(first_adapter, first_codex_home)
            second = observation(second_adapter, second_codex_home)
            identifier_keys = (
                "eventId",
                "sessionId",
                "actorId",
                "parentActorId",
                "scopeId",
            )
            for key in identifier_keys:
                self.assertEqual(first[key], first_retry[key], key)
                self.assertNotEqual(first[key], second[key], key)
            self.assertNotEqual(
                first["integrationInstance"], second["integrationInstance"]
            )
            serialized = json.dumps([first, second])
            for raw_value in ("shared-session", "shared-turn", "shared-agent"):
                self.assertNotIn(raw_value, serialized)

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
            paths = CODEX_HOOK.user_paths(home)
            instance_id = paths["instance"].read_text().strip()
            self.assertRegex(instance_id, r"^[0-9a-f]{24}$")
            self.assertNotEqual(instance_id, paths["adapter"].parent.name)
            self.assertEqual(paths["instance"].stat().st_mode & 0o777, 0o600)
            with mock.patch.object(CODEX_HOOK, "__file__", str(paths["adapter"])):
                event = self.normalize()
            self.assertEqual(event["integrationInstance"], instance_id)

    def test_install_preserves_unrelated_empty_groups_and_events(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            empty_group = {"matcher": "never", "hooks": []}
            paths["hooks"].write_text(json.dumps({
                "hooks": {
                    "UnknownEmptyEvent": [],
                    "Stop": [empty_group],
                }
            }))

            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            installed = json.loads(paths["hooks"].read_text())
            self.assertEqual(installed["hooks"]["UnknownEmptyEvent"], [])
            self.assertEqual(installed["hooks"]["Stop"][0], empty_group)

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

    def test_repair_reuses_current_and_legacy_owned_group_slots_idempotently(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            canonical = CODEX_HOOK.hook_handler(paths["forwarder"])
            legacy_command = CODEX_HOOK.legacy_python_command(
                paths["legacyAdapter"]
            )
            original_user_groups = {}
            hooks = {}
            for index, event_name in enumerate(CODEX_HOOK.USER_HOOK_EVENTS):
                before = {
                    "matcher": f"before-{event_name}",
                    "hooks": [{
                        "type": "command",
                        "command": f"user-before-{event_name}",
                    }],
                }
                after = {
                    "matcher": f"after-{event_name}",
                    "hooks": [{
                        "type": "command",
                        "command": f"user-after-{event_name}",
                    }],
                }
                owned = dict(canonical)
                if index % 3 == 1:
                    owned.update({
                        "command": f"outdated-{event_name}",
                        "timeout": 99,
                        "statusMessage": (
                            "agent-meong activity [dev.ailab.agent-meong/v2]"
                        ),
                    })
                elif index % 3 == 2:
                    owned.update({
                        "command": legacy_command,
                        "statusMessage": CODEX_HOOK.LEGACY_HOOK_STATUS_MESSAGE,
                    })
                hooks[event_name] = [before, {"hooks": [owned]}, after]
                original_user_groups[event_name] = (before, after)
            paths["hooks"].write_text(json.dumps({
                "custom": "preserved",
                "hooks": hooks,
            }))

            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            repaired = json.loads(paths["hooks"].read_text())
            self.assertEqual(repaired["custom"], "preserved")
            for event_name, (before, after) in original_user_groups.items():
                self.assertEqual(repaired["hooks"][event_name], [
                    before,
                    {"hooks": [canonical]},
                    after,
                ])

            first_install = paths["hooks"].read_bytes()
            first_stat = paths["hooks"].stat()
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            self.assertEqual(paths["hooks"].read_bytes(), first_install)
            second_stat = paths["hooks"].stat()
            self.assertEqual(second_stat.st_ino, first_stat.st_ino)
            self.assertEqual(second_stat.st_mtime_ns, first_stat.st_mtime_ns)

    def test_repair_deduplicates_owned_slots_without_reordering_user_definitions(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            canonical = CODEX_HOOK.hook_handler(paths["forwarder"])
            owned_v1 = {
                "type": "command",
                "command": "/old/agent-meong",
                "timeout": 10,
                "statusMessage": (
                    "agent-meong activity [dev.ailab.agent-meong/v1]"
                ),
            }
            owned_v3 = {
                "type": "command",
                "command": "/newer/old-agent-meong",
                "statusMessage": (
                    "agent-meong activity [dev.ailab.agent-meong/v3]"
                ),
            }
            user_before = {
                "hooks": [{"type": "command", "command": "user-before"}],
            }
            mixed_user_handlers = [
                {"type": "command", "command": "mixed-before"},
                {"type": "command", "command": "mixed-after"},
            ]
            mixed = {
                "matcher": "Bash",
                "custom": "preserved",
                "hooks": [
                    mixed_user_handlers[0],
                    dict(owned_v3),
                    mixed_user_handlers[1],
                ],
            }
            user_after = {
                "hooks": [{"type": "command", "command": "user-after"}],
            }
            unsupported_before = {
                "hooks": [{"type": "command", "command": "session-before"}],
            }
            unsupported_after = {
                "hooks": [{"type": "command", "command": "session-after"}],
            }
            paths["hooks"].write_text(json.dumps({
                "hooks": {
                    "Stop": [
                        user_before,
                        {"matcher": "drifted", "hooks": [
                            dict(owned_v1),
                            dict(owned_v3),
                        ]},
                        mixed,
                        {"hooks": [dict(owned_v1)]},
                        user_after,
                    ],
                    "SessionStart": [
                        unsupported_before,
                        {"hooks": [dict(owned_v3)]},
                        unsupported_after,
                    ],
                },
            }))

            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            repaired = json.loads(paths["hooks"].read_text())
            self.assertEqual(repaired["hooks"]["Stop"], [
                user_before,
                {"hooks": [canonical]},
                {
                    "matcher": "Bash",
                    "custom": "preserved",
                    "hooks": mixed_user_handlers,
                },
                user_after,
            ])
            self.assertEqual(repaired["hooks"]["SessionStart"], [
                unsupported_before,
                unsupported_after,
            ])
            for event_name in CODEX_HOOK.USER_HOOK_EVENTS:
                managed = [
                    candidate
                    for group in repaired["hooks"][event_name]
                    for candidate in group["hooks"]
                    if CODEX_HOOK.is_agent_meong_handler(
                        candidate,
                        expected_command=canonical["command"],
                    )
                ]
                self.assertEqual(managed, [canonical], event_name)

    def test_repair_appends_only_missing_event_slots(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            old_owned = {
                "type": "command",
                "command": "/old/agent-meong",
                "statusMessage": (
                    "agent-meong activity [dev.ailab.agent-meong/v2]"
                ),
            }
            before = {
                "hooks": [{"type": "command", "command": "user-before"}],
            }
            after = {
                "hooks": [{"type": "command", "command": "user-after"}],
            }
            paths["hooks"].write_text(json.dumps({
                "hooks": {"Stop": [before, {"hooks": [old_owned]}, after]},
            }))

            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            repaired = json.loads(paths["hooks"].read_text())
            canonical_group = {
                "hooks": [CODEX_HOOK.hook_handler(paths["forwarder"])],
            }
            self.assertEqual(
                repaired["hooks"]["Stop"],
                [before, canonical_group, after],
            )
            for event_name in set(CODEX_HOOK.USER_HOOK_EVENTS) - {"Stop"}:
                self.assertEqual(repaired["hooks"][event_name], [canonical_group])

    def test_uninstall_preserves_user_definitions_around_owned_slots(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            user_groups = {}
            hooks = {}
            for event_name in CODEX_HOOK.USER_HOOK_EVENTS:
                before = {
                    "matcher": f"before-{event_name}",
                    "hooks": [{
                        "type": "command",
                        "command": f"user-before-{event_name}",
                    }],
                }
                after = {
                    "matcher": f"after-{event_name}",
                    "hooks": [{
                        "type": "command",
                        "command": f"user-after-{event_name}",
                    }],
                }
                owned = {
                    "type": "command",
                    "command": f"old-{event_name}",
                    "statusMessage": (
                        "agent-meong activity [dev.ailab.agent-meong/v2]"
                    ),
                }
                hooks[event_name] = [before, {"hooks": [owned]}, after]
                user_groups[event_name] = [before, after]
            paths["hooks"].write_text(json.dumps({
                "custom": "preserved",
                "hooks": hooks,
            }))

            self.assertEqual(
                CODEX_HOOK.uninstall_user_hook(home=home),
                "not_installed",
            )
            uninstalled = json.loads(paths["hooks"].read_text())
            self.assertEqual(uninstalled["custom"], "preserved")
            self.assertEqual(uninstalled["hooks"], user_groups)

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
            self.assertFalse(CODEX_HOOK.user_paths(home)["instance"].exists())

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

    def test_async_managed_handler_is_reported_for_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            hooks_path = CODEX_HOOK.user_paths(home)["hooks"]
            installed = json.loads(hooks_path.read_text())
            installed["hooks"]["Stop"][-1]["hooks"][0]["async"] = False
            hooks_path.write_text(json.dumps(installed))

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "needs_repair")

    def test_each_managed_handler_field_is_verified_exactly(self):
        mutations = {
            "command": "/usr/bin/false",
            "timeout": 30,
            "statusMessage": "changed status",
        }
        for field, value in mutations.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                home = pathlib.Path(directory)
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
                hooks_path = CODEX_HOOK.user_paths(home)["hooks"]
                installed = json.loads(hooks_path.read_text())
                installed["hooks"]["Stop"][-1]["hooks"][0][field] = value
                hooks_path.write_text(json.dumps(installed))

                self.assertEqual(
                    CODEX_HOOK.user_hook_status(home=home),
                    "needs_repair",
                )

    def test_matcher_on_managed_group_is_reported_for_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            hooks_path = CODEX_HOOK.user_paths(home)["hooks"]
            installed = json.loads(hooks_path.read_text())
            installed["hooks"]["Stop"][-1]["matcher"] = "unexpected"
            hooks_path.write_text(json.dumps(installed))

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "needs_repair")

    def test_reinstall_migrates_drifted_legacy_and_versioned_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            expected_command = CODEX_HOOK.hook_handler(paths["forwarder"])["command"]
            paths["hooks"].write_text(json.dumps({
                "hooks": {
                    "Stop": [
                        {"hooks": [{
                            "type": "command",
                            "command": expected_command,
                            "timeout": 99,
                            "async": True,
                            "statusMessage": "drifted legacy status",
                        }]},
                        {"hooks": [{
                            "type": "command",
                            "command": "/usr/bin/false",
                            "timeout": 1,
                            "statusMessage": (
                                "agent-meong activity [dev.ailab.agent-meong/v2]"
                            ),
                        }]},
                    ]
                }
            }))

            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home),
                "needs_repair",
            )
            status = CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertEqual(status, "installed")
            installed = json.loads(paths["hooks"].read_text())
            owned = [
                handler
                for groups in installed["hooks"].values()
                for group in groups
                for handler in group["hooks"]
                if CODEX_HOOK.is_agent_meong_handler(
                    handler,
                    expected_command=expected_command,
                )
            ]
            self.assertEqual(len(owned), len(CODEX_HOOK.USER_HOOK_EVENTS))
            self.assertTrue(all(
                handler == CODEX_HOOK.hook_handler(paths["forwarder"])
                for handler in owned
            ))

    def test_upgrade_migrates_historical_shared_adapter_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            paths["legacyAdapter"].parent.mkdir(parents=True)
            paths["legacyAdapter"].write_bytes(MODULE_PATH.read_bytes())
            legacy_handler = {
                "type": "command",
                "command": CODEX_HOOK.legacy_python_command(paths["legacyAdapter"]),
                "timeout": 2,
                "statusMessage": CODEX_HOOK.LEGACY_HOOK_STATUS_MESSAGE,
            }
            paths["hooks"].write_text(json.dumps({
                "hooks": {
                    event_name: [{"hooks": [dict(legacy_handler)]}]
                    for event_name in CODEX_HOOK.USER_HOOK_EVENTS
                }
            }))

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "needs_repair")
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            upgraded = json.loads(paths["hooks"].read_text())
            all_handlers = [
                handler
                for groups in upgraded["hooks"].values()
                for group in groups
                for handler in group["hooks"]
            ]
            self.assertEqual(len(all_handlers), len(CODEX_HOOK.USER_HOOK_EVENTS))
            self.assertTrue(all(
                handler == CODEX_HOOK.hook_handler(paths["forwarder"])
                for handler in all_handlers
            ))

            self.assertEqual(CODEX_HOOK.uninstall_user_hook(home=home), "not_installed")
            uninstalled = json.loads(paths["hooks"].read_text())
            self.assertEqual(uninstalled["hooks"], {})
            self.assertFalse(paths["adapter"].exists())
            # The historical adapter was shared by arbitrary custom CODEX_HOME
            # values, so removing its now-inactive file cannot be proven safe.
            self.assertTrue(paths["legacyAdapter"].is_file())

    def test_upgrade_migrates_per_home_v5_python_handlers_to_native_v6(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            old_handler = {
                "type": "command",
                "command": CODEX_HOOK.legacy_python_command(paths["adapter"]),
                "timeout": 2,
                "statusMessage": (
                    "agent-meong activity [dev.ailab.agent-meong/v5]"
                ),
            }
            paths["hooks"].write_text(json.dumps({
                "hooks": {
                    event_name: [{"hooks": [dict(old_handler)]}]
                    for event_name in CODEX_HOOK.USER_HOOK_EVENTS
                }
            }))
            paths["adapter"].parent.mkdir(parents=True)
            paths["adapter"].write_bytes(MODULE_PATH.read_bytes())
            paths["instance"].write_text("0123456789abcdef01234567\n")
            paths["instance"].chmod(0o600)

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "needs_repair")
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            upgraded = json.loads(paths["hooks"].read_text())
            expected = CODEX_HOOK.hook_handler(paths["forwarder"])
            self.assertTrue(paths["forwarder"].is_file())
            self.assertTrue(paths["forwarder"].stat().st_mode & 0o100)
            self.assertTrue(all(
                group == {"hooks": [expected]}
                for groups in upgraded["hooks"].values()
                for group in groups
            ))

    def test_versioned_marker_ownership_survives_handler_type_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            document = json.loads(paths["hooks"].read_text())
            document["hooks"]["Stop"][-1]["hooks"][0]["type"] = "prompt"
            paths["hooks"].write_text(json.dumps(document))

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "needs_repair")
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            repaired = json.loads(paths["hooks"].read_text())
            owned = [
                handler
                for groups in repaired["hooks"].values()
                for group in groups
                for handler in group["hooks"]
                if CODEX_HOOK.is_agent_meong_handler(handler)
            ]
            self.assertEqual(len(owned), len(CODEX_HOOK.USER_HOOK_EVENTS))

            self.assertEqual(CODEX_HOOK.uninstall_user_hook(home=home), "not_installed")
            remaining = json.loads(paths["hooks"].read_text())
            self.assertFalse(any(remaining["hooks"].values()))

    def test_legacy_status_collision_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            collision = {
                "type": "command",
                "command": "unrelated-command",
                "statusMessage": CODEX_HOOK.LEGACY_HOOK_STATUS_MESSAGE,
            }
            paths["hooks"].write_text(json.dumps({
                "hooks": {"Stop": [{"hooks": [collision]}]}
            }))

            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home),
                "not_installed",
            )
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            status = CODEX_HOOK.uninstall_user_hook(home=home)

            self.assertEqual(status, "not_installed")
            remaining = json.loads(paths["hooks"].read_text())
            self.assertEqual(remaining["hooks"], {
                "Stop": [{"hooks": [collision]}]
            })

    def test_newer_version_is_preserved_and_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            future = {
                "type": "command",
                "command": "/future/agent-meong",
                "statusMessage": (
                    f"agent-meong activity [{CODEX_HOOK.HOOK_OWNER}/v99]"
                ),
            }
            original = {"hooks": {"Stop": [{"hooks": [future]}]}}
            paths["hooks"].write_text(json.dumps(original))

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "newer_version")
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "newer_version",
            )
            self.assertEqual(CODEX_HOOK.uninstall_user_hook(home=home), "newer_version")
            self.assertEqual(json.loads(paths["hooks"].read_text()), original)
            self.assertFalse(paths["adapter"].exists())

    def test_install_preserves_hooks_json_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            hooks_path = CODEX_HOOK.user_paths(home)["hooks"]
            target = root / "shared" / "hooks.json"
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps({"custom": "preserved", "hooks": {}}))
            hooks_path.parent.mkdir(parents=True)
            hooks_path.symlink_to(target)

            status = CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertEqual(status, "installed")
            self.assertTrue(hooks_path.is_symlink())
            self.assertEqual(json.loads(target.read_text())["custom"], "preserved")

    def test_install_rejects_managed_file_symlinks_before_hook_mutation(self):
        for file_key in ("adapter", "forwarder", "instance"):
            with self.subTest(file=file_key), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                home = root / "home"
                paths = CODEX_HOOK.user_paths(home)
                paths["hooks"].parent.mkdir(parents=True)
                original_hooks = b'{"custom":"preserved","hooks":{}}\n'
                paths["hooks"].write_bytes(original_hooks)
                paths[file_key].parent.mkdir(parents=True)
                outside = root / f"outside-{file_key}"
                outside_contents = (
                    b"0123456789abcdef01234567\n"
                    if file_key == "instance"
                    else MODULE_PATH.read_bytes()
                )
                outside.write_bytes(outside_contents)
                paths[file_key].symlink_to(outside)

                with self.assertRaises(ValueError):
                    CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

                self.assertEqual(paths["hooks"].read_bytes(), original_hooks)
                self.assertEqual(outside.read_bytes(), outside_contents)
                self.assertTrue(paths[file_key].is_symlink())
                self.assertEqual(
                    CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                    "invalid",
                )

    def test_uninstall_rejects_managed_file_symlinks_before_hook_mutation(self):
        for file_key in ("adapter", "forwarder", "instance"):
            with self.subTest(file=file_key), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                home = root / "home"
                paths = CODEX_HOOK.user_paths(home)
                self.assertEqual(
                    CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                    "installed",
                )
                original_hooks = paths["hooks"].read_bytes()
                outside = root / f"outside-{file_key}"
                outside_contents = (
                    b"fedcba9876543210fedcba98\n"
                    if file_key == "instance"
                    else b"external adapter must not change"
                )
                outside.write_bytes(outside_contents)
                paths[file_key].unlink()
                paths[file_key].symlink_to(outside)

                with self.assertRaises(ValueError):
                    CODEX_HOOK.uninstall_user_hook(home=home)

                self.assertEqual(paths["hooks"].read_bytes(), original_hooks)
                self.assertEqual(outside.read_bytes(), outside_contents)
                self.assertTrue(paths[file_key].is_symlink())
                self.assertEqual(
                    CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                    "invalid",
                )

    def test_managed_parent_symlinks_are_rejected_for_install_and_uninstall(self):
        for operation in ("install", "uninstall"):
            for component in ("support", "hooks-directory", "instance-directory"):
                with (
                    self.subTest(operation=operation, component=component),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = pathlib.Path(directory)
                    home = root / "home"
                    paths = CODEX_HOOK.user_paths(home)
                    managed_root = paths["adapter"].parent.parent.parent
                    link_paths = {
                        "support": managed_root,
                        "hooks-directory": managed_root / "codex-hooks",
                        "instance-directory": paths["adapter"].parent,
                    }
                    link_path = link_paths[component]
                    link_path.parent.mkdir(parents=True)
                    outside = root / f"outside-{operation}-{component}"
                    outside.mkdir()
                    sentinel = outside / "sentinel"
                    sentinel.write_bytes(b"outside directory must not change")
                    link_path.symlink_to(outside, target_is_directory=True)

                    paths["hooks"].parent.mkdir(parents=True)
                    if operation == "uninstall":
                        handler = CODEX_HOOK.hook_handler(paths["forwarder"])
                        document = {
                            "custom": "preserved",
                            "hooks": {
                                event_name: [{"hooks": [dict(handler)]}]
                                for event_name in CODEX_HOOK.USER_HOOK_EVENTS
                            },
                        }
                    else:
                        document = {"custom": "preserved", "hooks": {}}
                    paths["hooks"].write_text(json.dumps(document))
                    original_hooks = paths["hooks"].read_bytes()

                    with self.assertRaises(ValueError):
                        if operation == "install":
                            CODEX_HOOK.install_user_hook(
                                home=home,
                                source=MODULE_PATH,
                            )
                        else:
                            CODEX_HOOK.uninstall_user_hook(home=home)

                    self.assertEqual(paths["hooks"].read_bytes(), original_hooks)
                    self.assertEqual(
                        sentinel.read_bytes(),
                        b"outside directory must not change",
                    )
                    self.assertTrue(link_path.is_symlink())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_managed_special_files_are_rejected_before_hook_mutation(self):
        for file_key in ("adapter", "forwarder", "instance"):
            with self.subTest(file=file_key), tempfile.TemporaryDirectory() as directory:
                home = pathlib.Path(directory)
                paths = CODEX_HOOK.user_paths(home)
                paths["hooks"].parent.mkdir(parents=True)
                original_hooks = b'{"custom":"preserved","hooks":{}}\n'
                paths["hooks"].write_bytes(original_hooks)
                paths[file_key].parent.mkdir(parents=True)
                os.mkfifo(paths[file_key])

                with self.assertRaises(ValueError):
                    CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

                self.assertEqual(paths["hooks"].read_bytes(), original_hooks)

    def test_malformed_group_anywhere_invalidates_document(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            paths["hooks"].write_text(json.dumps({
                "hooks": {"UnknownFutureEvent": ["not-a-group"]}
            }))

            with self.assertRaises(ValueError):
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "invalid")
            self.assertFalse(paths["adapter"].exists())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_fifo_hooks_document_is_rejected_without_opening(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["hooks"].parent.mkdir(parents=True)
            os.mkfifo(paths["hooks"])

            with self.assertRaises(ValueError):
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "invalid")

    def test_config_hook_blockers_and_inline_warning_are_conservative(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["config"].parent.mkdir(parents=True)
            paths["config"].write_text(
                'note = "allow_managed_hooks_only = true"\n'
                '# [features]\n'
                '# hooks = false\n'
            )
            self.assertEqual(
                CODEX_HOOK.config_hook_diagnostics(paths["config"]),
                {"blockingStatus": None, "warnings": []},
            )

            paths["config"].write_text(
                '[hooks.state]\n'
                '[hooks.state."agent-meong"]\n'
                'decision = "allow"\n'
            )
            self.assertEqual(
                CODEX_HOOK.config_hook_diagnostics(paths["config"]),
                {"blockingStatus": None, "warnings": []},
            )

            for inline_hook in (
                '[[hooks.PreToolUse]]\n',
                '[hooks]\nPreToolUse = []\n',
                'hooks.PreToolUse = []\n',
                'hooks = { PreToolUse = [] }\n',
            ):
                with self.subTest(inline_hook=inline_hook):
                    paths["config"].write_text(inline_hook)
                    self.assertEqual(
                        CODEX_HOOK.config_hook_diagnostics(paths["config"])[
                            "warnings"
                        ],
                        [CODEX_HOOK.CONFIG_WARNING_INLINE_HOOKS],
                    )

            paths["config"].write_text(
                '[features]\n'
                'hooks = false\n'
                '[[hooks.PreToolUse]]\n'
            )

            diagnostics = CODEX_HOOK.config_hook_diagnostics(paths["config"])
            self.assertEqual(diagnostics["blockingStatus"], "hooks_disabled")
            self.assertEqual(
                diagnostics["warnings"],
                [CODEX_HOOK.CONFIG_WARNING_INLINE_HOOKS],
            )
            self.assertEqual(
                CODEX_HOOK.status_result("hooks_disabled", home=home),
                {
                    "status": "hooks_disabled",
                    "definitionId": CODEX_HOOK.HOOK_DEFINITION_ID,
                    "instanceId": None,
                    "managedHookPresent": False,
                    "runtimeStatus": "disabled",
                    "runtimeProblemEvents": list(CODEX_HOOK.USER_HOOK_EVENTS),
                    "warnings": [CODEX_HOOK.CONFIG_WARNING_INLINE_HOOKS],
                },
            )
            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "hooks_disabled")

            status = CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            self.assertEqual(status, "hooks_disabled")
            self.assertFalse(paths["hooks"].exists())
            self.assertFalse(paths["adapter"].exists())

            paths["config"].write_text("[features]\ncodex_hooks = false\n")
            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home),
                "hooks_disabled",
            )

            paths["config"].write_text(
                "[features]\nhooks = true\ncodex_hooks = false\n"
            )
            self.assertIsNone(
                CODEX_HOOK.config_hook_diagnostics(paths["config"])["blockingStatus"]
            )

            paths["config"].write_text("features.hooks = false\n")
            self.assertEqual(
                CODEX_HOOK.config_hook_diagnostics(paths["config"])["blockingStatus"],
                "hooks_disabled",
            )
            paths["config"].write_text(
                "features = { codex_hooks = false, hooks = true }\n"
            )
            self.assertIsNone(
                CODEX_HOOK.config_hook_diagnostics(paths["config"])["blockingStatus"]
            )
            paths["config"].write_text("features = { hooks = false }\n")
            self.assertEqual(
                CODEX_HOOK.config_hook_diagnostics(paths["config"])["blockingStatus"],
                "hooks_disabled",
            )

            paths["config"].write_text("allow_managed_hooks_only = true\n")
            self.assertIsNone(
                CODEX_HOOK.config_hook_diagnostics(paths["config"])["blockingStatus"]
            )
            status = CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            self.assertEqual(status, "installed")
            self.assertTrue(paths["hooks"].is_file())
            self.assertTrue(paths["adapter"].is_file())

            requirements = pathlib.Path(directory) / "requirements.toml"
            paths["config"].write_text("[features]\nhooks = false\n")
            requirements.write_text("[features]\nhooks = true\n")
            self.assertEqual(
                CODEX_HOOK.effective_hook_diagnostics(paths["config"], requirements),
                {"blockingStatus": None, "warnings": []},
            )
            requirements.write_text(
                "allow_managed_hooks_only = true\n[features]\nhooks = true\n"
            )
            self.assertEqual(
                CODEX_HOOK.effective_hook_diagnostics(paths["config"], requirements)[
                    "blockingStatus"
                ],
                "managed_hooks_only",
            )

            system_config = pathlib.Path(directory) / "system-config.toml"
            requirements.write_text("")
            paths["config"].write_text("")
            system_config.write_text("[features]\nhooks = false\n")
            self.assertEqual(
                CODEX_HOOK.effective_hook_diagnostics(
                    paths["config"], requirements, system_config
                )["blockingStatus"],
                "hooks_disabled",
            )
            paths["config"].write_text("[features]\nhooks = true\n")
            self.assertIsNone(
                CODEX_HOOK.effective_hook_diagnostics(
                    paths["config"], requirements, system_config
                )["blockingStatus"]
            )
            paths["config"].write_text("")
            system_config.write_text("allow_managed_hooks_only = true\n")
            self.assertIsNone(
                CODEX_HOOK.effective_hook_diagnostics(
                    paths["config"], requirements, system_config
                )["blockingStatus"]
            )

    def test_blocking_policy_reports_existing_managed_hook(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            paths["config"].write_text("[features]\nhooks = false\n")

            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "hooks_disabled")
            self.assertEqual(
                CODEX_HOOK.status_result("hooks_disabled", home=home)[
                    "managedHookPresent"
                ],
                True,
            )

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_special_config_file_is_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["config"].parent.mkdir(parents=True)
            os.mkfifo(paths["config"])

            with self.assertRaises(ValueError):
                CODEX_HOOK.user_hook_status(home=home)
            with self.assertRaises(ValueError):
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            self.assertFalse(paths["hooks"].exists())
            self.assertFalse(paths["adapter"].exists())

    def test_parent_symlink_alias_resolves_to_same_hook_lock_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            real = root / "real-codex"
            alias = root / "alias-codex"
            real.mkdir()
            alias.symlink_to(real, target_is_directory=True)

            real_target, _ = CODEX_HOOK._resolved_regular_path(real / "hooks.json")
            alias_target, _ = CODEX_HOOK._resolved_regular_path(alias / "hooks.json")
            self.assertEqual(real_target, alias_target)
            self.assertEqual(
                CODEX_HOOK.user_paths(root / "home", real)["adapter"],
                CODEX_HOOK.user_paths(root / "home", alias)["adapter"],
            )

    def test_install_rolls_back_managed_files_if_hook_commit_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["adapter"].parent.mkdir(parents=True)
            paths["adapter"].write_bytes(b"previous-adapter")
            paths["forwarder"].write_bytes(b"previous-forwarder")
            paths["forwarder"].chmod(0o700)

            with mock.patch.object(
                CODEX_HOOK,
                "write_json_atomic",
                side_effect=OSError("simulated hook write failure"),
            ):
                with self.assertRaises(OSError):
                    CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertEqual(paths["adapter"].read_bytes(), b"previous-adapter")
            self.assertEqual(
                paths["forwarder"].read_bytes(),
                b"previous-forwarder",
            )
            self.assertFalse(paths["instance"].exists())
            self.assertFalse(paths["hooks"].exists())

    def test_install_preserves_command_targets_after_committed_fsync_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            original_write = CODEX_HOOK.write_json_atomic
            real_fsync = os.fsync

            def fail_directory_sync_after_replace(path, document):
                call_count = 0

                def fail_second_sync(descriptor):
                    nonlocal call_count
                    call_count += 1
                    if call_count == 2:
                        raise OSError("simulated directory sync failure")
                    return real_fsync(descriptor)

                with mock.patch.object(os, "fsync", side_effect=fail_second_sync):
                    original_write(path, document)

            with mock.patch.object(
                CODEX_HOOK,
                "write_json_atomic",
                new=fail_directory_sync_after_replace,
            ):
                with self.assertRaises(CODEX_HOOK.AtomicReplaceCommittedError):
                    CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertTrue(paths["hooks"].exists())
            self.assertTrue(paths["adapter"].is_file())
            self.assertTrue(paths["forwarder"].is_file())
            self.assertTrue(paths["instance"].is_file())
            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                "installed",
            )

    def test_install_rejects_group_or_world_writable_managed_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            paths["adapter"].parent.mkdir(parents=True)
            paths["adapter"].parent.chmod(0o777)

            with self.assertRaises(ValueError):
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            self.assertFalse(paths["hooks"].exists())
            self.assertFalse(paths["adapter"].exists())
            self.assertFalse(paths["forwarder"].exists())
            self.assertFalse(paths["instance"].exists())

    def test_writable_managed_file_fails_closed_and_safe_mode_drift_repairs(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)

            for key, safe_mode in (
                ("adapter", 0o600),
                ("forwarder", 0o700),
                ("instance", 0o600),
            ):
                with self.subTest(unsafe_file=key):
                    paths[key].chmod(0o777)
                    self.assertEqual(
                        CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                        "invalid",
                    )
                    with self.assertRaises(ValueError):
                        CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
                    paths[key].chmod(safe_mode)

            paths["adapter"].chmod(0o644)
            paths["forwarder"].chmod(0o755)
            paths["instance"].chmod(0o644)
            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                "needs_repair",
            )
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            self.assertEqual(paths["adapter"].stat().st_mode & 0o777, 0o600)
            self.assertEqual(paths["forwarder"].stat().st_mode & 0o777, 0o700)
            self.assertEqual(paths["instance"].stat().st_mode & 0o777, 0o600)

    def test_uninstall_rolls_back_adapter_if_hook_commit_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            original_hooks = paths["hooks"].read_bytes()
            original_instance = paths["instance"].read_bytes()
            original_forwarder = paths["forwarder"].read_bytes()

            with mock.patch.object(
                CODEX_HOOK,
                "write_json_atomic",
                side_effect=OSError("simulated hook write failure"),
            ):
                with self.assertRaises(OSError):
                    CODEX_HOOK.uninstall_user_hook(home=home)

            self.assertEqual(paths["hooks"].read_bytes(), original_hooks)
            self.assertEqual(paths["adapter"].read_bytes(), MODULE_PATH.read_bytes())
            self.assertEqual(paths["forwarder"].read_bytes(), original_forwarder)
            self.assertEqual(paths["instance"].read_bytes(), original_instance)
            self.assertEqual(CODEX_HOOK.user_hook_status(home=home), "installed")

    def test_install_script_surfaces_json_error_on_stderr(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            codex_home = root / "codex"
            codex_home.mkdir(parents=True)
            (codex_home / "hooks.json").write_text("not-json")
            environment = dict(os.environ, HOME=str(home), CODEX_HOME=str(codex_home))

            result = subprocess.run(
                [str(MODULE_PATH.parent.parent / "scripts" / "install-codex-hook")],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertIn('"status": "error"', result.stderr)

    def test_changed_installed_adapter_is_reported_for_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            CODEX_HOOK.user_paths(home)["adapter"].write_text("changed")

            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                "needs_repair",
            )

    def test_missing_or_changed_native_forwarder_is_reported_for_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            paths["forwarder"].unlink()
            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                "needs_repair",
            )
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            paths["forwarder"].write_bytes(b"changed")
            paths["forwarder"].chmod(0o700)
            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                "needs_repair",
            )

    def test_missing_or_path_derived_instance_is_repaired_with_random_id(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            paths = CODEX_HOOK.user_paths(home)
            CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH)
            paths["instance"].unlink()

            self.assertEqual(
                CODEX_HOOK.user_hook_status(home=home, source=MODULE_PATH),
                "needs_repair",
            )
            self.assertEqual(
                CODEX_HOOK.install_user_hook(home=home, source=MODULE_PATH),
                "installed",
            )
            instance_id = paths["instance"].read_text().strip()
            self.assertRegex(instance_id, r"^[0-9a-f]{24}$")
            self.assertNotEqual(instance_id, paths["adapter"].parent.name)

    def test_explicit_codex_home_controls_hook_location(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            codex_home = root / "custom-codex"

            status = CODEX_HOOK.install_user_hook(
                home=home,
                codex_home=codex_home,
                source=MODULE_PATH,
            )

            self.assertEqual(status, "installed")
            self.assertTrue((codex_home / "hooks.json").is_file())
            self.assertFalse((home / ".codex" / "hooks.json").exists())

    def test_custom_codex_homes_have_independent_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            home = root / "home"
            codex_a = root / "codex-a"
            codex_b = root / "codex-b"
            paths_a = CODEX_HOOK.user_paths(home, codex_a)
            paths_b = CODEX_HOOK.user_paths(home, codex_b)

            self.assertNotEqual(paths_a["adapter"], paths_b["adapter"])
            self.assertEqual(
                CODEX_HOOK.install_user_hook(
                    home=home, codex_home=codex_a, source=MODULE_PATH
                ),
                "installed",
            )
            self.assertEqual(
                CODEX_HOOK.install_user_hook(
                    home=home, codex_home=codex_b, source=MODULE_PATH
                ),
                "installed",
            )
            instance_a = paths_a["instance"].read_text().strip()
            instance_b = paths_b["instance"].read_text().strip()
            self.assertNotEqual(instance_a, instance_b)
            self.assertNotEqual(instance_a, paths_a["adapter"].parent.name)
            self.assertNotEqual(instance_b, paths_b["adapter"].parent.name)

            self.assertEqual(
                CODEX_HOOK.install_user_hook(
                    home=home, codex_home=codex_b, source=MODULE_PATH
                ),
                "installed",
            )
            self.assertEqual(paths_b["instance"].read_text().strip(), instance_b)

            self.assertEqual(
                CODEX_HOOK.uninstall_user_hook(home=home, codex_home=codex_a),
                "not_installed",
            )
            self.assertFalse(paths_a["adapter"].exists())
            self.assertFalse(paths_a["instance"].exists())
            self.assertTrue(paths_b["adapter"].is_file())
            self.assertEqual(
                CODEX_HOOK.user_hook_status(
                    home=home, codex_home=codex_b, source=MODULE_PATH
                ),
                "installed",
            )

    def test_e2e_delivery_mode_exposes_transport_failure(self):
        args = mock.Mock(
            install=False,
            uninstall=False,
            status=False,
            print_only=False,
        )
        observation = {"schemaVersion": 0}
        with (
            mock.patch.object(CODEX_HOOK, "parse_args", return_value=args),
            mock.patch.object(CODEX_HOOK, "read_payload", return_value={}),
            mock.patch.object(CODEX_HOOK, "normalize", return_value=observation),
            mock.patch.object(CODEX_HOOK, "send", return_value=False),
            mock.patch.dict(
                os.environ,
                {"AGENT_MEONG_E2E_REQUIRE_DELIVERY": "1"},
            ),
        ):
            self.assertEqual(CODEX_HOOK.run(), 1)

        with (
            mock.patch.object(CODEX_HOOK, "parse_args", return_value=args),
            mock.patch.object(CODEX_HOOK, "read_payload", return_value={}),
            mock.patch.object(CODEX_HOOK, "normalize", return_value=observation),
            mock.patch.object(CODEX_HOOK, "send", return_value=False),
            mock.patch.dict(os.environ, {}, clear=True),
        ):
            self.assertEqual(CODEX_HOOK.run(), 0)

    def test_argument_parser_preserves_event_and_management_modes(self):
        cases = {
            (): (False, False, False, False),
            ("--print",): (True, False, False, False),
            ("--install",): (False, True, False, False),
            ("--uninstall",): (False, False, True, False),
            ("--status",): (False, False, False, True),
            ("--print", "--status"): (True, False, False, True),
        }
        for arguments, expected in cases.items():
            with (
                self.subTest(arguments=arguments),
                mock.patch.object(sys, "argv", [str(MODULE_PATH), *arguments]),
            ):
                parsed = CODEX_HOOK.parse_args()
                self.assertEqual(
                    (
                        parsed.print_only,
                        parsed.install,
                        parsed.uninstall,
                        parsed.status,
                    ),
                    expected,
                )

        for arguments in (("--unknown",), ("--install", "--status")):
            with (
                self.subTest(arguments=arguments),
                mock.patch.object(sys, "argv", [str(MODULE_PATH), *arguments]),
                mock.patch.object(sys, "stderr", new=io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                CODEX_HOOK.parse_args()

    def test_send_rejects_non_socket_and_symlink_endpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            regular = root / "regular"
            regular.write_text("not a socket")
            link = root / "link"
            link.symlink_to(regular)

            for endpoint in (regular, link):
                with (
                    self.subTest(endpoint=endpoint.name),
                    mock.patch.object(CODEX_HOOK, "socket_path", return_value=str(endpoint)),
                    mock.patch.object(CODEX_HOOK.socket, "socket") as socket_constructor,
                ):
                    self.assertFalse(CODEX_HOOK.send({"schemaVersion": 0}))
                    socket_constructor.assert_not_called()

    def test_send_rejects_socket_path_owned_by_another_user(self):
        endpoint = mock.Mock(
            st_mode=CODEX_HOOK.stat.S_IFSOCK | 0o600,
            st_uid=os.getuid() + 1,
        )
        with (
            mock.patch.object(CODEX_HOOK.os, "lstat", return_value=endpoint),
            mock.patch.object(CODEX_HOOK.socket, "socket") as socket_constructor,
        ):
            self.assertFalse(CODEX_HOOK.send({"schemaVersion": 0}))
            socket_constructor.assert_not_called()

    def test_send_verifies_connected_peer_before_writing(self):
        endpoint = mock.Mock(
            st_mode=CODEX_HOOK.stat.S_IFSOCK | 0o600,
            st_uid=os.getuid(),
        )
        client = mock.Mock()
        with (
            mock.patch.object(CODEX_HOOK.os, "lstat", return_value=endpoint),
            mock.patch.object(CODEX_HOOK.socket, "socket", return_value=client),
            mock.patch.object(
                CODEX_HOOK,
                "peer_effective_uid",
                return_value=os.getuid() + 1,
            ),
        ):
            self.assertFalse(CODEX_HOOK.send({"schemaVersion": 0}))

        client.connect.assert_called_once()
        client.sendall.assert_not_called()
        client.close.assert_called_once()

    def test_send_writes_only_to_an_owned_same_user_peer(self):
        endpoint = mock.Mock(
            st_mode=CODEX_HOOK.stat.S_IFSOCK | 0o600,
            st_uid=os.getuid(),
        )
        client = mock.Mock()
        with (
            mock.patch.object(CODEX_HOOK.os, "lstat", return_value=endpoint),
            mock.patch.object(CODEX_HOOK.socket, "socket", return_value=client),
            mock.patch.object(
                CODEX_HOOK,
                "peer_effective_uid",
                return_value=os.getuid(),
            ),
        ):
            self.assertTrue(CODEX_HOOK.send({"schemaVersion": 0}))

        client.sendall.assert_called_once_with(b'{"schemaVersion":0}\n')
        client.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
