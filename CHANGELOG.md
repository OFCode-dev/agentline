# Changelog

## 1.0.0 — 2026-08-18

First public release.

- Four adaptive lines: session stats, environment, Claude layer, system layer.
- Lines 3 and 4 hide when empty and merge into one line when they fit.
- Single-pass payload parsing — one `python3` invocation extracts every field.
- Machine-local service health panel (`~/.claude/agentline-services.conf`),
  never tracked by git, migrated automatically from earlier installs.
- Optional hooks for the word counter (🔤) and live agent tracker (🤖),
  wired idempotently with `bash install.sh --with-hooks`.
- One source tree for macOS and Linux; platform probes resolved once at startup.
- `claude --resume <session-id>` recovery command always visible on line 3.
- Masked account e-mail with a 60-second auth cache, truecolor gradient for
  frontier models, adaptive color thresholds for context, rate limits, and disk.

## 1.1.0 — 2026-08-19

- Layer lines 3 and 4 now wrap onto continuation rows at segment boundaries
  when they outgrow the width budget, instead of overflowing the terminal.
- Word counter redesigned: `🔤 ↑typed ↓written`, placed between the token
  counters and the line counters.
- Day abbreviation on line 2 pinned to English regardless of host locale.

## 1.1.1 — 2026-08-19

- `xhigh` effort now renders as bold white on a violet gradient with a 🟣
  marker, mirroring the styling of the `/effort` picker's top setting.
