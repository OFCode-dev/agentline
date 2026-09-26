# Changelog

## Unreleased

- A render that misses the render cache starts two `python3` instead of
  three, or four for a Fable/Mythos model. That is the render an active turn
  pays about once a second, and each `python3` start costs ~20 ms of CPU.
  The e-mail mask is now bash parameter expansion. It walks the same greedy
  match as the regex it replaces, and non-ASCII addresses still go to
  `python3`. The Fable gradient is painted by the layout pass, which runs on
  every full render anyway. The output is byte for byte what it was.
- One string now chooses the layout. `AGENTLINE_LAYOUT` lists segment
  names: `/` starts a line, `,` separates names, and a name left out is
  hidden. The default reproduces the four lines exactly. Before, the only
  way to hide or move a segment was to edit `agentline.sh`, which the next
  install overwrote.
- The status line follows the real terminal width. Claude Code ≥ 2.1.153
  passes it as `COLUMNS`, and agentline used a fixed 120 and never measured
  lines 1 and 2. Line 1 alone can carry 15 segments and ran off narrow
  terminals. Now, with `COLUMNS` known, a line that does not fit (less a
  2-cell resize margin) sheds segments in `AGENTLINE_DROP` order: tokens,
  word counts, duration, date, version, e-mail, lines changed. Whatever still
  does not fit wraps at `│` boundaries. Model, context and both rate limits
  are never dropped. Without `COLUMNS` nothing is dropped on a guessed width.
  `AGENTLINE_WIDTH` still wins when set. The width and layout settings are
  part of the render-cache key, so a resize shows on the next tick instead
  of after the cache TTL.

- Runs under bash 3.2 again (the macOS `/bin/bash`). bash 3.2 parses a
  heredoc body inside `$(…)` as shell text, so one apostrophe in a comment
  of the embedded Python parser opened a quote. Every full render then
  failed with a syntax error and printed nothing. Every embedded Python
  program, in `agentline.sh` and the word-count hook, is now read into a
  variable at top level and run with `python3 -c`. The test suite rejects
  an unbalanced apostrophe in any heredoc left inside `$(…)`.
- The host-probe cache can no longer run code from the payload. It stored
  the cwd raw on its own line, and its body is `eval`'d. A payload cwd of
  `/tmp/x` + newline + `active_mcps=$(cmd)` wrote an extra line, and the
  next render in `/tmp/x` within the probe TTL ran `cmd`. The cwd is now
  stored and compared `printf %q`-quoted. The body is only evaluated when it
  is exactly one `name=` line per probe variable, in the order agentline
  writes them.

- Displayed text can no longer inject terminal escapes. The final output
  goes through `printf %b`, so a branch, remote, directory, session name,
  model name, MCP server, process name, agent label or e-mail containing
  `\033]0;…`, `\e[…`, or a raw ESC/BEL byte was turned into a real escape
  sequence. That could retitle the window, clear the screen or forge part of
  the line. Every payload- and host-derived string is now stripped of
  control characters (C0, DEL, C1) and backslashes before it is displayed.
  Payload strings are cleaned in the parser, host strings with fork-free
  parameter expansion. The text itself still shows, cleaned. Paths used for
  lookups (cwd, session id, transcript) stay raw. UTF-8 encoded C1 controls
  (U+009B CSI is the bytes `C2 9B`) are stripped byte by byte as well. Under
  a C/POSIX locale or an unset `LANG` (common on servers) bash's
  `[[:cntrl:]]` does not match them, yet git allows them in a branch name
  and xterm-class terminals act on them. Other text is untouched: Turkish
  letters, emoji and `©` survive in every locale. Lone surrogates in the
  payload are dropped too. A `"session_name":"\ud800"` used to crash the
  parser's output, so the model and context segments vanished and a
  traceback went to stderr. `"\udc9b"` came out as a raw `0x9B`, the 8-bit
  CSI. The parser now writes its own UTF-8.
- Numeric fields accept ASCII digits only and stay within sane bounds.
  `"٣٠"` (Arabic-Indic 30) passed the old `\d` check and reached `printf`,
  which printed "invalid number" and a red `⚠️ 0%`. An integer past a
  double raised inside the parser and blanked the whole line 1. A window
  size past 64 bits broke bash's `[ -gt ]`. Such values, and anything from
  1e15 up, now hide their segment. The 200k-warning decision is made in the
  parser, which compares any size.
- A session name (or any displayed string) can no longer forge the clock or
  effort-animation placeholders. `@@AGENTLINE_CLOCK@@` in a session name
  used to be replaced by the live clock. The placeholders now contain a
  control byte, and no cleaned string can contain one.
