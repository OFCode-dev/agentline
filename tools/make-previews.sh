#!/bin/bash
# Regenerates the pictures in docs/ from the test suite's own fixtures.
#
#   bash tools/make-previews.sh
#
# No real session is ever photographed. `tests/run.sh --preview` renders
# tests/fixtures inside the hermetic harness — a pinned clock, invented
# numbers, a fake project dir, an already-masked account — and writes raw
# ANSI; tools/mksvg.py turns each file into an SVG with the terminal-window
# look. So a picture in docs/ cannot leak a path, a repo, an account, a
# session id or a service name: none of those reach the renderer.
#
# Review `git diff --stat docs/` before committing: the clock and the date in
# every picture move with the day it was generated.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSI="$(mktemp -d)"
trap 'rm -rf "$ANSI"' EXIT

bash "$ROOT/tests/run.sh" --preview "$ANSI" >/dev/null

# <ansi name> <svg name> <columns> <window title>
svg() {
  python3 "$ROOT/tools/mksvg.py" "$ANSI/$1.ansi" "$ROOT/docs/$2.svg" "$3" "$4" \
    "agentline $5 rendered in a terminal window" >/dev/null
  printf '  docs/%-24s %s\n' "$2.svg" "$(wc -c < "$ROOT/docs/$2.svg" | tr -d ' ') bytes"
}

# docs/preview.svg, the README's hero, is deliberately not in this list: it is
# a picked moment and replacing it is a design decision, not a regeneration.
echo "previews:"
svg sub-golden           preview-subagents  120 'agentline — subagent rows'      'subagent rows'
svg line-full            preview-full       120 'agentline — a full session'     'all four lines'
svg line-agents-overflow preview-agents     120 'agentline — agents at work'     'agent column'
svg line-api-meter       preview-api        120 'agentline — external API meter' 'API meter'
