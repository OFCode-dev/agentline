#!/bin/bash
# agentline optional hook: counts words in assistant output and user input.
# Feeds the 🔤 word-counter segment (↑ typed, ↓ written) on agentline's line 1.
#
# Claude Code hook payloads do not inline the transcript; they point at it via
# transcript_path (a JSONL file). This reads that file and counts the words in
# text blocks only, so tool results and system entries are not inflated into
# the totals. Called by PostToolUse and Stop hooks via stdin JSON. Wire it up
# with `bash install.sh --with-hooks` (see README).

# Same directory agentline.sh reads from, by the same rule: $AGENTLINE_TMP,
# else one private to the user — $XDG_RUNTIME_DIR/agentline when that is a
# real directory of ours, else ${TMPDIR:-/tmp}/agentline-$EUID — created
# 0700 and written only when it is a directory we own, not a symlink. It
# used to be /tmp, readable by everyone on the host. The file is 0600
# (umask 077), and the one the previous release left in /tmp goes.
umask 077
legacy=""
if [ -n "${AGENTLINE_TMP-}" ]; then
  WCDIR="$AGENTLINE_TMP"
else
  if [ -n "${XDG_RUNTIME_DIR-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ ! -L "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
    WCDIR="$XDG_RUNTIME_DIR/agentline"
  else
    WCDIR="${TMPDIR:-/tmp}/agentline-${EUID:-0}"
  fi
  [ -d "$WCDIR" ] || mkdir -m 700 "$WCDIR" 2>/dev/null
  { [ -d "$WCDIR" ] && [ ! -L "$WCDIR" ] && [ -O "$WCDIR" ]; } || exit 0
  legacy="${_AGENTLINE_LEGACY_TMP:-/tmp}/claude_wordcount.txt"
fi
WCFILE="$WCDIR/claude_wordcount.txt"

input=$(cat)
# Read into a variable and run with -c rather than written as a heredoc
# inside $(...): bash 3.2 (macOS /bin/bash) parses such a nested heredoc as
# shell text, so one apostrophe in the python would be a syntax error.
IFS= read -r -d '' _WC_PY <<'PYEOF'
import json, os
try:
    d = json.loads(os.environ.get('PAYLOAD', '') or '{}')
    path = d.get('transcript_path', '')
    words_in = words_out = 0
    if path and os.path.isfile(path):
        with open(path, encoding='utf-8') as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                role = entry.get('type')
                if role not in ('user', 'assistant'):
                    continue
                content = (entry.get('message') or {}).get('content', '')
                if isinstance(content, list):
                    text = ' '.join(b.get('text', '') for b in content
                                    if isinstance(b, dict) and b.get('type') == 'text')
                else:
                    text = str(content)
                if role == 'user':
                    words_in += len(text.split())
                else:
                    words_out += len(text.split())
    print(f'{words_in} {words_out}')
except Exception:
    print('0 0')
PYEOF
# -I (isolated): the hook runs in the project directory, and plain `python3 -c`
# would import a json.py or os.py sitting there instead of the standard one.
counts=$(PAYLOAD="$input" python3 -I -c "$_WC_PY")

# Write totals (overwrite each time — reflects the full session transcript)
echo "${counts:-0 0}" > "$WCFILE"
# A file an earlier release wrote at 0644 keeps its mode through `>`.
chmod 600 "$WCFILE" 2>/dev/null
if [ -n "$legacy" ] && [ -f "$legacy" ] && [ ! -L "$legacy" ] && [ -O "$legacy" ]; then
  rm -f "$legacy"
fi
