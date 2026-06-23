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
#
# Clone this repo wherever you like — the installer locates itself, so the repo
# path is not hardcoded anywhere. Runs under system bash 3.2 (no bash-4 features).

set -uo pipefail

# ---- args / defaults ----
VAULT_DIR="${RECALL_VAULT:-}"     # empty => ask (or default) below
DISTILL_TIME="19:00"
DO_LAUNCHD=1
DO_GIT="auto"                     # auto = init if missing (ask first); no = never
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_DIR="$2"; shift 2;;
    --time) DISTILL_TIME="$2"; shift 2;;
    --no-launchd) DO_LAUNCHD=0; shift;;
    --no-git) DO_GIT="no"; shift;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$LA_DIR/com.recall.distill.plist"

say()  { printf '\033[1;35mrecall\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mrecall\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mrecall\033[0m %s\n' "$*" >&2; exit 1; }

# ---- interactive helpers (read from the terminal; fall back to defaults) ----
interactive() { [ "$ASSUME_YES" -eq 0 ] && [ -e /dev/tty ]; }
ask() { # ask "prompt" "default" -> echoes the answer
  local p="$1" d="$2" a
  if interactive; then
    printf '%s' "$p" >/dev/tty; IFS= read -r a </dev/tty || a=""
    [ -n "$a" ] && printf '%s' "$a" || printf '%s' "$d"
  else
    printf '%s' "$d"
  fi
}
confirm() { # confirm "prompt" "Y|N" (default) -> returns 0 (yes) / 1 (no)
  local p="$1" def="$2" a
  if ! interactive; then [ "$def" = "Y" ]; return; fi
  printf '%s' "$p" >/dev/tty; IFS= read -r a </dev/tty || a=""
  [ -z "$a" ] && a="$def"
  case "$a" in [Yy]*) return 0;; *) return 1;; esac
}
expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

# ---- 1. dependency check ----
say "checking dependencies…"
MISSING=""
for dep in claude jq git perl; do
  command -v "$dep" >/dev/null 2>&1 || MISSING="$MISSING $dep"
done
[ -n "$MISSING" ] && die "missing required tools:$MISSING (install them, then re-run)"

BASH_BIN=""
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -x "$b" ] && { BASH_BIN="$b"; break; }
done
if [ -z "$BASH_BIN" ] && command -v bash >/dev/null 2>&1; then
  if [ "$(bash -c 'echo ${BASH_VERSINFO[0]:-0}')" -ge 4 ]; then BASH_BIN="$(command -v bash)"; fi
fi
[ -n "$BASH_BIN" ] || die "need bash 4+ for the distill runner — run: brew install bash"

if command -v brew >/dev/null 2>&1; then HOMEBREW_BIN="$(brew --prefix)/bin"; else HOMEBREW_BIN="$(dirname "$BASH_BIN")"; fi
say "using bash: $BASH_BIN   homebrew bin: $HOMEBREW_BIN"

# ---- 2. choose the vault location ----
if [ -z "$VAULT_DIR" ]; then
  if interactive; then
    echo "" >/dev/tty
    echo "recall stores knowledge in a 'recall/' subfolder of a directory you pick." >/dev/tty
    echo "An existing Obsidian vault works great (and syncs alongside your notes)." >/dev/tty
    if confirm "Do you already have an Obsidian vault / folder to use? [Y/n] " Y; then
      base="$(ask "  Path to it [$HOME/Documents/Vault]: " "$HOME/Documents/Vault")"
    else
      base="$(ask "  Where should I create one? [$HOME/Documents/Vault]: " "$HOME/Documents/Vault")"
    fi
    base="$(expand_tilde "$base")"
    VAULT_DIR="$base/recall"
  else
    VAULT_DIR="$HOME/Documents/Vault/recall"
  fi
fi
base="$(dirname "$VAULT_DIR")"
if [ ! -d "$base" ]; then
  confirm "Directory $base doesn't exist. Create it? [Y/n] " Y || die "aborted"
fi
say "vault: $VAULT_DIR"
mkdir -p "$VAULT_DIR/sessions" \
         "$VAULT_DIR/knowledge/global" \
         "$VAULT_DIR/knowledge/projects" \
         "$VAULT_DIR/inbox"
