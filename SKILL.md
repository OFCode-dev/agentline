---
name: agentline
description: Install and configure agentline, a zero-dependency four-line status bar for Claude Code showing session cost, context usage, rate limits, git branch, MCP servers, live subagents, and host health. Use when the user asks to set up, install, update, customize, or troubleshoot a Claude Code statusline.
---

# agentline — four-line status bar for Claude Code

agentline is a single bash script (no npm, no daemon, no network calls) that renders up to four adaptive statusline rows: session stats, environment, Claude layer, and system layer. Full reference: https://github.com/OFCode-dev/agentline — read `README.md` for the per-segment documentation.

## Install

```bash
git clone https://github.com/OFCode-dev/agentline.git
cd agentline
bash install.sh
```

Then restart Claude Code. `install.sh` copies the script to `~/.claude/agentline/agentline.sh`, points `statusLine` in `~/.claude/settings.json` at it, and seeds the machine-local service list. It is safe to re-run and upgrades in place.

- If `settings.json` already has a `statusLine` command, the installer upgrades that script in place instead of replacing the path — never silently discard a user's existing statusline; ask before switching if they have a different one configured.
- Requirements: Claude Code ≥ 2.x, `bash`, `python3`, `git`, `awk`, `top` (standard on macOS and Linux).

## Optional hooks

Two segments need small hooks (word counter `🔤`, live agent tracker `🤖`):

```bash
bash install.sh --with-hooks
```

This wires hook entries into `settings.json` idempotently — existing hooks are never duplicated or removed. Skip it unless the user wants those two segments.

## Configure

Set variables in the `env` block of `~/.claude/settings.json`:

| Variable | Default | Effect |
|---|---|---|
| `AGENTLINE_SERVICES` | `~/.claude/agentline-services.conf` | Path to the service list |
| `AGENTLINE_WIDTH` | `120` | Column budget for merging/wrapping lines 3+4 — set near the user's real terminal width |
| `AGENTLINE_TZ` | system timezone | Pin the clock, e.g. `Europe/Istanbul` on a UTC server |

Service panel (line 4): edit `~/.claude/agentline-services.conf`, one `systemd-unit:Label` per line. Discover candidates with `systemctl list-units --type=service --state=running` and let the user choose which units to monitor — prefer their own services over distro plumbing. The file is machine-local and gitignored by design.

## Verify

```bash
echo '{"model":{"id":"claude-fable-5"},"cwd":"'$HOME'","context_window":{"used_percentage":42}}' \
  | bash ~/.claude/agentline/agentline.sh
```

Expect a gradient `✦ Fable 5`, a green `📊 42%`, and no errors. Segments that cannot be measured disappear silently — that is by design, not a fault.

## Update

```bash
cd agentline && git pull && bash install.sh
```

## Uninstall

Remove the `statusLine` entry from `~/.claude/settings.json` and delete `~/.claude/agentline/` (plus `~/.claude/agentline-services.conf` if unwanted).
