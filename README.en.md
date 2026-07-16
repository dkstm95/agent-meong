# agent-meong

[한국어](README.md) | English

`agent-meong` is a macOS menu bar app that represents the activity of AI agents
running on the same Mac as simple moving dots and tadpoles. It is designed for
the moment when you have delegated several tasks and want to step away while
still sensing that work is moving and gradually winding down.

“Meong” (`멍`) is Korean for the pleasant moment of letting your mind go blank.

## What you will see

- A working main agent bounces gently in the menu bar.
- Clicking the menu bar icon immediately opens Meong Space, attached to the icon.
- A subagent is born from its main agent and returns to be absorbed when its end is observed.
- A main/subagent family keeps the same color family as its state changes.
- When one top-level agent turn ends, a menu bar signal appears and an agent-family receipt
  remains until viewed.
- Activity and objects diminish as the observed work winds down.

![agent-meong Meong Space attached to its menu bar icon](docs/images/agent-meong.png)

This is not a detailed log or productivity dashboard. It visualizes only a
small set of real lifecycle signals without collecting prompts, responses,
commands, file paths, or tool input/output. See [Product Principles](docs/product-principles.md)
for the product and design criteria.

## Current scope and limitations

- Requires macOS 14 or later.
- OpenAI Codex is the only observation source currently supported.
- Only Codex in the ChatGPT desktop app (Codex App) and Codex CLI tasks running
  **locally on this Mac** are observed. Codex cloud/web tasks, other Macs, and
  remote runners are not observed.
- Local Codex App and CLI instances using the default `~/.codex` share one connection.
- Activity from both Codex App and CLI can be observed, but the initial command-hook
  security review and trust step currently requires `/hooks` in Codex CLI.
- The GitHub source installer is currently the only official installation
  method. Prebuilt `.app`/`.zip` downloads and automatic updates are
  intentionally deferred until later.
- Codex `Stop` means that one agent turn ended. It does not mean the entire
  task/thread succeeded or failed, and agent-meong does not infer outcomes that
  Codex did not provide.

## Preflight

You need the following. Before installing, `scripts/install-app` automatically
checks macOS, Xcode Command Line Tools, Swift, and Python, and warns when Codex
CLI is missing. Use these commands to check everything yourself, including
whether the CLI supports `/hooks`.

- Xcode Command Line Tools and Swift 6
- `/usr/bin/python3`, supplied by the Command Line Tools
- A current Codex CLI version that supports `/hooks`
- A local Codex App or Codex CLI instance to observe

Check them in Terminal:

```bash
xcode-select -p
swift --version
/usr/bin/python3 --version
codex --version
```

If `xcode-select -p` fails, run `xcode-select --install` and wait for the
installation to finish. If Swift is not 6.x, update Xcode Command Line Tools.

