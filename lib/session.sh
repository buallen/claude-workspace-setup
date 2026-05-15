#!/bin/bash

SESSION_ROOT="${SESSION_ROOT:-$HOME/claude-sessions}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR/#\~/$HOME}"

session_dir() {
  printf '%s/%s\n' "$SESSION_ROOT" "$1"
}

ensure_session_dir() {
  mkdir -p "$(session_dir "$1")"
}

print_running_sessions() {
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (none)"
}

resolve_session_id() {
  local session_name="$1"
  local session_id="$2"
  local session_project_dir session_project_key found

  [ -n "$session_id" ] || return 0

  session_project_key="$(session_dir "$session_name" | sed 's#[^A-Za-z0-9_-]#-#g')"
  session_project_dir="$CLAUDE_CONFIG_DIR/projects/${session_project_key}"
  mkdir -p "$session_project_dir"

  if [ -f "$session_project_dir/${session_id}.jsonl" ]; then
    printf '%s\n' "$session_id"
    return 0
  fi

  found=$(find "$CLAUDE_CONFIG_DIR/projects" -name "${session_id}.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    ln "$found" "$session_project_dir/${session_id}.jsonl" 2>/dev/null || true
    printf '%s\n' "$session_id"
  else
    echo "Warning: session file for '$session_id' not found - starting fresh session" >&2
  fi
}

attach_or_switch() {
  local session_name="$1"
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "$session_name"
  else
    exec tmux attach -t "$session_name"
  fi
}

emit_vscode_cwd() {
  local dir="$1"
  printf '\e]7;file://%s%s\a' "$(hostname)" "$dir"
}
