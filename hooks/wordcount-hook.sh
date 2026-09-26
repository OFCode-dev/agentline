#!/bin/bash
# agentline optional hook: counts words in assistant output and user input.
# Feeds the 🔤 word-counter segment (↑ typed, ↓ written) on agentline's line 1.
#
# Claude Code hook payloads do not inline the transcript; they point at it via
# transcript_path (a JSONL file). This reads that file and counts the words in
# text blocks only, so tool results and system entries are not inflated into
# the totals. Called by PostToolUse and Stop hooks via stdin JSON. Wire it up
# with `bash install.sh --with-hooks` (see README).

# Same directory agentline.sh reads from: /tmp unless $AGENTLINE_TMP is set.
WCFILE="${AGENTLINE_TMP:-/tmp}/claude_wordcount.txt"

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
counts=$(PAYLOAD="$input" python3 -c "$_WC_PY")

# Write totals (overwrite each time — reflects the full session transcript)
echo "${counts:-0 0}" > "$WCFILE"