If `codex --version` fails or Codex CLI does not have `/hooks`, follow the
[official Codex CLI installation guide](https://developers.openai.com/codex/cli),
or install/update it with OpenAI's official standalone installer:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
```

## Install

```bash
git clone https://github.com/dkstm95/agent-meong.git "$HOME/agent-meong"
cd "$HOME/agent-meong"
bash scripts/install-app
```

The script checks the required build environment, creates a release build, verifies
its ad-hoc signature, and installs it at `~/Applications/AgentMeong.app`. It
also configures a per-user automatic-start item and launches the app. It does
not require `sudo`. There is no Dock icon. On first launch, connection guidance
opens automatically from the round menu bar icon. After a successful install,
the large local build caches at `dist/` and `macos/.build/` are removed by
default. Keep `$HOME/agent-meong` for updates and complete uninstallation
because there is no auto-update.

## Connect Codex and review security

1. Select `Connect & copy /hooks` (`연결하고 /hooks 복사`) once on
   agent-meong's first screen.
2. The app preserves existing settings while adding a user hook to the default
   `~/.codex`, installs its adapter below
   `~/Library/Application Support/AgentMeong/codex-hooks/`, and copies
   `/hooks` to the clipboard.
3. Fully quit every running Codex App and Codex CLI instance, then reopen them.
   Codex does not reliably reload a live `hooks.json` change, so this is required.
4. Paste `/hooks` into a local task in the newly opened Codex CLI.
5. Trust the definitions under the `User config` source only if all items below match.

### `/hooks` checklist

- One handler marked `agent-meong activity [dev.ailab.agent-meong/v4]` appears
  under each of these seven events. Existing hooks installed by the user may
  also appear and must be reviewed separately.
  - `UserPromptSubmit`
  - `PreToolUse`
  - `PermissionRequest`
  - `PostToolUse`
  - `SubagentStart`
  - `SubagentStop`
  - `Stop`
- All seven agent-meong handlers have type `command`.
- Every agent-meong command has this shape. Your home directory and the
  24-character hexadecimal opaque directory value will differ.

  ```text
  /usr/bin/python3 '/Users/<you>/Library/Application Support/AgentMeong/codex-hooks/<24-hex>/codex_hook.py'
  ```

- `statusMessage` is exactly
  `agent-meong activity [dev.ailab.agent-meong/v4]`.
- `timeout` is 2 seconds and the handler is not `async`.

If anything differs, do not trust it. Update the app and checkout, then inspect
the definitions again. It is normal to see lifecycle events and commands rather
than a separate hook named `agent-meong`. Codex skips a new or changed definition
until you trust it. See the [official Codex Hooks documentation](https://learn.chatgpt.com/docs/hooks)
for details about the security model.

agent-meong preserves the definitions and relative order of other hooks. However,
Codex hook trust keys currently include a hook's position within its event. Repairing
duplicate older agent-meong entries or removing agent-meong can shift a later entry,
so another user hook may need review again. Recheck the entire `User config` source
in `/hooks` after repair or disconnect.

### Confirm with a real event

After trusting the definitions, open a **new local task** in Codex in the
ChatGPT desktop app or Codex CLI on the same Mac and send one short prompt.
Make sure it is not a cloud task.

When connected:

- agent-meong closes its connection guidance automatically;
- the top-left chip changes to `Codex · just now` (`Codex · 방금`); and
- a moving main-agent dot appears in Meong Space.
- A short, one-time guide explains movement, the needs-attention ring, and the turn-end
  ripple after the first real event.

The app does not infer success from the presence of hook files. It reports a
connection only after receiving the first real event.

## Everyday use

- The menu bar dot bounces while agents are working.
- Left-click the icon to open Meong Space. Click outside it to close it.
- Concurrent local tasks appear as separate main and subagent objects.
- Members of one main/subagent family share a color family. Color is a relationship cue,
  not a unique ID, and state meaning also uses rings, segmented rings, open arcs, double
  halos, bars, and diamonds.
- An observed tool start or finish produces only a brief dot impulse on that object. It does
  not claim that a tool remains active or expose its payload.
- A blue menu bar signal appears when one top-level turn ends. This is a Codex
  turn-end observation, not a success verdict for the entire thread. If Meong Space is closed,
  up to four of the most recent distinct agent families leave individual receipts for the next
  opening. This is a recent-family count, not the total number of unseen turns.
- Right-click the icon for status, `Open Meong Space`, and `Quit`.
- To reopen the app, open `~/Applications/AgentMeong.app` in Finder or run:

  ```bash
  open "$HOME/Applications/AgentMeong.app"
  ```

### Launch at Login

By default, the installer creates the per-user
`~/Library/LaunchAgents/dev.ailab.agent-meong.plist`, so the app opens from the
next login. To turn it off or back on later, change `AgentMeong` under
`System Settings > General > Login Items > App Background Activity`. Because
the GitHub source build uses an ad-hoc signature, some macOS versions may show
`Item from unidentified developer` as its detail. Updates preserve the
validated existing item and a state the user disabled in macOS.

Advanced users who do not want the item created can use this command for the
first installation instead. This option does not change or remove an item that
already exists.

```bash
cd "$HOME/agent-meong"
AGENT_MEONG_START_AT_LOGIN=0 bash scripts/install-app
```

The app respects Reduce Motion and Increase Contrast settings. VoiceOver
exposes counts for quiet, active, needs-attention, uncertain, finished,
completed, cancelled, and failed states, plus the ring, segmented-ring,
open-arc, double-halo, bar, and diamond grammar as text.

## Update

There are no automatic updates. Run these commands in the directory you cloned:

```bash
cd "$HOME/agent-meong"
git pull --ff-only
bash scripts/install-app
```

The installer builds and verifies the new app before quitting and replacing the
running version. If replacement fails, it restores the previous bundle and
reopens it when it was running. In the rare case that the new app refuses to
quit, the installer does not delete the live bundle; it prints the recoverable
previous-bundle path and exits with failure. It also preserves a valid
automatic-start item and a user-disabled state. If you see `Repair required`
(`복구 필요`) after relaunch, select `Repair & copy /hooks` (`복구하고 /hooks 복사`).
Then fully quit and reopen Codex App and CLI, inspect the complete `/hooks`
source, trust matching definitions, and confirm with a new local prompt.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| No menu bar icon | Run `open "$HOME/Applications/AgentMeong.app"`. If it still fails, inspect the Terminal error from `bash scripts/install-app`. |
| App did not open after login | Check whether `AgentMeong` is off under `System Settings > General > Login Items > App Background Activity`. `Item from unidentified developer` is an expected detail for the source build. |
| Codex has no `/hooks` | Install or update Codex CLI using the [official guide](https://developers.openai.com/codex/cli). |
| `Check required` or `Waiting for event` | Check that Codex App and CLI were fully reopened, `/hooks` trust is complete, the task is local on the same Mac, and you sent a new prompt. |
| `Repair required` | Select `Repair & copy /hooks`, fully reopen Codex App and CLI, then review all of `/hooks`; other hook definitions and settings are preserved. |
| `Hooks off` | Check `[features] hooks = false` in the active Codex settings. Ask your administrator if policy enforces it. |
| `Policy restricted` | `allow_managed_hooks_only = true` in `requirements.toml` or managed policy is blocking user hooks and requires an administrator change. |
| `Check configuration` | Repair the JSON syntax in `hooks.json` for the current Codex home. agent-meong will not overwrite a malformed file. |
| `Check source` | Inline hooks in `config.toml` and `hooks.json` are both loading. Review every source in `/hooks`. |
| `Check format` | Align the app and checkout versions, then select `Repair & copy /hooks`. |

If the issue remains, get the source revision and local changed-file count with
these commands. A second value of `0` means the checkout is clean.

```bash
cd "$HOME/agent-meong"
git rev-parse --short HEAD
git status --porcelain | wc -l
```

Open a [GitHub Issue](https://github.com/dkstm95/agent-meong/issues) with the
revision, changed-file count, and visible status. Do not attach prompts,
responses, commands, file paths, or tool payloads.

## Custom `CODEX_HOME`

An app launched from Finder does not automatically know a custom `CODEX_HOME`
from your shell. Install from the same environment the CLI uses:

```bash
cd "$HOME/agent-meong"
CODEX_HOME="/absolute/path/to/codex-home" bash scripts/install-codex-hook
```

Then fully quit and reopen Codex App and CLI instances using that home, apply the
`/hooks` checklist, and send a new local prompt. You can connect multiple custom
homes the same way. To honor its privacy boundary, agent-meong does not store
the actual custom-home path, so you must retain that path.

## Disconnect Codex

### Default `~/.codex`

Open the connection chip in the app and select `Disconnect` (`연결 해제`). This
removes only agent-meong's handlers and adapter while preserving other Codex
settings and hooks. On success it also clears the scene, connection record, and
restart checkpoint. Fully quit and reopen Codex App and CLI afterward, then
recheck trust for the other user hooks in `/hooks`.

You can remove only the hook from a source checkout:

```bash
cd "$HOME/agent-meong"
bash scripts/uninstall-codex-hook
```

That command does not directly clear the running app's scene or saved connection
record, so use the in-app action when you intend to keep using agent-meong. With
either method, fully reopen running Codex App and CLI instances after removal.

### Custom `CODEX_HOME`

Use the same path and environment used during installation:

```bash
cd "$HOME/agent-meong"
CODEX_HOME="/absolute/path/to/codex-home" bash scripts/uninstall-codex-hook
```

Repeat the shell removal for every connected custom home and fully reopen the
Codex App and CLI instances that use each home. Only after the last custom home
is removed, select `Forget connection record` (`연결 기록 지우기`) once to clear
the aggregate local scene and confirmation record.

## Completely uninstall the app and data

Order matters. Deleting the support directory while a custom hook remains would
leave Codex invoking a missing adapter path.

If you already deleted `$HOME/agent-meong`, clone the official repository back
to the same location before continuing:

```bash
git clone https://github.com/dkstm95/agent-meong.git "$HOME/agent-meong"
```

1. Remove the hook from every connected custom `CODEX_HOME` first:

   ```bash
   cd "$HOME/agent-meong"
   CODEX_HOME="/absolute/path/to/codex-home" bash scripts/uninstall-codex-hook
   ```

2. Run the full uninstaller in the default environment:

   ```bash
   cd "$HOME/agent-meong"
   bash scripts/uninstall-app
   ```

   Even if your shell exports a custom `CODEX_HOME`, this command deliberately
   removes the default `~/.codex` connection.

The script removes the default hook first. If another custom adapter remains,
it stops before deleting the app or its data. Remove that hook from its custom
home as in step 1, then run the uninstaller again. Once every connection is
gone, it quits the installed app and removes the automatic-start item, app
bundle, checkpoint, UserDefaults, and default socket and lock. If unexpected
support data or an unsafe socket item must be retained, it does not report
success: it prints the remaining paths and exits nonzero. If the automatic-start
item does not exactly match the agent-meong definition, the script does not
overwrite or remove it; it stops safely before removing the app or its data.

If the script finds a shared adapter from an older alpha, it cannot safely tell
whether a custom home still refers to it, so it stops. Only after you have
personally confirmed that every custom home is disconnected, remove it explicitly:

```bash
cd "$HOME/agent-meong"
AGENT_MEONG_REMOVE_LEGACY_ADAPTER=1 bash scripts/uninstall-app
```

The source checkout itself is never deleted for safety. After the uninstaller
succeeds, move `$HOME/agent-meong` to the Trash in Finder to remove the source
as well. A successful install removes `dist/` and `macos/.build/` by default.
If you kept them for contribution with `AGENT_MEONG_KEEP_BUILD_ARTIFACTS=1`,
delete them together with the clone.

## Privacy

The Codex hook receives the original JSON but does not store, log, or send:

- prompts or responses;
- commands or file paths; or
- tool input/output.

Only this derived metadata crosses the user-only Unix socket:

- SHA-256-based, 32-character opaque session, turn, and agent IDs;
- lifecycle event kinds and `shell`, `edit`, `search`, `browser`, or `other` tool categories;
- a hook-definition version and opaque instance that does not disclose the actual path; and
- termination facts explicitly provided by Codex.

The short-restart checkpoint stores only derived metadata for active, attention,
and uncertain objects in a user-only file. It does not store raw events or
finished, completed, failed, or cancelled objects. See the
[protocol schema](protocol/event-v0.schema.json) for the observation boundary.

## Development and contribution

- [Contributing guide](CONTRIBUTING.md)
- [Product principles](docs/product-principles.md)
- [Local packaging and release procedure](docs/releasing.md)
- Full checks: `bash scripts/check`
- Aqua GUI E2E: `bash scripts/check-e2e`
- Real Codex CLI acceptance: `bash scripts/check-codex-cli-acceptance`

## License

[MIT License](LICENSE)