- Cache file names carry a format version (`render_<sid>.v2.*`). The first
  renders after an upgrade therefore never replay a body the previous
  release cached, which would print an old placeholder literally or
  uncleaned service labels for a few seconds. Old files are left to the
  daily prune.
- Payload robustness and a truthful context warning. A payload that does not
  decode, or decodes to something other than an object, used to become `{}`:
  the model and context segments vanished with no hint why. It now shows a
  dim `⚠ payload` first on line 1, and the host segments still render.
  `model` is read both as an object and as a bare id string, because the
  shape has flipped between Claude Code versions and crashed other status
  lines. Before, a string model dropped the name without notice. Numeric fields that
  are not numbers are dropped instead of reaching awk and `printf` (stray
  stderr and a false `0%`). On a window larger than 200k, the payload's
  `exceeds_200k_tokens` now forces a yellow `⚠️ … >200k` even at a low
  percentage. A 1M model at 25 % is already past the long-context mark. A
  compact-relative percentage was considered and left out, because the
  payload exposes no auto-compact threshold.
- A test suite and CI. `bash tests/run.sh` (bash + python3, no bats) runs
  the real script over a fixture set — full, minimal, `{}`, malformed and
  empty input, a null post-compact window, a 1M model, Fable + max, xhigh vs
  ultracode, hostile values — at widths 120/80/40 against ANSI-stripped
  golden files, and requires exit 0, empty stderr and wraps only at `│`.
  It also proves cached ticks come from the render cache, counts fast-path
  forks with strace where available, and runs `install.sh` end to end
  against fixture homes. Host probes are seeded through the probe cache, so
  runs are hermetic. GitHub Actions runs it on Ubuntu (bash 5, shellcheck
  at error level) and on macOS under the system bash 3.2.
- The hook side files follow `AGENTLINE_TMP`. `claude_wordcount.txt` and
  `claude_agents.txt` were hard-coded under `/tmp`, ignoring `TMPDIR` and
  `HOME`, so two users on one host shared one counter and no test could run
  without reading the host's real files. agentline and both hooks now resolve
  `${AGENTLINE_TMP:-/tmp}`, so the default is unchanged. The reader also
  honours `CLAUDE_AGENTS_FILE`, which the registry helper already accepted:
  a relocated registry used to leave the 🤖 segment empty.

- Caches are scoped to the account. Claude Code keeps one account per
  config directory, but the `/usage` cache was a single `usage.fable` and the
  fetch always read `~/.claude/.credentials.json`, so a `CLAUDE_CONFIG_DIR`
  profile showed the default account's `F:` share. The credentials path and
  both caches now follow `CLAUDE_CONFIG_DIR`, keyed by the directory path
  (`usage.<key>`, `email.<key>`, built with parameter expansion, no fork).
- The unmasked account e-mail no longer sits in `/tmp`. Its cache was
  `$TMPDIR/agentline-email-<uid>`: outside the owner-only directory, mode
  664 and shared by every profile. It now lives in the 0700 cache
  directory, per account, and the old file is deleted on sight. The script
  also runs under `umask 077`, so every cache file is 600. When the cache
  directory fails its trust check, the `claude auth status` fallback is
  skipped, because it would otherwise be a CLI cold start every second.
- One `/usage` request per expiry, not one per session. The render that
  finds the cache expired touches it before fetching, so every other
  session serves the previous value in the meantime. No lock is involved,
  so none can be left stuck. The request timeout drops from 10 s to 3 s
  because it runs inside a render. A failed fetch still caches empty,
  hiding `F:` for one TTL rather than showing an unconfirmed number.
