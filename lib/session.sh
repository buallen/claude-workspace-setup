#!/bin/bash

SESSION_ROOT="${SESSION_ROOT:-$HOME/claude-sessions}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR/#\~/$HOME}"

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

ensure_session_dir() {
  mkdir -p "$(session_dir "$1")"
}

cleanup_personal_default_shadow() {
  local session_name="$1"
  local shadow_dir entry

  [ "$session_name" = "Personal" ] || return 0
  [ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude-private" ] || return 0

  shadow_dir="$HOME/.claude/projects/$(session_project_key "$session_name")"
  [ -e "$shadow_dir" ] || return 0

  if [ -L "$shadow_dir" ]; then
    rm "$shadow_dir"
    return 0
  fi

  [ -d "$shadow_dir" ] || return 0

  while IFS= read -r entry; do
    [ -f "$entry" ] || {
      echo "Warning: refusing to remove non-file default Personal shadow entry: $entry" >&2
      return 1
    }
    case "$entry" in
      *.jsonl) ;;
      *)
        echo "Warning: refusing to remove non-jsonl default Personal shadow entry: $entry" >&2
        return 1
        ;;
    esac
    if [ -s "$entry" ] && grep -v '"type":"permission-mode"' "$entry" >/dev/null; then
      echo "Warning: refusing to remove default Personal shadow with non-permission content: $entry" >&2
      return 1
    fi
  done < <(find "$shadow_dir" -mindepth 1 -maxdepth 1 -print)

  rm -rf "$shadow_dir"
}

print_running_sessions() {
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (none)"
}

resolve_session_id() {
  local session_name="$1"
  local session_id="$2"
  local session_project_dir session_project_key found_id candidate f
  local current_session_file

  session_project_key="$(session_project_key "$session_name")"
  session_project_dir="$CLAUDE_CONFIG_DIR/projects/${session_project_key}"
  mkdir -p "$session_project_dir"
  ensure_session_dir "$session_name"
  current_session_file="$(session_dir "$session_name")/.current-session"

  # If a specific ID was given and the file exists, use it and pin it
  if [ -n "$session_id" ] && [ -f "$session_project_dir/${session_id}.jsonl" ]; then
    printf '%s\n' "$session_id"
    printf '%s\n' "$session_id" > "$current_session_file"
    return 0
  fi

  # Check .current-session marker — lets Mac and phone share the same session across reconnects
  if [ -f "$current_session_file" ]; then
    candidate="$(tr -d '[:space:]' < "$current_session_file")"
    if [ -n "$candidate" ] && [ -f "$session_project_dir/${candidate}.jsonl" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # Find the latest interactive session
  # Only skip queue-operation: those are definitively background agents started via /go or task queue
  # file-history-snapshot, ai-title, permission-mode etc. can all appear in interactive sessions
  found_id=""
  while IFS= read -r f; do
    candidate="$(basename "$f" .jsonl)"
    if head -1 "$f" 2>/dev/null | grep -q '"type":"queue-operation"'; then
      continue
    fi
    found_id="$candidate"
    break
  done < <(ls -t "$session_project_dir"/*.jsonl 2>/dev/null)

  if [ -n "$found_id" ]; then
    [ -n "$session_id" ] && echo "Warning: session '$session_id' not found - using latest interactive: $found_id" >&2
    printf '%s\n' "$found_id"
    printf '%s\n' "$found_id" > "$current_session_file"
    return 0
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
