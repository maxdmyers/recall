#!/usr/bin/env bash
# agentic-os :: SessionStart hook — injects vault knowledge indexes as
# additional context. Read-only, never modifies project files. Fails open:
# any error -> exit 0 silently so a broken vault never blocks session start.
#
# Fires on all SessionStart sources (startup, resume, clear, compact) so
# context survives /clear and auto-compact too.

set +e  # never die

VAULT="${AGENTIC_OS_VAULT:-$HOME/Documents/Vault}"
KNOWLEDGE="$VAULT/agentic-os/knowledge"
[ -d "$KNOWLEDGE" ] || exit 0

# Project = git root basename, else cwd basename. Matches capture-session.sh.
CWD="$PWD"
if REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); then
  PROJECT=$(basename "$REPO")
  SKILLS_DIR="$REPO/.claude/skills"
else
  PROJECT=$(basename "$CWD")
  SKILLS_DIR="$CWD/.claude/skills"
fi

# Compose the context block. Tagged so Claude can recognize it as background.
CTX=$(
  echo "<agentic-os-knowledge>"
  echo "Indexes from your knowledge vault. Read full notes on demand:"
  echo "  $KNOWLEDGE/global/<name>.md  or  $KNOWLEDGE/projects/$PROJECT/<name>.md"
  echo

  [ -f "$KNOWLEDGE/global/INDEX.md" ] && { cat "$KNOWLEDGE/global/INDEX.md"; echo; }

  PROJ_INDEX="$KNOWLEDGE/projects/$PROJECT/INDEX.md"
  if [ -f "$PROJ_INDEX" ]; then
    cat "$PROJ_INDEX"; echo
  else
    echo "# $PROJECT knowledge"
    echo "(no project notes yet — distill will populate as sessions accumulate)"
    echo
  fi

  # Live list of installed skills for this project (read each SKILL.md's
  # frontmatter description). Computed live so newly-installed skills appear
  # the same day, without waiting on a vault refresh.
  if [ -d "$SKILLS_DIR" ]; then
    found=0
    for sk in "$SKILLS_DIR"/*/SKILL.md; do
      [ -f "$sk" ] || continue
      [ "$found" -eq 0 ] && { echo "# $PROJECT installed skills"; found=1; }
      sk_name=$(basename "$(dirname "$sk")")
      sk_desc=$(awk '/^description:/ {sub(/^description: */,""); print; exit}' "$sk")
      echo "- $sk_name — ${sk_desc:-<no description>}"
    done
    [ "$found" -eq 1 ] && echo
  fi

  echo "</agentic-os-knowledge>"
)

# Read the hook event name from stdin (SessionStart for all sources). Default
# to SessionStart if stdin parse fails — the value is informational only.
STDIN_JSON=$(cat 2>/dev/null)
EVENT=$(printf '%s' "$STDIN_JSON" | /usr/bin/jq -r '.hook_event_name // "SessionStart"' 2>/dev/null)
[ -z "$EVENT" ] && EVENT="SessionStart"

# Emit JSON with additionalContext. jq -R -s --arg handles all escaping safely.
printf '%s' "$CTX" | /usr/bin/jq -R -s --arg event "$EVENT" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: .}}'

exit 0
