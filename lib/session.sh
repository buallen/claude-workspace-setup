#!/bin/bash

SESSION_ROOT="${SESSION_ROOT:-$HOME/claude-sessions}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR/#\~/$HOME}"
CLAUDE_SESSION_PROJECTS_DIR="${CLAUDE_SESSION_PROJECTS_DIR:-}"
CLAUDE_SESSION_PROJECTS_DIR="${CLAUDE_SESSION_PROJECTS_DIR/#\~/$HOME}"

session_base_env_prefix() {
  local quoted
  printf -v quoted '%q ' env -u NO_COLOR COLORTERM="${COLORTERM:-truecolor}"
  printf '%s' "$quoted"
}

session_dir() {
  printf '%s/%s\n' "$SESSION_ROOT" "$1"
}

session_project_key() {
  session_dir "$1" | sed 's#[^A-Za-z0-9_-]#-#g'
}

session_project_dir() {
  local projects_dir="${CLAUDE_SESSION_PROJECTS_DIR:-$CLAUDE_CONFIG_DIR/projects}"
  printf '%s/%s\n' "$projects_dir" "$(session_project_key "$1")"
}

runtime_session_project_dir() {
  printf '%s/projects/%s\n' "$CLAUDE_CONFIG_DIR" "$(session_project_key "$1")"
}

ensure_session_project_mapping() {
  local session_name="$1"
  local target_dir runtime_dir runtime_parent current_target existing_entry

  [ -n "$CLAUDE_SESSION_PROJECTS_DIR" ] || return 0
  [ "$CLAUDE_SESSION_PROJECTS_DIR" != "$CLAUDE_CONFIG_DIR/projects" ] || return 0

  target_dir="$(session_project_dir "$session_name")"
  runtime_dir="$(runtime_session_project_dir "$session_name")"
  runtime_parent="$(dirname "$runtime_dir")"

  mkdir -p "$target_dir" "$runtime_parent"

  if [ -L "$runtime_dir" ]; then
    current_target="$(readlink "$runtime_dir")"
    [ "$current_target" = "$target_dir" ] && return 0
    rm "$runtime_dir"
  elif [ -e "$runtime_dir" ]; then
    existing_entry="$(find "$runtime_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    if [ -n "$existing_entry" ]; then
      echo "Error: cannot map '$runtime_dir' to '$target_dir' because it is not empty" >&2
      echo "Move or purge that project state first, then retry." >&2
      return 1
    fi
    rmdir "$runtime_dir"
  fi

  ln -s "$target_dir" "$runtime_dir"
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
  local project_dir

  [ -n "$session_id" ] || return 0

  project_dir="$(session_project_dir "$session_name")"
  mkdir -p "$project_dir"

  if [ -f "$project_dir/${session_id}.jsonl" ]; then
    printf '%s\n' "$session_id"
    return 0
  fi

  echo "Warning: session file for '$session_id' not found in '$project_dir' - not resuming by id" >&2
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
