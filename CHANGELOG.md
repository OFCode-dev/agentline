# Changelog

## Unreleased

- Live agents on line 3 are no longer limited to Claude's own subagents. Any
  process can register itself through the new `hooks/agentline-agent.sh`
  (`add` / `remove <label>`), so an external agent CLI driven from a shell —
  `codex`, `agy`, a run on another host — is visible while it works instead of
  being waited on blind. `add` replaces a row carrying the same label rather
  than appending, which makes it usable as a heartbeat.
- The agent tracker no longer deletes the whole file on `Stop`. `Stop` fires at
  the end of every assistant turn, so a still-running external agent that had
  taken a row was wiped from the bar while it was still working. The hook now
  records what it registered in a per-session sidecar and removes only those
  labels; rows owned by another session or by an external process survive.
- Registry writes take an `flock` and prune by age before applying the size
  cap. The previous append-then-`tail -8` could interleave under parallel
  dispatch and could evict a running agent while a stale row survived.

- Weekly premium-model usage as an orange `F:` field inside the `W:` segment
  (`W:28% F:12% ↻29/8`). Read from `rate_limits.seven_day_overage_included`
  first — Claude Code's own label map calls that bucket the "Fable 5 limit" —
  with `rate_limits.seven_day_opus` as a fallback. Claude Code 2.1.x builds
  the status-line `rate_limits` object from four response-header buckets only
  (`five_hour`, `seven_day`, `seven_day_overage_included`, `overage`);
  `seven_day_opus` is not among them, so reading it alone never rendered on
  2.1.x. Non-numeric values are ignored rather than passed to `printf`.
- Opt-in `/usage` source for `F:`: on accounts whose responses carry no
  per-model header at all (verified on Max 5x — the payload holds only
  `five_hour` and `seven_day`), the Fable share exists only at
  `GET /api/oauth/usage` → `limits[]` → `kind: weekly_scoped`,
  `scope.model.display_name: Fable`. `AGENTLINE_USAGE_API=1` reads it from
  there, cached for `AGENTLINE_USAGE_TTL` seconds (default 300) in the
  owner-only cache directory. It is the only network request agentline can
  make, it is off by default, and every failure mode leaves `F:` hidden.

- Live clock: the `HH:MM:SS` segment on line 2 now ticks every second instead
  of freezing between conversation events. `install.sh` sets
  `statusLine.refreshInterval` to 1 in `settings.json` (an interval you already
  chose is left alone), and re-running the installer adds it to an existing
  install.
- Per-session render cache makes that affordable. The finished line is stored
  with the clock as a placeholder; a tick with an unchanged payload and a cache
  younger than `AGENTLINE_CACHE_TTL` (default 5 s) only stamps in the current
  time — no `python3`, no host probes, and no `date` at all on bash ≥ 5.0.
  Full render ≈ 0.5 s, cached tick ≈ 0 s. Any payload change invalidates the
  cache immediately, so no segment is ever shown stale across a state change.
- Host probes are throttled independently of the render cache, via a new
  `AGENTLINE_PROBE_TTL` (default 15 s). The render cache is invalidated by any
  payload change, which happens constantly during a turn, so on its own it
  still let `top -bn1`, `df`, `ss`, `crontab`, `who` and a `systemctl
  is-active` per unit run up to once a second — most of a render's cost, spent
  on numbers that barely move. CPU, RAM, disk, ports, services, MCP and git now
  survive those invalidations: a render that misses the render cache but hits
  the probe cache costs ~0.11 s instead of ~0.5 s. The cwd is part of the
  validity check, so changing directory re-probes git at once; the live
  subagent list is never throttled.
- New `AGENTLINE_CACHE_TTL` variable to trade render freshness against CPU.
- The render cache lives in a per-user `0700` directory
  (`${TMPDIR:-/tmp}/agentline-<euid>/`), created atomically with `mkdir -m 700`
  and re-verified on every render as a non-symlink directory owned by the
  current user. A predictable path directly in a shared `/tmp` would let a
  co-tenant pre-plant a symlink and redirect the write, and would leave the
  cached payload world-readable. If the directory cannot be trusted, caching
  is disabled rather than written unsafely — the bar still renders, it just
  stops taking the fast path.

- Fixed: dev-server port entries could render with a stray, unmatched `(`
  (e.g. `(v1(3002)`). Some processes report their kernel `comm` name already
  wrapped in parentheses (a real Linux convention, e.g. `(sd-pam)`), and the
  15-byte `comm` truncation can chop the trailing `)` off a longer one before
  it ever reaches `ss`. The formatter now strips any leading/trailing
  parens from the process name before wrapping it in its own `(port)`, so
  every entry matches the `name(port)` shape.

- `max` and ultracode (`xhigh` entered via the ultra-effort mode) now animate
  in the statusline instead of rendering one frozen gradient frame: each tick
  turns the word one step around a closed color wheel, through the same
  zero-fork clock-tick substitution as the `HH:MM:SS` segment — no `python3`,
  no subprocess, ~0.5 ms of bash arithmetic on a one-second tick.
  A terminal has no position between one cell and the next, so a step of less
  than a whole letter cannot read as movement — it only re-tints each letter
  where it stands, which the eye takes for flicker. A tick therefore advances
  the pattern exactly one letter: each letter inherits the colour its
  neighbour just had, and the eye reads the pattern as travelling. That also
  buys the saturation back, since a chase only permutes a fixed set of
  colours and the bar's total brightness is identical frame to frame — it was
  the re-tinting, not the vividness, that strobed. The rainbow is generated
  in OkLCh at lightness 0.70 with the most chroma each hue can hold there,
  and has 37 entries rather than 36 so three letters a third of the wheel
  apart come back one step short every three ticks, precessing a full turn
  every ~111 s instead of cycling the same three colours forever. ultracode
  keeps the picker's bold-white-on-violet treatment; violet as a foreground
  alone sits too close to a dark terminal ground to read as lit.

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

## 1.1.2 — 2026-08-19

- `max` effort now renders as a static rainbow with a 🌈 marker, mirroring the
  `/effort` picker's rainbow-animated styling — so the scale's true top level
  outranks the violet `xhigh` visually, matching low < medium < high < xhigh
  < max (ultracode is a side mode that reports as `xhigh`).

## 1.2.0 — 2026-08-19

- True ultracode detection: the payload reports ultracode as plain `xhigh`,
  so agentline now scans the session transcript's effort markers and renders
  a violet `ultracode` pill only when ultracode is really on; genuine xhigh
  stays red. The 🟣 and 🌈 marker emojis are gone — the pill and the rainbow
  speak for themselves.
- `transcript_path` extracted from the payload (with a session-id fallback);
  reverse file scan is BSD/macOS-portable (`tac` / `tail -r`).
