#!/bin/bash
# Installs agentline into ~/.claude/ and wires it into settings.json.
#
#   bash install.sh               install or upgrade the status bar
#   bash install.sh --with-hooks  also wire the optional word-counter and
#                                 agent-tracker hooks (see README)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
DEFAULT_DEST="$HOME/.claude/agentline/agentline.sh"
SVC_EXAMPLE="$SCRIPT_DIR/agentline-services.conf.example"
SVC_CONFIG="$HOME/.claude/agentline-services.conf"
OLD_SVC_CONFIG="$HOME/.claude/statusline-services.conf"

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Resolve the install target from settings.json. A custom agentline path is
# upgraded in place; a pre-rename *statusline* path is migrated to the default
# agentline location so the old name does not live on.
DEST=$(python3 - "$SETTINGS" "$DEFAULT_DEST" <<'PYEOF'
import json, shlex, sys
settings_path, default_dest = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        d = json.load(f)
except Exception:
    d = {}
cmd = (d.get("statusLine") or {}).get("command", "")
path = ""
if cmd:
    # "bash /path/agentline.sh" -> "/path/agentline.sh"
    for part in shlex.split(cmd):
        if part.endswith(".sh"):
            path = part
            break
if "statusline" in path.rsplit("/", 1)[-1]:
    path = ""
print(path or default_dest)
PYEOF
)

mkdir -p "$(dirname "$DEST")"
cp "$SCRIPT_DIR/agentline.sh" "$DEST"
chmod +x "$DEST"
echo "✓ Installed to $DEST"

# Machine-local service list. Never overwrite an existing one: it holds this
# host's unit names and is deliberately not tracked in git. A pre-rename
# statusline conf is migrated so the host keeps its unit list.
if [ -f "$SVC_CONFIG" ]; then
  echo "• Kept existing $SVC_CONFIG"
elif [ -f "$OLD_SVC_CONFIG" ]; then
  cp "$OLD_SVC_CONFIG" "$SVC_CONFIG"
  echo "✓ Migrated $OLD_SVC_CONFIG -> $SVC_CONFIG"
elif [ -f "$SVC_EXAMPLE" ]; then
  cp "$SVC_EXAMPLE" "$SVC_CONFIG"
  echo "✓ Seeded $SVC_CONFIG — edit it to list this machine's services"
fi

# Point settings.json at the installed script. An existing agentline command is
# left verbatim (it may carry an interpreter prefix or a custom path); an empty
# or pre-rename statusline command is (re)pointed at $DEST.
python3 - "$DEST" "$SETTINGS" <<'PYEOF'
import json, sys
dest, settings_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        d = json.load(f)
except Exception:
    d = {}
existing = (d.get("statusLine") or {}).get("command", "")
if not existing or "statusline" in existing:
    d["statusLine"] = {"type": "command", "command": dest}
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"✓ settings.json statusLine set to {dest}")
elif dest in existing:
    print(f"• settings.json left as-is: {existing}")
else:
    # The configured command does not reference the path just installed to
    # (e.g. it points at a wrapper or a non-.sh symlink). Say so instead of
    # silently leaving a decoy copy behind.
    print(f"⚠ settings.json statusLine ({existing}) does not reference {dest};")
    print("  left untouched — update it manually if you meant to switch.")
PYEOF

# --- Optional hooks -----------------------------------------------------------
# The 💬 word-counter (line 1) and 🤖 agent-tracker (line 3) segments read
# files written by two small hooks. They are opt-in because they touch the
# hooks section of settings.json.
if [ "${1:-}" = "--with-hooks" ]; then
  HOOKS_DEST="$HOME/.claude/agentline"
  mkdir -p "$HOOKS_DEST"
  cp "$SCRIPT_DIR/hooks/wordcount-hook.sh" "$HOOKS_DEST/"
  cp "$SCRIPT_DIR/hooks/agent-tracker-hook.sh" "$HOOKS_DEST/"
  chmod +x "$HOOKS_DEST/wordcount-hook.sh" "$HOOKS_DEST/agent-tracker-hook.sh"

  python3 - "$SETTINGS" "$HOOKS_DEST" <<'PYEOF'
import json, sys
settings_path, hooks_dest = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})

def ensure(event, matcher, command):
    """Idempotently add a command hook. A hook with the same script name
    counts as already present; one still pointing into a pre-rename
    'statusline' directory is repointed at the fresh install instead of
    being left to dangle."""
    basename = command.rsplit("/", 1)[-1]
    groups = hooks.setdefault(event, [])
    for g in groups:
        for h in g.get("hooks", []):
            cmd = h.get("command", "")
            if cmd.rsplit("/", 1)[-1] == basename:
                if "statusline" in cmd:
                    h["command"] = command
                return
    for g in groups:
        if g.get("matcher", "") == matcher:
            g.setdefault("hooks", []).append({"type": "command", "command": command})
            return
    groups.append({"matcher": matcher, "hooks": [{"type": "command", "command": command}]})

wc = f"{hooks_dest}/wordcount-hook.sh"
at = f"{hooks_dest}/agent-tracker-hook.sh"
ensure("PostToolUse", "", wc)
ensure("Stop", "", wc)
# The subagent tool is 'Agent' in current Claude Code releases, 'Task' in
# earlier ones; the regex matcher covers both.
ensure("PreToolUse", "Agent|Task", at)
ensure("Stop", "", at)

with open(settings_path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print("✓ Hooks wired: word counter (💬) + agent tracker (🤖)")
PYEOF
fi

echo "Done. Restart Claude Code to see the status bar."
