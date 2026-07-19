# agent-meong

[한국어](README.md) | English

`agent-meong` is a macOS menu bar app that represents the activity of AI agents
running on the same Mac as simple moving dots and tadpoles. It is designed for
the moment when you have delegated several tasks and want to step away while
still sensing that work is moving and gradually winding down. Objects are
anonymous: the app does not display prompts, responses, task names, or chat
titles.

“Meong” (`멍`) is Korean for the pleasant moment of letting your mind go blank.

## What you will see

You only need to learn three signals first:

- **Movement**: an agent is active.
- **Ring**: the agent needs your attention.
- **Outward ripple**: one top-level agent turn ended. This does not mean that
  the entire task succeeded.

Everything else follows a few simple rules:

- A working main agent bounces gently in the menu bar.
- Clicking the menu bar icon immediately opens Meong Space, attached to the icon.
- A subagent is born from its main agent and returns to be absorbed when its end is observed.
- Each object's body color and shape show that agent's own current state. When
  its state changes, that object changes color.
- The menu bar icon does not collapse all agents into one priority color. Like
  one virtual Agent Key, it briefly shows recent agent state transitions in order.
  Its bounce is separate: it means at least one agent is active.
- Parent-child relationships appear through birth, absorption, and nearby movement,
  rather than a fixed identity color. Marker shapes and VoiceOver carry the same
  facts without relying on color.
- When one top-level agent turn ends, a menu bar signal appears and an agent-family receipt
  remains until viewed during the current app session.
- Activity and objects diminish as the observed work winds down.

