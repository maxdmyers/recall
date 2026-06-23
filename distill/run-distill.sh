#!/usr/bin/env bash
# recall :: nightly distill runner (local, Mac-only)
# pull vault -> thin undistilled session transcripts -> run Sonnet distill ->
# mark sessions distilled -> commit & push vault.
# Skips (costs $0) if fewer than THRESHOLD undistilled sessions.

# Needs bash 4+ (mapfile). macOS /bin/bash is 3.2 — re-exec under Homebrew bash if so.
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "run-distill: needs bash 4+ (have $BASH_VERSION); no modern bash found" >&2
  exit 1
fi

set -uo pipefail

AOS="${RECALL_VAULT:-$HOME/Documents/Vault/recall}"
SESSIONS="$AOS/sessions"
# Git lives at the enclosing repo root — recall may be its own repo or nested
# inside a larger vault. Fall back to the recall dir if it isn't a repo yet.
GIT_ROOT="$(git -C "$AOS" rev-parse --show-toplevel 2>/dev/null || echo "$AOS")"
SCRATCH="$GIT_ROOT/.distill-scratch"
LOCK="$GIT_ROOT/.distill.lock"
HERE="$(cd "$(dirname "$0")" && pwd)"
THRESHOLD="${RECALL_DISTILL_THRESHOLD:-1}"
MODEL="${RECALL_DISTILL_MODEL:-sonnet}"
BUDGET="${RECALL_DISTILL_BUDGET:-1.50}"
LOG="$AOS/.distill.log"

log(){ printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

# Single-run lock (mkdir is atomic).
if ! mkdir "$LOCK" 2>/dev/null; then log "skip: locked"; exit 0; fi
trap 'rm -rf "$LOCK" "$SCRATCH"' EXIT

export RECALL_DISTILL=1   # stops the capture hook logging our own claude run

cd "$GIT_ROOT" || { log "no vault at $GIT_ROOT"; exit 1; }
git pull --rebase --autostash -q 2>>"$LOG" || log "warn: git pull failed"

# Refresh the code repo's remote-tracking ref so the dashboard's "update available"
# hint stays current (fetch only — no checkout). Non-fatal.
git -C "$HERE/.." fetch -q 2>>"$LOG" || log "warn: repo fetch failed"

# Refresh the dashboard every night (cheap, pure shell) — even if we skip
# distilling below, so queue count + schedule health stay current.
"$HERE/../dashboard/build-dashboard.sh" >>"$LOG" 2>&1 || log "warn: dashboard build failed"

# Collect undistilled sessions, excluding ones touched in the last STALE min
# (the hook rewrites the dump each turn, so a recent mtime == session still active).
STALE="${RECALL_DISTILL_STALE_MIN:-30}"
mapfile -t TODO < <(comm -12 \
  <(grep -rl '^distilled: false' "$SESSIONS" 2>/dev/null | sort) \
  <(find "$SESSIONS" -name '*.md' -mmin +"$STALE" 2>/dev/null | sort))
COUNT=${#TODO[@]}
if [ "$COUNT" -lt "$THRESHOLD" ]; then log "skip: $COUNT undistilled (< $THRESHOLD)"; exit 0; fi
log "start: $COUNT undistilled sessions"

# Thin each session's transcript into scratch (fallback: the dump itself).
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
for f in "${TODO[@]}"; do
  proj=$(grep -m1 '^project:' "$f" | sed 's/^project: //')
  sid=$(grep -m1 '^session_id:' "$f" | sed 's/^session_id: //')
  tx=$(grep -m1 '^transcript:' "$f" | sed 's/^transcript: //')
  out="$SCRATCH/${proj}__${sid:0:8}.md"
  {
    echo "# session: $sid"
    echo "# project: $proj"
    echo
    if [ -f "$tx" ]; then "$HERE/thin-transcript.sh" "$tx"; else cat "$f"; fi
  } > "$out"
done

# Run the distill agent headless. Restrict tools; auto-accept edits; cap spend.
PROMPT=$(cat "$HERE/distill-prompt.md")
if claude -p "$PROMPT" \
    --model "$MODEL" \
    --permission-mode acceptEdits \
    --allowedTools "Read Write Edit Glob Grep" \
    --add-dir "$GIT_ROOT" \
    --max-budget-usd "$BUDGET" \
    --output-format json >>"$LOG" 2>&1; then
  log "distill ok"
else
  log "distill FAILED (rc=$?); leaving sessions undistilled"; exit 1
fi

# Mark processed sessions distilled (only after success).
# perl, not sed: byte-safe against emoji/UTF-8 in dumps (BSD sed throws "illegal byte sequence").
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
for f in "${TODO[@]}"; do
  perl -i -pe 's/^distilled: false/distilled: true/' "$f"
  grep -q '^distilled_at:' "$f" || perl -i -pe "s/^(distilled: true)\$/\$1\ndistilled_at: $NOW/" "$f"
done

# Commit & push knowledge back.
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "distill: $COUNT sessions -> knowledge ($(date -u '+%Y-%m-%d'))"
  git push -q 2>>"$LOG" || log "warn: git push failed"
  log "committed + pushed"
else
  log "nothing changed to commit"
fi

# Rebuild dashboard so freshly-distilled notes show up tonight, not tomorrow.
"$HERE/../dashboard/build-dashboard.sh" >>"$LOG" 2>&1 || log "warn: dashboard build failed"
log "done"
