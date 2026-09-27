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

- If `settings.json` already runs an `agentline.sh`, the installer upgrades that script in place, also when it runs through a wrapper (`bash -c "… exec …/agentline.sh"`, a pipe through `sed`). It prints "agentline behind a wrapper — left as-is" and exits `0`. Do not `--force` that, because it would drop the wrapper and the env it sets. A pre-rename `statusline.sh` / `statusline-command.sh` is migrated only when the file carries agentline's header or reads `statusline-services.conf`, or when the command is one absolute path that no longer exists. A status line that is anything else is left untouched, the installer prints the snippet to paste, skips `--with-hooks`, and exits `3` (installed but NOT active) — treat that as "not done yet", not as success. Ask the user before re-running with `bash install.sh --force` to switch.
- If `settings.json` is not valid JSON, the installer stops with the line number and changes nothing. Fix the file, then re-run. Every edit is preceded by a backup `settings.json.agentline-bak-<timestamp>` (newest 5 kept).
- To customize, put overrides in `~/.claude/agentline/local.sh` (sourced before the lines are assembled; `install.sh` never touches it). Do not edit the installed `agentline.sh`: upgrades replace it, keeping the previous copy as `agentline.sh.bak-<timestamp>`.
- Requirements: Claude Code ≥ 2.x, `bash`, `python3`, `git`, `awk`, `top` (standard on macOS and Linux).

## Optional hooks

Two segments need small hooks (word counter `🔤`, live agent tracker `🤖`):

```bash
bash install.sh --with-hooks
```

This wires hook entries into `settings.json` idempotently — existing hooks are never duplicated or removed. The agent tracker is registered for PreToolUse (`Agent|Task`), SubagentStart, SubagentStop and Stop. Re-running it on an older install adds the two subagent events. Skip it unless the user wants those two segments. `AGENTLINE_AGENT_SHOW` (default 4) caps how many running agents `🤖` lists before it counts the rest as `+N`.

## Configure

Set variables in the `env` block of `~/.claude/settings.json`:

| Variable | Default | Effect |
|---|---|---|
| `AGENTLINE_SERVICES` | `~/.claude/agentline-services.conf` | Path to the service list |
| `AGENTLINE_LAYOUT` | the four default lines | Segment order and grouping: `/` starts a line, `,` separates names, an omitted name is hidden (names listed in the README's "Layout and narrow terminals"). Use this rather than editing `agentline.sh`, which an upgrade replaces |
| `AGENTLINE_DROP` | `tok_in,tok_out,words,compact,dur,date,version,email,lines,cpu,mem,disk,cache` | Segments dropped first, in order, from a line too wide for the terminal; `model`, `ctx`, `5h`, `week` never drop, nor a segment in warning state (disk ≥ 80 %, cold/expiring cache, failed service). Empty = wrap only |
| `AGENTLINE_PACE` | `1` | `0` hides the `⇡`/`⇣` pace arrows after `S:`/`W:` |
| `AGENTLINE_THEME` | `dark` | `light` darkens the fixed colours (Fable gradient, gold/orange, `max` rainbow) for a light background; `mono` = no colour (also any non-empty `NO_COLOR`). Ask the user which background they use rather than guessing; `bash install.sh --theme light` writes it |
| `AGENTLINE_GLYPHS` | `emoji` | `ascii` = nothing above U+007F, for fonts without emoji; `bash install.sh --glyphs ascii` writes it |
| `AGENTLINE_COLOR_GOLD` / `_ORANGE` / `_FABLE_FROM` / `_FABLE_TO` | unset | `r,g,b` overrides for those fixed colours |
| `AGENTLINE_CACHE_WARN` | `60` (5m TTL), `300` (1h) | Seconds before a warm prompt cache expires at which the `🗄️ ↻` countdown appears |
| `AGENTLINE_CACHE_VERBOSE` | unset | `1` always shows the prompt-cache hit ratio |
| `AGENTLINE_GIT_STATUS` | `1` | `0` drops the git ahead/behind and dirty counts (no `git status` call) |
| `AGENTLINE_GIT_UNTRACKED` | `1` | `0` skips the untracked scan (`-uno`) on large repos |
| `AGENTLINE_LINKS` | `1` | `0` turns off the OSC-8 links on the PR number and `owner/repo` (always off under tmux/screen/zellij) |
| `AGENTLINE_WIDTH` | `COLUMNS`−2, else `120` | Column budget; overrides the live width Claude Code ≥ 2.1.153 passes as `COLUMNS`. Normally leave unset |
| `AGENTLINE_TZ` | system timezone | Pin the clock, e.g. `Europe/Istanbul` on a UTC server |
| `AGENTLINE_USAGE_API` | unset | Set to `1` to fetch the Fable weekly share (`F:`) from `/api/oauth/usage` when the payload has no per-model bucket — the only network call agentline can make, opt-in only. Reads `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude`) and caches per profile; does nothing on macOS, where the token is in the Keychain |
| `AGENTLINE_USAGE_TTL` | `300` | Seconds a fetched `/usage` result is reused |

Service panel (line 4): edit `~/.claude/agentline-services.conf`, one `systemd-unit:Label` per line. Discover candidates with `systemctl list-units --type=service --state=running` and let the user choose which units to monitor — prefer their own services over distro plumbing. The file is machine-local and gitignored by design.

## Verify

```bash
echo '{"model":{"id":"claude-fable-5"},"cwd":"'$HOME'","context_window":{"used_percentage":42}}' \
  | bash ~/.claude/agentline/agentline.sh
```

Expect a gradient `✦ Fable 5`, a green `📊 42%`, and no errors. Segments that cannot be measured disappear silently — that is by design, not a fault.

## Troubleshoot

When a segment is missing or the line is slow, run the doctor before reading the script:

```bash
bash ~/.claude/agentline/agentline.sh --doctor            # from a terminal: built-in sample payload
echo '{}' | bash ~/.claude/agentline/agentline.sh --doctor # or pipe the payload in question
```

It lists every segment as shown or hidden, with its data source ("absent: …" = the payload lacked the field; "probe" = the host command returned nothing). It also gives per-phase render times, the cache directory's trust state, and which hook events `settings.json` wires. A hook event reported `NO` is fixed by re-running `bash install.sh --with-hooks`. It writes no cache, so it is safe to run at any time.

## Update

```bash
cd agentline && git pull && bash install.sh
```

## Uninstall

Remove the `statusLine` entry from `~/.claude/settings.json` and delete `~/.claude/agentline/` (plus `~/.claude/agentline-services.conf` if unwanted).