See [Reading color](#reading-color) for every menu bar color and shape at a glance.

This is not a detailed log or productivity dashboard. It never stores or logs
prompts, responses, commands, file paths, or tool input/output, or forwards
them to the macOS app. It visualizes only a small set of activity signals. See
[Product Principles](docs/product-principles.md) for the product and design criteria.

## Quick start

Only GitHub source installation is available today. You need macOS 14 or later,
Xcode Command Line Tools and Swift 6, and a local Codex version with `/hooks`.
It does not require `sudo`, and it starts automatically when you log in after
installation.

1. Press `⌘ Space`, search for `Terminal`, and open it.
2. On a Mac that has not built software before, run this first:

   ```bash
   xcode-select -p
   ```

   If it prints a path such as `/Library/Developer/CommandLineTools`, continue
   to step 3. If it prints an error, run `xcode-select --install`, **wait for
   that installation to finish**, and then continue.
3. Copy **all three lines** below, paste the whole block into Terminal, and
   press `Return`:

   ```bash
   git clone https://github.com/dkstm95/agent-meong.git "$HOME/agent-meong"
   cd "$HOME/agent-meong"
   bash scripts/install-app
   ```

   The first release build may print many lines for several minutes. If you see
   a line beginning with `Building agent-meong`, it is working; do not close
   Terminal. Installation is complete when the final lines include one beginning
   with `Installed agent-meong at`.

   If you see `destination path ... already exists`, a source folder is already
   there. Do not delete it without checking it; use the [Update](#update)
   commands instead.
4. Select `Connect` in the agent-meong popover that opens.
5. agent-meong opens a new Terminal and launches Codex automatically. When
   `Hooks need review` appears, select `Review hooks`. In the normal flow you
   do not paste `/hooks` and run it with `Return` yourself.
6. Under `User config`, review the seven lifecycle events and their command
   definitions shown by the app, then trust them. It is normal that Codex does
   not show a separate hook named `agent-meong`. You may use `Trust all` when
   the app confirms that no other hooks are waiting. If it reports another
   pending count, trust only these seven entries individually.
7. Open the menu bar icon. `Codex · waiting for activity` means **setup is
   complete**. You may close the review Terminal. Use local Codex normally and
   the first activity will appear automatically. Sending a short request in
   the opened CLI is only an optional immediate test.

`Codex · waiting for activity` means that hook setup and trust are complete,
but no real activity has arrived yet. After the first signal, you will see
`Codex · just now` and a moving object. Fully quit and reopen any Codex App
or CLI that was already open before connection. Remote and web tasks are not
shown.
[Disconnecting Codex](#disconnect-codex) is different from
[removing the app, automatic start, and data](#completely-uninstall-the-app-and-data).

## Current scope and limitations

- Requires macOS 14 or later.
- OpenAI Codex is the only observation source currently supported.
- Only the standalone Codex App, Codex inside the ChatGPT desktop app, and
  Codex CLI tasks running **locally on this Mac** are observed. Regular ChatGPT
  conversations, Codex cloud/web tasks, other Macs, and remote runners are not
  observed.
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
checks macOS, Xcode Command Line Tools, Swift, and Python. After installation,
agent-meong checks the Codex executable and hook state when you select `Connect`
and explains any required action in the same screen.

- Xcode Command Line Tools and Swift 6
- `/usr/bin/python3`, supplied by the Command Line Tools
- A current Codex App, Codex inside the ChatGPT desktop app, or Codex CLI
  version that supports `/hooks`
- A local Codex task to observe

Check them in Terminal:

```bash
xcode-select -p
swift --version
/usr/bin/python3 --version
codex --version # when using the standalone CLI
```

If `xcode-select -p` fails, run `xcode-select --install` and wait for the
installation to finish. If Swift is not 6.x, open
`System Settings > General > Software Update` and install available macOS and
Xcode Command Line Tools updates.

If ChatGPT and Codex App are absent and `codex --version` fails or lacks
`/hooks`, follow the
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

You can copy and paste that entire block into Terminal. The script checks the
required build environment, creates a release build, verifies
its ad-hoc signature, and installs it at `~/Applications/AgentMeong.app`. It
also configures a per-user automatic-start item and launches the app. It does
not require `sudo`. There is no Dock icon. On first launch, connection guidance
opens automatically from the round menu bar icon. After a successful install,
the large local build caches at `dist/` and `macos/.build/` are removed by
default. Keep `$HOME/agent-meong` for updates and complete uninstallation
because there is no auto-update.

`destination path ... already exists` means that folder is already present. If
you downloaded agent-meong before, use [Update](#update). If the folder contains
something else or an incomplete download, rename it in Finder and install
again. Do not delete a folder without checking its contents.

## Connect Codex and review security

1. Select `Connect` once on agent-meong's first screen.
2. agent-meong preserves existing settings while installing lifecycle hooks and
   the adapter in the default `~/.codex`. It automatically opens a new Terminal
   and launches a fresh Codex CLI. It also copies `/hooks` only as a recovery
   fallback.
3. When `Hooks need review` appears, select `Review hooks`. In the normal flow
   you do not paste `/hooks` and run it with `Return`. If Codex exceptionally opens
   at a regular prompt instead of the review screen, use the fallback already
   copied by the app: `⌘V` → `Return` opens `/hooks`.
4. Under `User config`, confirm that the command definitions for
   `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`,
   `SubagentStart`, and `SubagentStop` point to the same agent-meong forwarder
   and are enabled, then trust them. Leave every other handler unchanged. You
   may use `Trust all` when the app reports `0` other pending hooks. Otherwise,
   trust only these seven entries individually.
   agent-meong rechecks approval
   automatically and refreshes when needed as you open its menu bar popover.

Command-hook approval is Codex's one manual security step while the definition
remains unchanged. agent-meong never
writes or bypasses trust on your behalf. It handles installation, read-only
diagnostics, copying `/hooks`, and opening a fresh CLI. Codex App or CLI instances
that were already open should be reopened before you expect them to be observed,
but you do not need to quit everything before starting the review.

It is normal to see lifecycle events and command definitions rather than a
separate hook named `agent-meong`. agent-meong reads Codex's own status for all
seven handlers and reports `Approval needed` or the actual disabled event when
something is blocked. Codex skips new or changed definitions until you trust
them. See the [official Codex Hooks documentation](https://learn.chatgpt.com/docs/hooks)
for details.

<details>
<summary>Full criteria for the seven lifecycle commands</summary>

- Events: `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`,
  `SubagentStart`, `SubagentStop`, and `Stop`
- Type: `command` for all seven
- Command:

  ```text
  '/Users/<you>/Library/Application Support/AgentMeong/codex-hooks/<24-hex>/codex_hook_forwarder'
  ```

- Timeout: 2 seconds, not async

If anything differs, do not trust it; update the app and checkout. Other hooks
you installed may appear alongside these and must be reviewed separately.

</details>

agent-meong preserves the definitions and relative order of other hooks. However,
Codex hook trust keys currently include a hook's position within its event. Repairing
duplicate older agent-meong entries or removing agent-meong can shift a later entry,
so another user hook may need review again. Recheck the entire `User config` source
in `/hooks` after repair or disconnect.

### Setup complete and first activity

When `Codex · waiting for activity` appears after approval, connection setup is
complete. You may close the review Terminal; sending a separate request there
is optional. For an immediate test, send a harmless request such as `Reply only
with "connection check"` that does not ask Codex to modify files.

To use a Codex App or CLI that was already open before connection, fully quit
and reopen it first, then start a **new local task**. Regular ChatGPT
conversations and Codex cloud/web tasks are not shown.

After approval, agent-meong shows `Codex · waiting for activity` even before a
real event arrives, making it clear that hook setup is complete. When the first
event from new work arrives:

- the top-left chip changes to `Codex · just now`; and
- a moving main-agent dot appears in Meong Space.
- A short, one-time guide explains movement, the needs-attention ring, and the turn-end
  ripple after the first real event.

The app distinguishes hook readiness from confirmed event receipt. It shows
`waiting for activity` only after all seven handlers are enabled and trusted,
then shows a recent-event time and objects only after receiving a real event.

## Everyday use

- The menu bar dot bounces while agents are working.
- Left-click the icon to open Meong Space. Click outside it to close it.
- Concurrent local tasks appear as separate main and subagent objects.
- Each object's body color changes independently with its own current state. Meong
  Space shows every concurrent agent's current state at once. Size, nearby movement,
  birth, and absorption express family relationships.
- The menu bar body color and shape show the agent whose state changed most recently.
  Rapid changes from different agents are shown briefly in order.
  If attention or failure remains elsewhere, a ring or diamond stays visible independently
  of the recent-change body color.
- Less common shapes map directly to states: a segmented ring is `Uncertain`,
  an open arc is `Finished`, a double halo is `Completed`, a horizontal bar is
  `Cancelled`, and a diamond is `Failure reported`. Completed, cancelled, and
  failed appear only when Codex explicitly supplies that outcome.
- Select the `?` icon at the top right to review all three essential signals,
  the tool-activity dots, and every less-common state as icons. Use the `×`
  inside the guide or press `Escape` to return to the scene; clicking outside
  closes all of Meong Space.
- An observed tool start sends a filled dot outward; a finish draws a hollow dot
  inward. Two or three overlapping dots are closely spaced events, not a count
  of running tools. Their angle is decorative and does not identify a tool type.
  The app does not claim that a tool remains active or expose its payload.
- A blue menu bar signal appears when one top-level turn ends. This is a Codex
  turn-end observation, not a success verdict for the entire thread. If Meong Space is closed,
  up to four of the most recent distinct agent families leave individual receipts for the next
  opening. This is a recent-family count for the current app session, not the total number of
  unseen turns; receipts are not restored after the app restarts.
- Right-click the icon for status, `Open Meong Space`, `Help, update, and
  uninstall`, and `Quit`.
- To reopen the app, open `~/Applications/AgentMeong.app` in Finder or run:

  ```bash
  open "$HOME/Applications/AgentMeong.app"
  ```

### Reading color

Meong Space and the menu bar share one status palette. Color never stands alone;
every state also has a shape, motion cue, or VoiceOver description.

#### Per-agent state

Each object's body color and shape show that agent's own current state. The object
switches to the matching color and shape as soon as its state changes. Birth,
absorption, size, and nearby movement—not color—express parent-child relationships.

#### Menu bar icon

The single menu bar icon does not collapse every agent into one aggregate color. It
shows the color and shape of the agent whose state changed most recently, then plays
rapid transitions briefly in order. The icon can keep bouncing while its body shows
completed or failed: body color means the recent change, while bounce independently
means at least one agent is active. Open Meong Space to see all current states at once.

| Color | State | Paired shape |
| --- | --- | --- |
| Sky blue | Quiet | Stationary dot |
| Cyan | Active | Movement; a chevron with Reduce Motion |
| Orange | Needs attention | Ring |
| Gray-violet | Uncertain | Segmented ring |
| Pale blue | Ended; result unknown | Open arc |
| Purple | Completed; success explicitly reported | Double halo |
| Gray | Cancelled | Horizontal bar |
| Red | Failure reported | Diamond |

The blue outer ripple in the menu bar is a separate signal that one top-level agent
turn just ended; it does not mean the whole task succeeded. Select `?` in the
top-right of Meong Space to compare the actual swatches and shapes. A guide opened
by the user stays visible until you select its `×`, press `Escape`, select `?`
again, or click outside Meong Space.

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
exposes counts and shape cues for quiet, active, needs-attention, uncertain,
and finished states. Completed, cancelled, and failed appear only when an
observation source explicitly supplies that outcome. With Reduce Motion,
movement stops and a static chevron keeps the active state visible.

## Update

There are no automatic updates. Press `⌘ Space` to open Terminal, then copy
and paste this entire block. It downloads the new version into the original
source folder and reinstalls the app:

```bash
cd "$HOME/agent-meong"
git pull --ff-only
bash scripts/install-app
```

The update is complete when the final lines include one beginning with
`Installed agent-meong at` and the app reopens. Your connection and Launch at Login setting are
preserved. Only if the connection definition changed and you see `Repair
required` should you use the repair action and complete Codex's security review
again.

The installer builds and verifies the new app before quitting and replacing the
running version. If replacement fails, it restores the previous bundle and
reopens it when it was running. In the rare case that the new app refuses to
quit, the installer does not delete the live bundle; it prints the recoverable
previous-bundle path and exits with failure. It also preserves a valid
automatic-start item and a user-disabled state. If you see `Repair required`
after relaunch, use the repair action. agent-meong opens a fresh
Codex review when needed; reopen existing instances once before observing them.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| No menu bar icon | Run `open "$HOME/Applications/AgentMeong.app"`. If the app is running but the icon is hidden, free some menu bar space. If it still fails, inspect the Terminal error from `bash scripts/install-app`. |
| App did not open after login | Check whether `AgentMeong` is off under `System Settings > General > Login Items > App Background Activity`. `Item from unidentified developer` is an expected detail for the source build. |
| Codex has no `/hooks` | Update ChatGPT or Codex App, or install/update Codex CLI using the [official guide](https://developers.openai.com/codex/cli). |
| `Approval needed` | Select `Open Codex review`, then choose `Review hooks` on the `Hooks need review` screen and trust the seven agent-meong entries. If Codex exceptionally opens at a regular prompt, use the copied `/hooks` fallback with `⌘V` → `Return`. |
| `Hook disabled` | Re-enable and trust the lifecycle event named by agent-meong under `/hooks` > `User config`. |
| `Waiting for event` | An earlier connection is known, but this run has not sent activity yet. Fully quit and reopen Codex App or CLI instances left open before connection, then send a request in a new local task on this Mac. |
| `Check status` | agent-meong could not read the current Codex hook state. Check again shortly. |
| `Repair required` | Use the repair action. agent-meong handles `/hooks` and opening a fresh CLI when review is needed; other hook definitions and settings are preserved. |
| `Hooks off` | Check `[features] hooks = false` in the active Codex settings. Ask your administrator if policy enforces it. |
| `Policy restricted` | `allow_managed_hooks_only = true` in `requirements.toml` or managed policy is blocking user hooks and requires an administrator change. |
| `Check configuration` | Repair the JSON syntax in `hooks.json` for the current Codex home. agent-meong will not overwrite a malformed file. |
| A trailing `◇` | Hooks from `config.toml` and `hooks.json` are both loading. This is an advisory and does not replace the base connection state; review both sources in `/hooks`. |
| `Check format` | Align the app and checkout versions, then select `Repair connection`. |
| `destination path ... already exists` | If `$HOME/agent-meong` is an earlier download, use the [Update](#update) commands. If it contains something else, rename it in Finder and install again instead of deleting it blindly. |

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

Open the `Codex · …` status button at the top left of Meong Space and select
`Disconnect`. **Disconnecting does not remove the app: agent-meong and Launch
at Login remain enabled.** This removes only agent-meong's handlers and adapter
while preserving other Codex settings and hooks. On success it removes only the
objects and restart checkpoint, scene end receipts, and confirmation owned by
the default connection. State and records from custom `CODEX_HOME`
connections remain.
Fully quit and reopen Codex App and CLI afterward, then recheck trust for the
other user hooks in `/hooks`.

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
is removed, select `Forget separate history` once to clear
the aggregate local scene and confirmation record.

## Completely uninstall the app and data

`Quit` in the right-click menu only closes the app; it does not uninstall it.
To remove the app, Codex connection, Launch at Login item, and local data, keep
the original `$HOME/agent-meong` source folder and use the uninstaller below.

If you only used the default `~/.codex` and never connected a custom
`CODEX_HOME`, open Terminal and paste this entire block:

```bash
cd "$HOME/agent-meong"
bash scripts/uninstall-app
```

When you see `Uninstalled agent-meong and its default Codex connection.`, the
app and its data are gone. For safety, the source checkout is not deleted
automatically. As the final step, move the `agent-meong` folder in your home
folder to the Trash in Finder to remove the downloaded source too.

If you connected a custom `CODEX_HOME`, order matters. Deleting the support
directory while a custom hook remains would leave Codex invoking a missing
adapter path.

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

Frequent event delivery uses a lightweight native forwarder. The Python
adapter runs only for infrequent connection installation, repair, and status
diagnostics.

Connection diagnostics use Codex's local, read-only `hooks/list`; they do not
start an AI task or model call. The configured command, source path, and hash
for agent-meong entries are checked only in memory and are never stored, logged,
or sent. The UI retains only enabled/trust status, affected lifecycle names,
and the aggregate count of other hooks waiting for review. Names, commands, and
paths from those other hooks never cross into the app. Codex app-server state
and logs are isolated in a user-only temporary directory and deleted after the
query. agent-meong never opens or reads the user's Codex database directly.

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
