# agent-meong

[한국어](README.md) | English

<p align="center">
  <img src="docs/images/agent-meong-mark.svg" width="180" alt="agent-meong app icon">
</p>

> Less fire-gazing. More agent-gazing.

`agent-meong` is a macOS app that turns the activity of running AI agents into motion.

Delegate a few tasks, take a break, and quietly watch the work continue and wind down.

## What you will see

You only need to know three signals.

- **Movement**: an agent is active.
- **Ring**: the agent needs your attention.
- **Outward ripple**: one top-level agent turn ended. This does not mean the whole task succeeded.

Everything else follows a few simple rules.

- When a main agent is working, the menu bar icon **bounces**.
- A subagent is born from its main agent and returns to be absorbed when its end is observed.
- As activity and objects disappear, you can feel the work winding down.

See [Reading color](#reading-color) for every menu bar color and shape.

agent-meong is not a log viewer or productivity dashboard. It does not store or send prompts,
responses, commands, file paths, or tool input/output to the app. It shows only a small set of
activity signals instead of the content of your work.

## Installation

agent-meong currently supports only OpenAI Codex running on this Mac. It observes Codex App,
Codex inside the ChatGPT desktop app, and Codex CLI. Regular ChatGPT conversations and Codex
cloud or web tasks are not shown.

Installation is available only from GitHub source. You need:

- macOS 14 or later;
- Xcode Command Line Tools, Swift 6, and `/usr/bin/python3`; and
- a current local Codex version that supports `/hooks`.

Codex App and CLI instances that share the default `~/.codex` need only one connection.

### How to install

Paste the following into an AI agent such as Codex.

```text
Read the README below and install agent-meong on this Mac.
Do what is needed to install and connect it, but pause at the Codex hook
trust step so I can review it myself.
https://raw.githubusercontent.com/dkstm95/agent-meong/refs/heads/main/README.en.md
```

## Connect Codex

1. Select `Connect` in agent-meong when it opens from the menu bar.
2. In the new Codex Terminal, select `Review hooks` when `Hooks need review` appears.
3. Under `User config`, confirm that these seven lifecycle events point to the same
   agent-meong command, then trust them.

   ```text
   UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse,
   Stop, SubagentStart, SubagentStop
   ```

4. Use `Trust all` only when the app confirms that no other hooks are waiting for review.
   Otherwise, trust only the seven agent-meong events.
5. `Codex · waiting for activity` in the menu bar means the connection is ready.

Codex hook trust is a security step that you must complete yourself. agent-meong never writes
or bypasses trust on your behalf. Fully quit and reopen any Codex App or CLI that was already
open before connection.

## Using agent-meong

- Select the menu bar icon to open Meong Space.
- Meong Space shows the current state of every agent together.
- Select `?` at the top right to review motion and state shapes.
- Turn automatic launch on or off under `System Settings > General > Login Items`.
- To reopen the app, launch `~/Applications/AgentMeong.app` from Finder.

### Reading color

Each object's body color distinguishes the agent and stays stable while it is on screen. Movement
and shapes around the body show state. The menu bar icon shows the most recently changed state in
color and shape. Its bounce is a separate signal that at least one agent is active.

| Menu bar color | State | Meong Space shape |
| --- | --- | --- |
| Sky blue | Quiet | Dot |
| Cyan | Active | Movement |
| Orange | Needs attention | Ring |
| Gray-violet | Uncertain | Segmented ring |
| Pale blue | Ended, result unknown | Open arc |
| Purple | Completed | Double halo |
| Gray | Cancelled | Horizontal bar |
| Red | Failure needs attention | Diamond |

Body color is not an agent name or unique identifier. Completed, cancelled, and failed appear only
when Codex explicitly reports the outcome. The blue
outer ripple means that one top-level agent turn ended; it is not a success signal. Shapes and
VoiceOver provide the same state when color is hard to distinguish. With Reduce Motion, a chevron
replaces active movement.

## Privacy

The Codex hook receives the original event, but it does not store or send prompts, responses,
commands, file paths, or tool input/output. Only the following data crosses a user-only local socket:

- session, turn, and agent IDs transformed so the original values cannot be recovered;
- lifecycle events and broad tool categories; and
- termination states explicitly reported by Codex.

See [Product principles](docs/product-principles.md) and the
[observation schema](protocol/event-v0.schema.json) for the full boundary.

## Update

There are no automatic updates. Run these commands from the original source folder:

```bash
cd "$HOME/agent-meong"
git pull --ff-only
bash scripts/install-app
```

Your connection and automatic-launch setting are preserved.

## Disconnect and uninstall

To disconnect only Codex, open the `Codex · …` status button in Meong Space and select
`Disconnect`. The app and its automatic-launch setting remain installed.

To remove the app, default Codex connection, automatic-launch item, and local data, run:

```bash
cd "$HOME/agent-meong"
bash scripts/uninstall-app
```

The source folder is never deleted automatically. After uninstalling, move
`$HOME/agent-meong` to the Trash in Finder if you no longer need it.

<details>
<summary>If you use a custom CODEX_HOME</summary>

Before uninstalling the app, remove the hook from every connected environment:

```bash
cd "$HOME/agent-meong"
CODEX_HOME="/absolute/path/to/codex-home" bash scripts/uninstall-codex-hook
```

To connect a custom `CODEX_HOME`, run `bash scripts/install-codex-hook` from that same
environment. Fully quit and reopen the affected Codex instance after connecting or disconnecting.

</details>

## Troubleshooting

| What you see | What to check |
| --- | --- |
| No menu bar icon | Run `open "$HOME/Applications/AgentMeong.app"` and make sure the menu bar has enough space. |
| Codex has no `/hooks` | Update Codex App or CLI to the latest version. |
| `Approval needed` or `Hook disabled` | Select `Open Codex review`, then enable and trust the event named by the app. |
| `Waiting for event` | Fully quit and reopen Codex instances left open before connection, then start a new local task. |
| `Repair required` | Use the repair action and review the required hooks again. |
| `destination path ... already exists` | Use [Update](#update) for an existing checkout. Rename any unrelated folder instead of deleting it. |

If the problem continues, open a [GitHub Issue](https://github.com/dkstm95/agent-meong/issues)
with the visible status and source revision. Do not attach prompts, responses, commands, file paths,
or tool payloads.

## Development and contribution

- [Contributing guide](CONTRIBUTING.md)
- [Product principles](docs/product-principles.md)
- Full checks: `bash scripts/check`

## License

[MIT License](LICENSE)
