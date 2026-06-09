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
#   all        everything above

set +e

VAULT="${RECALL_VAULT:-$HOME/Documents/Vault}"
AOS="$VAULT/recall"
SESSIONS="$AOS/sessions"
KNOWLEDGE="$AOS/knowledge"
LOG="$AOS/.distill.log"

[ -d "$AOS" ] || { echo "recall: vault not found at $AOS" >&2; exit 1; }

# ---- helpers ----
hr() { printf '\n— %s —\n' "$1"; }

cmd_status() {
  hr "sessions"
  local total undist
  total=$(ls "$SESSIONS"/*.md 2>/dev/null | wc -l | tr -d ' ')
  undist=$(grep -rl '^distilled: false' "$SESSIONS" 2>/dev/null | wc -l | tr -d ' ')
  printf "  total %s  |  distilled %s  |  undistilled %s\n" "$total" "$((total - undist))" "$undist"

  hr "knowledge"
  local notes
  notes=$(find "$KNOWLEDGE" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
  printf "  notes %s\n" "$notes"
  for d in "$KNOWLEDGE/global" "$KNOWLEDGE/projects"/*; do
    [ -d "$d" ] || continue
    local rel n
    rel="${d#$KNOWLEDGE/}"
    n=$(find "$d" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
    printf "    %-30s %s\n" "$rel" "$n"
  done

  hr "distill schedule"
  local job_status last_line
  job_status=$(launchctl list 2>/dev/null | awk '/com\.recall\.distill/ {printf "PID=%s  exit=%s", $1, $2}')
  printf "  launchd  %s\n" "${job_status:-not loaded}"
  last_line=$(grep -E ' done$| FAILED| skip:' "$LOG" 2>/dev/null | tail -1)
  printf "  last run %s\n" "${last_line:-(no runs logged)}"

  hr "proposals"
  if [ -f "$AOS/inbox/proposals.md" ]; then
    local prop_count impl_count
    prop_count=$(grep -c '^## ' "$AOS/inbox/proposals.md" 2>/dev/null)
    impl_count=$(grep -c 'status:.*implemented' "$AOS/inbox/proposals.md" 2>/dev/null)
    printf "  total %s  |  implemented %s  |  pending %s\n" "$prop_count" "$impl_count" "$((prop_count - impl_count))"
  else
    echo "  no proposals file yet"
  fi

  hr "vault git"
  local dirty unpushed
  dirty=$(git -C "$VAULT" status --short 2>/dev/null | wc -l | tr -d ' ')
  unpushed=$(git -C "$VAULT" log @{u}.. --oneline 2>/dev/null | wc -l | tr -d ' ')
  printf "  dirty %s file(s)  |  unpushed %s commit(s)\n" "$dirty" "$unpushed"
}

cmd_sessions() {
  hr "sessions by project"
  grep -h '^project:' "$SESSIONS"/*.md 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/  /'

  hr "5 most recent sessions"
  ls -t "$SESSIONS"/*.md 2>/dev/null | head -5 | while read -r f; do
    local proj upd dist
    proj=$(grep -m1 '^project:' "$f" | sed 's/^project: //')
    upd=$(grep -m1 '^updated:' "$f" | sed 's/^updated: //')
    dist=$(grep -m1 '^distilled:' "$f" | sed 's/^distilled: //')
    printf "  %-20s  %s  distilled=%s\n" "$proj" "$upd" "$dist"
  done
}

cmd_knowledge() {
  hr "notes by area"
  for d in "$KNOWLEDGE/global" "$KNOWLEDGE/projects"/*; do
    [ -d "$d" ] || continue
    local rel n
    rel="${d#$KNOWLEDGE/}"
    n=$(find "$d" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-30s %s\n" "$rel" "$n"
  done

  hr "5 most recently updated notes"
  find "$KNOWLEDGE" -name '*.md' -not -name 'INDEX.md' -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -rn | head -5 \
    | awk -v k="$KNOWLEDGE/" '{ ts=$1; $1=""; sub(/^ /,""); sub(k,""); cmd="date -r "ts" +%Y-%m-%d"; cmd | getline d; close(cmd); printf "  %s  %s\n", d, $0 }'
}

cmd_proposals() {
  local f="$AOS/inbox/proposals.md"
  [ -f "$f" ] || { echo "no proposals file"; return; }
  hr "skill / automation proposals"
  awk '
    /^## / { if (name) print_block(); name=substr($0,4); status=""; scope=""; conf=""; seen=""; what="" }
    /^- status:/ { sub(/^- status: */,""); status=$0 }
    /^- scope:/  { sub(/^- scope: */,"");  scope=$0  }
    /^- confidence:/ { sub(/^- confidence: */,""); conf=$0 }
    /^- seen:/ { sub(/^- seen: */,""); seen=$0 }
    /^- what:/ { sub(/^- what: */,""); what=$0 }
    END { if (name) print_block() }
    function print_block() {
      printf "  %s  [%s]\n", name, status
      printf "    scope: %s  |  confidence: %s\n", scope, conf
      printf "    seen:  %s\n", seen
      printf "    what:  %s\n\n", what
    }
  ' "$f"
}

cmd_distill() {
  hr "last 10 distill runs"
  grep -E ' done$| FAILED| skip:| nothing changed' "$LOG" 2>/dev/null | tail -10 | sed 's/^/  /'

  hr "cost breakdown"
  grep '^{' "$LOG" 2>/dev/null | /usr/bin/jq -s -r '
    if length == 0 then "  (no completed runs yet)"
    else
      "  runs \(length)  |  total $\((map(.total_cost_usd) | add) | . * 10000 | round / 10000)  |  avg $\(((map(.total_cost_usd) | add) / length) * 10000 | round / 10000)",
      "",
      (to_entries | .[] | "  #\(.key + 1)  $\(.value.total_cost_usd | . * 10000 | round / 10000)  \(.value.duration_ms / 1000 | floor)s  \(.value.num_turns) turns")
    end
  '
}

case "${1:-status}" in
  status)     cmd_status ;;
  sessions)   cmd_sessions ;;
  knowledge)  cmd_knowledge ;;
  proposals)  cmd_proposals ;;
  distill)    cmd_distill ;;
  all)        cmd_status; cmd_sessions; cmd_knowledge; cmd_proposals; cmd_distill ;;
  -h|--help|help) echo "usage: recall.sh [status|sessions|knowledge|proposals|distill|all]" ;;
  *) echo "unknown subcommand: $1" >&2; exit 1 ;;
esac