[ -f "$VAULT_DIR/inbox/proposals.md" ] || printf '# Proposals\n\n' > "$VAULT_DIR/inbox/proposals.md"

# ---- 3. git: version + sync the distilled knowledge ----
GIT_ROOT="$(git -C "$VAULT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$GIT_ROOT" ]; then
  say "vault is already in a git repo: $GIT_ROOT (obsidian-git friendly)"
elif [ "$DO_GIT" = "no" ]; then
  warn "no git repo (--no-git): distill won't version or push knowledge"
  GIT_ROOT="$VAULT_DIR"
else
  if confirm "Not a git repo yet. Initialize one so distilled knowledge is versioned + pushable?
  (Say No if the obsidian-git plugin will manage git for this vault.) [Y/n] " Y; then
    git -C "$VAULT_DIR" init -q && say "initialized git repo at $VAULT_DIR"
    GIT_ROOT="$VAULT_DIR"
  else
    warn "skipped git init — set up git / obsidian-git yourself for versioning + sync"
    GIT_ROOT="$VAULT_DIR"
  fi
fi
# Keep runner scratch/lock/logs out of version control (only if it's a repo).
if git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  IGNORE="$GIT_ROOT/.gitignore"
  for pat in ".distill-scratch/" ".distill.lock/" ".distill.log" ".distill.launchd.log"; do
    grep -qxF "$pat" "$IGNORE" 2>/dev/null || echo "$pat" >> "$IGNORE"
  done
  git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1 || \
    warn "vault repo has no 'origin' remote — nightly 'git push' is skipped until you add one (the obsidian-git plugin can also handle sync)"
fi

# ---- 4. distill schedule ----
if [ "$DO_LAUNCHD" -eq 1 ] && interactive; then
  DISTILL_TIME="$(ask "What time should the nightly distill run? (24h HH:MM) [$DISTILL_TIME]: " "$DISTILL_TIME")"
fi
case "$DISTILL_TIME" in
  [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9]) ;;
  *) die "invalid time '$DISTILL_TIME' — use 24h HH:MM (e.g. 19:00)";;
esac
HOUR=$((10#${DISTILL_TIME%%:*})); MINUTE=$((10#${DISTILL_TIME##*:}))
{ [ "$HOUR" -ge 0 ] && [ "$HOUR" -le 23 ] && [ "$MINUTE" -ge 0 ] && [ "$MINUTE" -le 59 ]; } \
  || die "invalid time '$DISTILL_TIME' — hour 0-23, minute 0-59"

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

HOOKS_GEN="$REPO_DIR/install/recall-hooks.generated.json"
render "$REPO_DIR/install/recall-hooks.json.template" > "$HOOKS_GEN"

# ---- 6. merge hooks into settings.json (idempotent, preserves other hooks) ----
say "wiring hooks into $SETTINGS"
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
' "$HOOKS_GEN" "$SETTINGS")" || die "jq merge failed — settings.json left untouched (backup at $SETTINGS.recall-bak)"
printf '%s\n' "$MERGED" > "$SETTINGS"
say "hooks merged (backup: $SETTINGS.recall-bak)"

# ---- 7. launchd job ----
if [ "$DO_LAUNCHD" -eq 1 ]; then
  PLIST_GEN="$REPO_DIR/install/com.recall.distill.generated.plist"
  render "$REPO_DIR/install/com.recall.distill.plist.template" > "$PLIST_GEN"
  mkdir -p "$LA_DIR"
  cp "$PLIST_GEN" "$PLIST_DST"
  launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
  if launchctl load "$PLIST_DST" >/dev/null 2>&1; then
    say "launchd job loaded — distill runs nightly at $DISTILL_TIME"
  else
    warn "could not load launchd job; load it manually: launchctl load $PLIST_DST"
  fi
else
  say "skipping launchd (--no-launchd); run distill manually: $REPO_DIR/distill/run-distill.sh"
fi

say "done. Inspect state any time with: $REPO_DIR/dashboard/recall.sh status"
