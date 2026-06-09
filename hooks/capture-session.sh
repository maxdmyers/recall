#!/usr/bin/env bash
# recall :: capture hook (Stop)
# Idempotent per session_id. Writes a lightweight markdown dump pointing at the
# full transcript, so the nightly distill can read sessions without an LLM call here.
# Pure shell + jq + git. Never blocks Claude: always exits 0.

set -uo pipefail

VAULT="${RECALL_VAULT:-$HOME/Documents/Vault/recall}"
SESSIONS="$VAULT/sessions"

# Don't capture distill's own headless claude runs (recursion guard).
[ -n "${RECALL_DISTILL:-}" ] && exit 0

PAYLOAD=$(cat)

# Only act on the Stop event regardless of how we're wired.
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty')
[ "$EVENT" = "Stop" ] || { [ -n "$EVENT" ] && exit 0; }

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty')
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty')
LAST_MSG=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' | tr '\n' ' ' | head -c 500)

[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] || CWD="$PWD"

# Project identity: git repo root basename, else launch-dir basename.
if REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); then
  PROJECT=$(basename "$REPO")
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
  DIFFSTAT=$(git -C "$CWD" diff --stat 2>/dev/null | tail -40)
  STATUS=$(git -C "$CWD" status --short 2>/dev/null | head -40)
else
  PROJECT=$(basename "$CWD")
  BRANCH=""
  DIFFSTAT=""
  STATUS=""
fi

SHORT="${SESSION_ID:0:8}"
mkdir -p "$SESSIONS"
FILE="$SESSIONS/${PROJECT}__${SHORT}.md"

# Preserve original Started timestamp across turns.
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
if [ -f "$FILE" ]; then
  STARTED=$(grep -m1 '^started:' "$FILE" | sed 's/^started: //')
fi
[ -n "${STARTED:-}" ] || STARTED="$NOW"

{
  echo "---"
  echo "session_id: $SESSION_ID"
  echo "project: $PROJECT"
  echo "branch: ${BRANCH:-}"
  echo "cwd: $CWD"
  echo "started: $STARTED"
  echo "updated: $NOW"
  echo "transcript: $TRANSCRIPT"
  echo "distilled: false"
  echo "tags: [recall/session]"
  echo "---"
  echo
  echo "# Session $SHORT — $PROJECT"
  echo
  echo "## Last assistant message"
  echo "${LAST_MSG:-(none)}"
  echo
  echo "## Git diff --stat"
  echo '```'
  echo "${DIFFSTAT:-(no repo / no changes)}"
  echo '```'
  echo
  echo "## Git status"
  echo '```'
  echo "${STATUS:-(no repo / clean)}"
  echo '```'
} > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

exit 0