- The agent registry is locked on macOS too, by a lock no dead writer can
  wedge. macOS has no `flock(1)`, and the unguarded call there let every
  write run unlocked. Each write is now one short `python3` run that holds
  `flock(2)` on `claude_agents.txt.lock` (the file the old `flock(1)` used,
  so the two exclude each other) for the whole read-modify-write. The kernel
  releases the lock with its holder, so there is no stale lock to break. A
  `mkdir` lock tried in between lost rows under a 12-writer stress run and
  could wedge the registry. A lock still held after 5 s skips the write with
  a note on stderr instead of racing. A lock that cannot be opened (an
  unwritable directory, a full disk, another user's file in a sticky `/tmp`)
  skips at once instead of waiting out the 5 s, and so does a missing
  `python3`. Leftover `.d` / `.d.stale.*` directories older than a minute
  are removed on the next write.
- The `/usage` refresh survives the render being cancelled. Claude Code
  cancels an in-flight status-line script whenever the next update is due
  (every second with `refreshInterval: 1`), and a full render plus a fetch
  often ran past that. The fetch claimed the refresh by touching the cache
  itself, so a cancelled render left a fresh mtime on stale or empty content
  for a whole TTL. The claim is now a separate `.claim` file holding its
  epoch, which ages out after 30 s, and the fetch runs as a detached python
  in its own session that renames its result into place, so the render
  neither waits for it nor can take it down. The old figure stays up at most
  a minute past its TTL while the refresh is in flight. The claim is dropped
  only after the result has been renamed into place. If the cache cannot be
  written (a full disk), retries are held to one every 30 s instead of one
  per render, and a claim that cannot be written starts no fetch at all.
- Cache file modes are repaired. `umask 077` only covers new files: a
  cache file an older release left at 644 stayed 644 through every `>`
  rewrite. The daily sweep now sets surviving files to 600 and the
  directory to 700.
- The cache directory is pruned. Every session left `render_<sid>.*` files
  behind forever; once a day, files untouched for 7 days are deleted. The
  daily gate is read with a builtin, so the other renders pay nothing.

- `install.sh` no longer wipes a `settings.json` it cannot parse. Any JSON
  error used to become an empty object that the next save wrote back, so one
  trailing comma cost every permission, hook and `env` entry. It now stops
  with `✗ … is not valid JSON (line N)` before touching anything. Each run
  that does edit the file first copies it to
  `settings.json.agentline-bak-<timestamp>` (newest 5 kept), then writes to a
  temp file and renames it into place, through a symlink if there is one.
- The installer no longer takes over other status lines. It used to match
  `"statusline"` anywhere in the command, so `npx -y ccstatusline@latest` or a
  user's `my-statusline.sh` was silently repointed. A `custom.sh` was worse:
  it was treated as the install target and overwritten by `cp`. Only
  `agentline.sh` is upgraded in place now, and only the pre-rename
  `statusline-command.sh` / `statusline.sh` are migrated. Anything else is
  left alone, with the snippet to paste printed instead; `--force` switches
  anyway. The hook repoint follows the same rule: a hook is repointed only
  when it sits in the old `statusline/` directory or no longer exists.
- The installer no longer takes over `~/.claude/statusline.sh` or
  `~/.claude/statusline-command.sh`. Those pre-rename names are also the docs
  example and what Claude Code's own `/statusline` setup writes, and the name
  alone was enough to repoint them. A pre-rename script is now migrated only
  on positive proof: its first 64 KB carry agentline's header line or the
  pre-rename `statusline-services.conf`, or the command is one absolute path
  that does not exist. A directory rule (`*/statusline/statusline.sh`) would
  have taken over rz1989s/claude-code-statusline, which installs exactly
  there. The bare word "agentline" would have matched a user's wrapper that
  pipes agentline through `sed`. A "missing" compound command
  (`bash -c "source ~/.profile; ~/.claude/statusline.sh"`) or an unexpanded
  `$XDG_CONFIG_HOME/…` path is not proof either. The marker check reads
  regular files only and never opens a FIFO. A compound command such as
  `bash -c "… exec ~/…/agentline.sh"` is no longer mistaken for a path (the
  whole string used to become the install target, created under the cwd): an
  install path is trusted only when it is absolute and names an existing file.
  agentline run through such a wrapper is reported as "behind a wrapper — left
  as-is", its copy is upgraded in place, and the install exits 0 instead of
  claiming it is not active and pointing at a `--force` that would drop the
  wrapper's environment. `--with-hooks` on a `settings.json` whose `hooks`
  is not an object is refused before anything is copied or written.
- A foreign status line no longer reports success. The installer used to say
  "Done" and wire `--with-hooks` for a status line that was not agentline. It
  now says agentline is installed but NOT active, skips the hooks, and exits
  with status 3.
- `settings.json` bind-mounted on its own (devcontainers) is written in place.
  The atomic rename fails there with `EBUSY` and printed a traceback; after
  the backup, the installer now falls back to rewriting the file. Backup
  stamps are UTC, so name order is age order across a DST change.
- Local tweaks survive upgrades. `~/.claude/agentline/local.sh`
  (`AGENTLINE_LOCAL`) is sourced on every full render, after the colours and
  before the lines are assembled, and the installer never writes it. It costs
  nothing on cached ticks. An installed `agentline.sh` that differs from the
  new one is kept as `agentline.sh.bak-<timestamp>` rather than overwritten.

- Dim text is readable on light terminal themes. `DIM` was `2;37` — faint
  *white* — so every dim value (service health, `ssh:`/`cron:`, dev ports, date,
  version, resume command, reset times) all but disappeared on a light
  background. It is now plain faint (`2`), which dims whatever foreground the
  theme uses.

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
