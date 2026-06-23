#!/usr/bin/env bash
# recall :: status CLI / dashboard
# Read-only inspection of vault state. Surface for /recall skill.
#
# Subcommands:
#   status     overall health (default)
#   sessions   per-project session breakdown + recency
#   knowledge  knowledge notes by area + recent additions
#   proposals  pending + implemented skill proposals
#   distill    last N distill runs (cost, duration, outcome)
#   open       (re)build the HTML dashboard and open it in the browser
#   update     git pull the repo + re-apply install (self-update)
#   all        everything above
#
# Honors NO_COLOR (and auto-disables color when piped).

set +e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOS="${RECALL_VAULT:-$HOME/Documents/Vault/recall}"
SESSIONS="$AOS/sessions"
KNOWLEDGE="$AOS/knowledge"
LOG="$AOS/.distill.log"
GIT_ROOT="$(git -C "$AOS" rev-parse --show-toplevel 2>/dev/null || echo "$AOS")"
REPO_DIR="$(cd "$HERE/.." && pwd)"
recall_version() { git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown; }
updates_behind() { git -C "$REPO_DIR" rev-list --count HEAD..@{u} 2>/dev/null || echo 0; }

# ---- presentation ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  MAG=$'\033[35m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; D=""; R=""; MAG=""; GRN=""; YEL=""; RED=""; CYN=""
fi
RULE="────────────────────────────────────────────────────"
hr()   { printf '\n  %s▸ %s%s\n' "$B$MAG" "$1" "$R"; }
kv()   { printf '    %s%-11s%s %s\n' "$D" "$1" "$R" "$2"; }
row()  { printf '    %s\n' "$1"; }
note() { printf '    %s%s%s\n' "$D" "$1" "$R"; }
# colorize a count: plain if zero, color $2 if nonzero
hot()  { if [ "${1:-0}" -gt 0 ] 2>/dev/null; then printf '%s%s%s' "$2" "$1" "$R"; else printf '%s' "${1:-0}"; fi; }

[ -d "$AOS" ] || { printf '%srecall:%s vault not found at %s\n' "$RED" "$R" "$AOS" >&2; exit 1; }

cmd_status() {
  printf '\n  %s✦ recall%s  %s%s%s\n' "$B$MAG" "$R" "$D" "$(recall_version)" "$R"
  printf '  %s%s%s\n' "$D" "$RULE" "$R"
  local behind; behind=$(updates_behind)
  [ "${behind:-0}" -gt 0 ] && printf '  %s↑ update available%s — %s commit(s) behind · run: recall.sh update\n' "$YEL$B" "$R" "$behind"

  hr "Sessions"
  local total undist
  total=$(ls "$SESSIONS"/*.md 2>/dev/null | wc -l | tr -d ' ')
  undist=$(grep -rl '^distilled: false' "$SESSIONS" 2>/dev/null | wc -l | tr -d ' ')
  kv "captured"  "$total"
  kv "distilled" "$((total - undist))"
  kv "in queue"  "$(hot "$undist" "$YEL")"

  hr "Knowledge"
  local notes
  notes=$(find "$KNOWLEDGE" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
  kv "notes" "$notes"
  for d in "$KNOWLEDGE/global" "$KNOWLEDGE/projects"/*; do
    [ -d "$d" ] || continue
    local rel n
    rel="${d#$KNOWLEDGE/}"
    n=$(find "$d" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
    printf '    %s%-22s%s %s\n' "$D" "$rel" "$R" "$n"
  done

  hr "Distill"
  local jobline exit_ health last_line
  jobline=$(launchctl list 2>/dev/null | grep 'com\.recall\.distill')
  if [ -n "$jobline" ]; then
    exit_=$(printf '%s' "$jobline" | awk '{print $2}')
    if [ "$exit_" = "0" ]; then health="${GRN}✓ scheduled${R}"; else health="${RED}✗ exit $exit_${R}"; fi
  else
    health="${YEL}not loaded${R}"
  fi
  kv "schedule" "$health"
  last_line=$(grep -E ' done$| FAILED| skip:' "$LOG" 2>/dev/null | tail -1)
  kv "last run" "${last_line:-(none logged)}"

  hr "Proposals"
  if [ -f "$AOS/inbox/proposals.md" ]; then
    local pt pi
    pt=$(grep -c '^## ' "$AOS/inbox/proposals.md" 2>/dev/null); pt=${pt:-0}
    pi=$(grep -c 'status:.*implemented' "$AOS/inbox/proposals.md" 2>/dev/null); pi=${pi:-0}
    kv "pending"     "$(hot "$((pt - pi))" "$YEL")"
    kv "implemented" "$pi"
  else
    note "no proposals yet"
  fi

  hr "Vault git"
  local dirty unpushed
  dirty=$(git -C "$GIT_ROOT" status --short 2>/dev/null | wc -l | tr -d ' ')
  unpushed=$(git -C "$GIT_ROOT" log @{u}.. --oneline 2>/dev/null | wc -l | tr -d ' ')
  if [ "${dirty:-0}" -eq 0 ] && [ "${unpushed:-0}" -eq 0 ]; then
    row "${GRN}✓ clean${R} · up to date"
  else
    kv "changed"  "$(hot "$dirty" "$YEL") file(s)"
    kv "unpushed" "$(hot "$unpushed" "$YEL") commit(s)"
  fi
  printf '\n'
}

cmd_sessions() {
  hr "Sessions by project"
  grep -h '^project:' "$SESSIONS"/*.md 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'

  hr "Recent sessions"
  ls -t "$SESSIONS"/*.md 2>/dev/null | head -5 | while read -r f; do
    local proj upd dist
    proj=$(grep -m1 '^project:' "$f" | sed 's/^project: //')
    upd=$(grep -m1 '^updated:' "$f" | sed 's/^updated: //')
    dist=$(grep -m1 '^distilled:' "$f" | sed 's/^distilled: //')
    printf '    %s%-20s%s %s  %sdistilled=%s%s\n' "$B" "$proj" "$R" "$upd" "$D" "$dist" "$R"
  done
  printf '\n'
}

cmd_knowledge() {
  hr "Notes by area"
  for d in "$KNOWLEDGE/global" "$KNOWLEDGE/projects"/*; do
    [ -d "$d" ] || continue
    local rel n
    rel="${d#$KNOWLEDGE/}"
    n=$(find "$d" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
    printf '    %s%-22s%s %s\n' "$D" "$rel" "$R" "$n"
  done

  hr "Recently updated"
  find "$KNOWLEDGE" -name '*.md' -not -name 'INDEX.md' -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -rn | head -5 \
    | awk -v k="$KNOWLEDGE/" '{ ts=$1; $1=""; sub(/^ /,""); sub(k,""); cmd="date -r "ts" +%Y-%m-%d"; cmd | getline d; close(cmd); printf "    %s  %s\n", d, $0 }'
  printf '\n'
}

cmd_proposals() {
  local f="$AOS/inbox/proposals.md"
  [ -f "$f" ] || { hr "Proposals"; note "no proposals file"; return; }
  hr "Proposals"
  awk -v B="$B" -v D="$D" -v R="$R" '
    /^## / { if (name) print_block(); name=substr($0,4); status=""; scope=""; conf=""; seen=""; what="" }
    /^- status:/ { sub(/^- status: */,""); status=$0 }
    /^- scope:/  { sub(/^- scope: */,"");  scope=$0  }
    /^- confidence:/ { sub(/^- confidence: */,""); conf=$0 }
    /^- seen:/ { sub(/^- seen: */,""); seen=$0 }
    /^- what:/ { sub(/^- what: */,""); what=$0 }
    END { if (name) print_block() }
    function print_block() {
      printf "    %s%s%s  %s[%s]%s\n", B, name, R, D, status, R
      printf "      %sscope%s %s   %sconfidence%s %s\n", D, R, scope, D, R, conf
      printf "      %sseen%s  %s\n", D, R, seen
      printf "      %swhat%s  %s\n\n", D, R, what
    }
  ' "$f"
}

