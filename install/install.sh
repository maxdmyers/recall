#!/usr/bin/env bash
# recall :: installer (macOS)
# Renders the install templates for THIS machine, wires the Claude Code hooks
# into ~/.claude/settings.json (preserving any existing hooks), scaffolds the
# vault, and loads the nightly distill launchd job.
#
# Interactive by default (asks where the vault lives, whether to init git, and
# what time distill runs). Safe to re-run: hook merge + launchd load are idempotent.
#
#   ./install/install.sh                 # interactive
#   ./install/install.sh -y              # non-interactive, accept defaults
#   ./install/install.sh --vault DIR     # set the recall data dir explicitly
#   ./install/install.sh --time 22:30    # nightly distill time (24h HH:MM)
#   ./install/install.sh --no-git        # never git-init the vault
#   ./install/install.sh --no-launchd    # skip the scheduler
#   ./install/install.sh --no-claude-md  # don't add the recall block to ~/.claude/CLAUDE.md
#
# Clone this repo wherever you like — the installer locates itself, so the repo
# path is not hardcoded anywhere. Honors NO_COLOR. Runs under system bash 3.2.

set -uo pipefail

# ---- args / defaults ----
VAULT_DIR="${RECALL_VAULT:-}"     # empty => ask (or default) below
DISTILL_TIME="19:00"
DO_LAUNCHD=1
DO_GIT="auto"                     # auto = init if missing (ask first); no = never
DO_CLAUDE_MD="ask"                # ask = prompt (default yes); yes/no = forced
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_DIR="$2"; shift 2;;
    --time) DISTILL_TIME="$2"; shift 2;;
    --no-launchd) DO_LAUNCHD=0; shift;;
    --no-git) DO_GIT="no"; shift;;
    --claude-md) DO_CLAUDE_MD="yes"; shift;;
    --no-claude-md) DO_CLAUDE_MD="no"; shift;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$LA_DIR/com.recall.distill.plist"
RULE="────────────────────────────────────────────────────"

# ---- colors (off when piped or NO_COLOR) ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  MAG=$'\033[35m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; D=""; R=""; MAG=""; GRN=""; YEL=""; RED=""; CYN=""
fi

# ---- output helpers ----
step() { printf '\n  %s▸ %s%s\n' "$B$MAG" "$1" "$R"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$R" "$1"; }
info() { printf '    %s%s%s\n' "$D" "$1" "$R"; }
warn() { printf '    %s!%s %s\n' "$YEL" "$R" "$1" >&2; }
die()  { printf '\n  %s✗ %s%s\n\n' "$RED$B" "$1" "$R" >&2; exit 1; }

# ---- interactive prompts (read from the terminal; fall back to defaults) ----
interactive() { [ "$ASSUME_YES" -eq 0 ] && [ -e /dev/tty ]; }
ask() { # ask "question" "default" -> echoes the answer
  local q="$1" d="$2" a
  if interactive; then
    printf '    %s?%s %s %s[%s]%s ' "$CYN" "$R" "$q" "$D" "$d" "$R" >/dev/tty
    IFS= read -r a </dev/tty || a=""
    [ -n "$a" ] && printf '%s' "$a" || printf '%s' "$d"
  else
    printf '%s' "$d"
  fi
}
confirm() { # confirm "question" "Y|N" (default) -> returns 0 (yes) / 1 (no)
  local q="$1" def="$2" a hint
  [ "$def" = "Y" ] && hint="Y/n" || hint="y/N"
  if ! interactive; then [ "$def" = "Y" ]; return; fi
  printf '    %s?%s %s %s[%s]%s ' "$CYN" "$R" "$q" "$D" "$hint" "$R" >/dev/tty
  IFS= read -r a </dev/tty || a=""
  [ -z "$a" ] && a="$def"
  case "$a" in [Yy]*) return 0;; *) return 1;; esac
}
expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#$HOME}";; "$HOME") printf '~';; *) printf '%s' "$1";; esac; }
clock12() { # clock12 H M -> "7:00pm"
  local h="$1" m="$2" ap=am h12="$1"
  [ "$h" -ge 12 ] && ap=pm; [ "$h" -gt 12 ] && h12=$((h-12)); [ "$h" -eq 0 ] && h12=12
  printf '%d:%02d%s' "$h12" "$m" "$ap"
}

