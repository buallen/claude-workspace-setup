#!/bin/bash
# Start a Happy Coder tmux session through VibeProxy without modifying the
# existing happy-session / claude-session scripts.

set -euo pipefail

MODEL="gpt-5.5"
EFFORT="max"
RESTART="false"

usage() {
  cat <<'EOF'
Usage: happy-vibe-session [--restart] [--model MODEL] [--effort LEVEL] <task-name> [session-id]

Examples:
  happy-vibe-session TroubleShooting
  happy-vibe-session --restart TroubleShooting
  happy-vibe-session --model gpt-5.3-codex TroubleShooting
  happy-vibe-session --effort high TroubleShooting

Notes:
  Existing live tmux sessions are attached unchanged. Use --restart when you
  want to kill and recreate the tmux session with VibeProxy.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --restart)
      RESTART="true"
      shift
      ;;
    --model)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --model" >&2
        exit 2
      fi
      MODEL="$2"
      shift 2
      ;;
    --effort)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --effort" >&2
        exit 2
      fi
      case "$2" in
        low|medium|high|max)
          EFFORT="$2"
          ;;
        *)
          echo "Invalid --effort value: $2" >&2
          echo "Allowed values: low, medium, high, max" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

SESSION_NAME="${1:-}"
SESSION_ID="${2:-}"

if [ -z "$SESSION_NAME" ]; then
  usage >&2
  exit 2
fi

if ! lsof -i :8317 -sTCP:LISTEN >/dev/null 2>&1; then
  if [ -d /Applications/VibeProxy.app ]; then
    open -a /Applications/VibeProxy.app
    sleep 3
  fi
fi

if ! lsof -i :8317 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "VibeProxy is not running. Launch /Applications/VibeProxy.app first." >&2
  exit 1
fi

if ! curl -fsS --max-time 10 http://127.0.0.1:8317/v1/models | grep -q "\"id\":\"${MODEL}\""; then
  echo "VibeProxy is running, but model '${MODEL}' is not available." >&2
  echo "Available models:" >&2
  curl -fsS --max-time 10 http://127.0.0.1:8317/v1/models \
    | tr '{},' '\n' \
    | sed -n 's/.*"id":"\([^"]*\)".*/  \1/p' >&2
  exit 1
fi

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  if [ "$RESTART" = "true" ]; then
    tmux kill-session -t "$SESSION_NAME"
  else
    echo "tmux session '$SESSION_NAME' already exists." >&2
    echo "Run with --restart to recreate it with VibeProxy, or exit happy inside the pane first." >&2
    exec tmux attach -t "$SESSION_NAME"
  fi
fi

SESSION_DIR="$HOME/claude-sessions/$SESSION_NAME"
mkdir -p "$SESSION_DIR"

ENV_PREFIX=$(printf '%q ' \
  env \
  HAPPY_SERVER_URL="${HAPPY_SERVER_URL:-http://localhost:3005}" \
  ANTHROPIC_BASE_URL="http://localhost:8317" \
  ANTHROPIC_AUTH_TOKEN="vibeproxy" \
  ANTHROPIC_API_KEY="" \
  DISABLE_TELEMETRY="true" \
  DISABLE_COST_WARNINGS="true" \
  API_TIMEOUT_MS="600000")

if [ -n "$SESSION_ID" ]; then
  HAPPY_CMD="${ENV_PREFIX}$(printf '%q ' happy --yolo --model "$MODEL" --effort "$EFFORT" --resume "$SESSION_ID")"
else
  HAPPY_CMD="${ENV_PREFIX}$(printf '%q ' happy --yolo --model "$MODEL" --effort "$EFFORT" --continue)"
fi

if ! tmux new-session -d -s "$SESSION_NAME" -c "$SESSION_DIR"; then
  echo "Error: failed to create tmux session '$SESSION_NAME'" >&2
  exit 1
fi

tmux send-keys -t "$SESSION_NAME" "$HAPPY_CMD" Enter
echo "New VibeProxy Happy session: $SESSION_NAME"
echo "Model: $MODEL"
echo "Effort: $EFFORT"

printf '\e]7;file://%s%s\a' "$(hostname)" "$SESSION_DIR"

if [ -n "${TMUX:-}" ]; then
  exec tmux switch-client -t "$SESSION_NAME"
else
  exec tmux attach -t "$SESSION_NAME"
fi