cmd_distill() {
  hr "Recent runs"
  grep -E ' done$| FAILED| skip:| nothing changed' "$LOG" 2>/dev/null | tail -10 | sed 's/^/    /'

  hr "Cost"
  grep '^{' "$LOG" 2>/dev/null | jq -s -r '
    if length == 0 then "    (no completed runs yet)"
    else
      "    runs \(length)  |  total $\((map(.total_cost_usd) | add) | . * 10000 | round / 10000)  |  avg $\(((map(.total_cost_usd) | add) / length) * 10000 | round / 10000)",
      "",
      (to_entries | .[] | "    #\(.key + 1)  $\(.value.total_cost_usd | . * 10000 | round / 10000)  \(.value.duration_ms / 1000 | floor)s  \(.value.num_turns) turns")
    end
  '
  printf '\n'
}

cmd_open() {
  local out="$AOS/dashboard.html"
  "$HERE/build-dashboard.sh" "$out" || { printf '%srecall:%s dashboard build failed\n' "$RED" "$R" >&2; return 1; }
  command -v open >/dev/null 2>&1 && open "$out"
}

cmd_update() {
  hr "Update"
  kv "repo"    "$REPO_DIR"
  kv "current" "$(recall_version)"
  git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || { printf '%s    not a git checkout — can'\''t self-update%s\n' "$RED" "$R" >&2; return 1; }

  note "pulling latest…"
  git -C "$REPO_DIR" pull --ff-only 2>&1 | sed 's/^/    /'
  [ "${PIPESTATUS[0]}" -eq 0 ] \
    || { printf '%s    pull failed (local changes or diverged?) — resolve in %s%s\n' "$RED" "$REPO_DIR" "$R" >&2; return 1; }

  # Re-apply install non-interactively using the saved config, so any changed
  # plist/hooks templates take effect.
  local conf="$AOS/.recall-install" args
  args="-y"
  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    . "$conf"
    [ -n "${RECALL_VAULT:-}" ]   && args="$args --vault $RECALL_VAULT"
    [ -n "${RECALL_TIME:-}" ]    && args="$args --time $RECALL_TIME"
    [ "${RECALL_LAUNCHD:-1}" = "0" ]   && args="$args --no-launchd"
    [ "${RECALL_CLAUDE_MD:-1}" = "0" ] && args="$args --no-claude-md"
  fi
  note "re-applying install…"
  # shellcheck disable=SC2086
  "$REPO_DIR/install/install.sh" $args || { printf '%s    install step failed%s\n' "$RED" "$R" >&2; return 1; }
  kv "now at" "$(recall_version)"
}

case "${1:-status}" in
  status)     cmd_status ;;
  sessions)   cmd_sessions ;;
  knowledge)  cmd_knowledge ;;
  proposals)  cmd_proposals ;;
  distill)    cmd_distill ;;
  open|html)  cmd_open ;;
  update)     cmd_update ;;
  all)        cmd_status; cmd_sessions; cmd_knowledge; cmd_proposals; cmd_distill ;;
  -h|--help|help) echo "usage: recall.sh [status|sessions|knowledge|proposals|distill|open|update|all]" ;;
  *) printf '%srecall:%s unknown subcommand: %s\n' "$RED" "$R" "$1" >&2; exit 1 ;;
esac