# ---- banner ----
printf '\n  %s✦ recall%s  %ssetup%s\n' "$B$MAG" "$R" "$D" "$R"
printf '  %sself-improving memory for Claude Code%s\n' "$D" "$R"
printf '  %s%s%s\n' "$D" "$RULE" "$R"

# ---- 1. dependencies ----
step "Dependencies"
MISSING=""
for dep in claude jq git perl; do
  command -v "$dep" >/dev/null 2>&1 || MISSING="$MISSING $dep"
done
[ -n "$MISSING" ] && die "missing required tools:$MISSING — install them, then re-run"
ok "claude, jq, git, perl"

BASH_BIN=""
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -x "$b" ] && { BASH_BIN="$b"; break; }
done
if [ -z "$BASH_BIN" ] && command -v bash >/dev/null 2>&1; then
  if [ "$(bash -c 'echo ${BASH_VERSINFO[0]:-0}')" -ge 4 ]; then BASH_BIN="$(command -v bash)"; fi
fi
[ -n "$BASH_BIN" ] || die "need bash 4+ for the distill runner — run: brew install bash"
if command -v brew >/dev/null 2>&1; then HOMEBREW_BIN="$(brew --prefix)/bin"; else HOMEBREW_BIN="$(dirname "$BASH_BIN")"; fi
ok "bash $("$BASH_BIN" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}') ($BASH_BIN)"

# ---- 2. vault location ----
step "Vault"
if [ -z "$VAULT_DIR" ]; then
  if interactive; then
    info "recall keeps its knowledge in a recall/ folder inside a directory you choose."
    info "An existing Obsidian vault is perfect — it'll sync right alongside your notes."
    if confirm "Do you already have a vault or folder you'd like to use?" Y; then
      base="$(ask "Where is it?" "$(tilde "$HOME/Documents/Vault")")"
    else
      base="$(ask "Where should recall create it?" "$(tilde "$HOME/Documents/Vault")")"
    fi
    base="$(expand_tilde "$base")"
    VAULT_DIR="$base/recall"
  else
    VAULT_DIR="$HOME/Documents/Vault/recall"
  fi
fi
base="$(dirname "$VAULT_DIR")"
if [ ! -d "$base" ]; then
  confirm "$(tilde "$base") doesn't exist yet — create it?" Y || die "aborted"
fi
mkdir -p "$VAULT_DIR/sessions" \
         "$VAULT_DIR/knowledge/global" \
         "$VAULT_DIR/knowledge/projects" \
         "$VAULT_DIR/inbox"
[ -f "$VAULT_DIR/inbox/proposals.md" ] || printf '# Proposals\n\n' > "$VAULT_DIR/inbox/proposals.md"
ok "knowledge vault ready at $(tilde "$VAULT_DIR")"

# ---- 3. git: version + sync the distilled knowledge ----
step "Git"
GIT_ROOT="$(git -C "$VAULT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$GIT_ROOT" ]; then
  ok "tracked by git at $(tilde "$GIT_ROOT")"
  info "recall will commit + push what it learns here (works with the Obsidian Git plugin)."
elif [ "$DO_GIT" = "no" ]; then
  warn "not a git repo (--no-git): distilled knowledge won't be versioned or synced"
  GIT_ROOT="$VAULT_DIR"
else
  info "This folder isn't tracked by git yet. Versioning lets recall save and sync"
  info "what it learns over time, and roll back if anything looks off."
  if confirm "Set up git here? (Choose No if the Obsidian Git plugin already manages it)" Y; then
    git -C "$VAULT_DIR" init -q && ok "git repository created"
    GIT_ROOT="$VAULT_DIR"
  else
    GIT_ROOT="$VAULT_DIR"
    warn "skipped — set up git or the Obsidian Git plugin yourself to sync"
  fi
