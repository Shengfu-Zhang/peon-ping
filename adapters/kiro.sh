#!/bin/bash
# peon-ping adapter for Kiro CLI (Amazon)
# Translates Kiro hook events into peon.sh stdin JSON
#
# Kiro CLI has a hook system that pipes JSON to hooks via stdin,
# nearly identical to Claude Code. This adapter remaps the few
# differing event names and forwards to peon.sh.
#
# preToolUse triggers a background stall detector that plays a
# PermissionRequest sound if the kiro-cli DB doesn't update within
# PEON_STALL_TIMEOUT seconds (default: 30). This heuristically
# detects permission prompts without being noisy on auto-approved tools.
#
# Setup: Create ~/.kiro/agents/peon-ping.json with:
#
#   {
#     "name": "peon-ping",
#     "description": "Audio notifications via peon-ping hooks.",
#     "hooks": {
#       "agentSpawn": [
#         { "command": "bash ~/.claude/hooks/peon-ping/adapters/kiro.sh" }
#       ],
#       "userPromptSubmit": [
#         { "command": "bash ~/.claude/hooks/peon-ping/adapters/kiro.sh" }
#       ],
#       "stop": [
#         { "command": "bash ~/.claude/hooks/peon-ping/adapters/kiro.sh" }
#       ],
#       "preToolUse": [
#         { "command": "bash ~/.claude/hooks/peon-ping/adapters/kiro.sh" }
#       ]
#     }
#   }
#
# Tip: Desktop overlay notifications add ~10s latency to hooks.
#      Recommend: peon notifications off

set -euo pipefail

PEON_DIR="${CLAUDE_PEON_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/peon-ping}"
STALL_TIMEOUT="${PEON_STALL_TIMEOUT:-30}"

# --- Platform-aware kiro-cli DB path ---
find_kiro_db() {
  [ -n "${KIRO_DB:-}" ] && { echo "$KIRO_DB"; return; }
  case "$(uname -s)" in
    Darwin)
      echo "${HOME}/Library/Application Support/kiro-cli/data.sqlite3" ;;
    Linux)
      local db="${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli/data.sqlite3"
      [ -f "$db" ] || db="${HOME}/.config/kiro-cli/data.sqlite3"
      [ -f "$db" ] || db="${HOME}/.kiro-cli/data.sqlite3"
      echo "$db" ;;
    *) echo "" ;;
  esac
}

# --- Stall detector (runs in background for preToolUse) ---
stall_watch() {
  local db="$1" session_id="$2" cwd="$3"
  local lockfile="/tmp/kiro-stall-${session_id}.pid"

  # Kill previous watcher for this session
  if [ -f "$lockfile" ]; then
    local old_pid
    old_pid=$(cat "$lockfile" 2>/dev/null)
    [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
  fi
  echo $$ > "$lockfile"
  trap '[ -f "'"$lockfile"'" ] && [ "$(cat "'"$lockfile"'" 2>/dev/null)" = "'"$$"'" ] && rm -f "'"$lockfile"'"' EXIT

  # Snapshot current DB timestamp for this session
  local initial
  initial=$(sqlite3 "$db" "SELECT MAX(updated_at) FROM conversations_v2 WHERE key='$cwd';" 2>/dev/null)
  [ -z "$initial" ] && exit 0

  # Poll — exit early if DB changes
  local elapsed=0
  while [ "$elapsed" -lt "$STALL_TIMEOUT" ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    local current
    current=$(sqlite3 "$db" "SELECT MAX(updated_at) FROM conversations_v2 WHERE key='$cwd';" 2>/dev/null)
    [ "$current" != "$initial" ] && exit 0
  done

  # Stalled — play permission sound
  echo '{"hook_event_name":"PermissionRequest","session_id":"kiro-'"$session_id"'","cwd":"'"$cwd"'"}' \
    | bash "$PEON_DIR/peon.sh"
}

# --- Read and remap event ---
INPUT=$(cat)
MAPPED_JSON=$(echo "$INPUT" | python3 -c "
import sys, json, os

data = json.load(sys.stdin)
event = data.get('hook_event_name', 'stop')

remap = {
    'agentSpawn': 'SessionStart',
    'userPromptSubmit': 'UserPromptSubmit',
    'stop': 'Stop',
    'preToolUse': '_StallWatch',
}

mapped = remap.get(event)
if mapped is None:
    sys.exit(0)

sid = data.get('session_id', str(os.getpid()))
cwd = data.get('cwd', os.getcwd())

print(json.dumps({
    'hook_event_name': mapped,
    'notification_type': '',
    'cwd': cwd,
    'session_id': sid,
    'permission_mode': data.get('permission_mode', ''),
}))
")

[ -z "$MAPPED_JSON" ] && exit 0

EVENT=$(echo "$MAPPED_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['hook_event_name'])")
SESSION_ID=$(echo "$MAPPED_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
CWD=$(echo "$MAPPED_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['cwd'])")

if [ "$EVENT" = "_StallWatch" ]; then
  # preToolUse — spawn background stall detector
  KIRO_DB=$(find_kiro_db)
  if [ -n "$KIRO_DB" ] && [ -f "$KIRO_DB" ] && command -v sqlite3 >/dev/null; then
    stall_watch "$KIRO_DB" "$SESSION_ID" "$CWD" &
    disown
  fi
else
  # Normal event — forward to peon.sh with kiro- prefix
  echo "$MAPPED_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['session_id'] = 'kiro-' + d['session_id']
print(json.dumps(d))
" | bash "$PEON_DIR/peon.sh"
fi