fi
if git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  IGNORE="$GIT_ROOT/.gitignore"
  for pat in ".distill-scratch/" ".distill.lock/" ".distill.log" ".distill.launchd.log"; do
    grep -qxF "$pat" "$IGNORE" 2>/dev/null || echo "$pat" >> "$IGNORE"
  done
  git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1 \
    || info "no remote set yet — nightly sync starts once you add one (the Obsidian Git plugin can also handle it)."
fi

# ---- 4. schedule ----
step "Schedule"
if [ "$DO_LAUNCHD" -eq 1 ] && interactive; then
  info "Each night, recall reviews the day's sessions and folds them into your vault."
  DISTILL_TIME="$(ask "What time should that happen? (24-hour HH:MM)" "$DISTILL_TIME")"
fi
case "$DISTILL_TIME" in
  [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9]) ;;
  *) die "invalid time '$DISTILL_TIME' — use 24h HH:MM (e.g. 19:00)";;
esac
HOUR=$((10#${DISTILL_TIME%%:*})); MINUTE=$((10#${DISTILL_TIME##*:}))
{ [ "$HOUR" -ge 0 ] && [ "$HOUR" -le 23 ] && [ "$MINUTE" -ge 0 ] && [ "$MINUTE" -le 59 ]; } \
  || die "invalid time '$DISTILL_TIME' — hour 0-23, minute 0-59"
SCHED_TXT="nightly · $(clock12 "$HOUR" "$MINUTE")"
if [ "$DO_LAUNCHD" -eq 1 ]; then ok "$SCHED_TXT"; else info "no schedule (--no-launchd) — you'll run distill yourself"; fi

# ---- 5. render templates ----
render() { sed \
  -e "s#__REPO_DIR__#$REPO_DIR#g" \
  -e "s#__VAULT_DIR__#$VAULT_DIR#g" \
  -e "s#__BASH__#$BASH_BIN#g" \
  -e "s#__HOMEBREW_BIN__#$HOMEBREW_BIN#g" \
  -e "s#__HOME__#$HOME#g" \
  -e "s#__HOUR__#$HOUR#g" \
  -e "s#__MINUTE__#$MINUTE#g" \
  "$1"; }

# ---- 6. merge hooks into settings.json (idempotent, preserves other hooks) ----
step "Hooks"
HOOKS_GEN="$REPO_DIR/install/recall-hooks.generated.json"
render "$REPO_DIR/install/recall-hooks.json.template" > "$HOOKS_GEN"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.recall-bak"
MERGED="$(jq -s '
  .[0] as $tpl | (.[1] // {}) as $cur |
  reduce ($tpl.hooks | keys[]) as $ev (
    $cur;
    .hooks[$ev] = (
      ((.hooks[$ev] // []) | map(select(
        ((.hooks // []) | any(.command | test("/(capture-session|inject-knowledge)\\.sh$"))) | not
      )))
      + $tpl.hooks[$ev]
    )
  )
' "$HOOKS_GEN" "$SETTINGS")" || die "jq merge failed — settings.json untouched (backup at $SETTINGS.recall-bak)"
printf '%s\n' "$MERGED" > "$SETTINGS"
ok "capture + retrieval hooks added to Claude Code"
info "your other hooks were left untouched · backup saved to $(tilde "$SETTINGS").recall-bak"

# ---- 7. global CLAUDE.md guidance (optional, idempotent) ----
step "Claude guidance"
recall_claude_block() { cat <<'BLOCK' | sed "s#__VAULT_DIR__#$VAULT_DIR#g"
<!-- BEGIN recall -->
## Knowledge vault (recall)
Durable, learned knowledge for your projects lives at `__VAULT_DIR__/knowledge/`
and is injected into each session automatically by the recall SessionStart hook
(global index + the current project's index). Read full notes on demand — don't
bulk-load them.

The nightly distill is the sole writer: treat the vault as read-only during
sessions, and verify a note still matches reality before relying on it. Anything
you learn is captured automatically and folded in by distill — never hand-edit
the vault.
<!-- END recall -->
BLOCK
}
add_claude_md() {
  mkdir -p "$(dirname "$CLAUDE_MD")"
  [ -f "$CLAUDE_MD" ] || : > "$CLAUDE_MD"
  perl -0pi -e 's/\n*<!-- BEGIN recall -->.*?<!-- END recall -->\n*/\n/s' "$CLAUDE_MD"
  { [ -s "$CLAUDE_MD" ] && printf '\n'; recall_claude_block; } >> "$CLAUDE_MD"
  ok "added a recall note to $(tilde "$CLAUDE_MD")"
}
if [ "$DO_CLAUDE_MD" = "no" ]; then
  info "skipped (--no-claude-md)"
elif [ "$DO_CLAUDE_MD" = "yes" ] || \
     confirm "Add a short note to your global CLAUDE.md so Claude knows how to use the vault?" Y; then
  add_claude_md
else
  info "skipped — re-run the installer anytime to add it"
fi

# ---- 8. launchd job ----
step "Scheduler"
if [ "$DO_LAUNCHD" -eq 1 ]; then
  PLIST_GEN="$REPO_DIR/install/com.recall.distill.generated.plist"
  render "$REPO_DIR/install/com.recall.distill.plist.template" > "$PLIST_GEN"
  mkdir -p "$LA_DIR"
  cp "$PLIST_GEN" "$PLIST_DST"
  launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
  if launchctl load "$PLIST_DST" >/dev/null 2>&1; then
    ok "scheduled — recall will run $SCHED_TXT"
  else
    warn "couldn't schedule it automatically; load it with: launchctl load $(tilde "$PLIST_DST")"
  fi
else
  info "skipped (--no-launchd) · run it yourself with $(tilde "$REPO_DIR")/distill/run-distill.sh"
fi

# ---- summary ----
[ "$DO_LAUNCHD" -eq 1 ] && sched_line="$SCHED_TXT" || sched_line="manual (you run distill)"
[ "$DO_CLAUDE_MD" = "no" ] && cmd_line="(skipped)" || cmd_line="$(tilde "$CLAUDE_MD")"
RECALL_CLI="$(tilde "$REPO_DIR")/dashboard/recall.sh"
printf '\n  %s%s%s\n' "$D" "$RULE" "$R"
printf '  %s✓ recall is ready%s\n\n' "$GRN$B" "$R"
printf '    %s%-9s%s %s\n' "$D" "vault" "$R" "$(tilde "$VAULT_DIR")"
printf '    %s%-9s%s %s\n' "$D" "schedule" "$R" "$sched_line"
printf '    %s%-9s%s %s\n' "$D" "hooks" "$R" "$(tilde "$SETTINGS")"
printf '    %s%-9s%s %s\n' "$D" "guidance" "$R" "$cmd_line"

printf '\n  %sWhat happens now%s\n' "$B" "$R"
printf '    %s1.%s Start a new Claude Code session (or restart it) to turn on capture.\n' "$MAG" "$R"
printf '    %s2.%s Work as usual — recall quietly saves each session.\n' "$MAG" "$R"
if [ "$DO_LAUNCHD" -eq 1 ]; then
  printf '    %s3.%s Every night (%s) it distills those sessions into your vault\n' "$MAG" "$R" "$SCHED_TXT"
  printf '       and feeds what it learns back into future sessions.\n'
else
  printf '    %s3.%s Run a distill pass whenever you like: %s%s/distill/run-distill.sh%s\n' "$MAG" "$R" "$D" "$(tilde "$REPO_DIR")" "$R"
fi
printf '\n  %sCheck on it anytime%s  %s%s status%s   %s(tip: alias recall=%s)%s\n\n' \
  "$B" "$R" "$CYN" "$RECALL_CLI" "$R" "$D" "$RECALL_CLI" "$R"
