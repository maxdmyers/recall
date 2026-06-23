#!/usr/bin/env bash
# recall :: installer (macOS)
# Renders the install templates for THIS machine, wires the Claude Code hooks
# into ~/.claude/settings.json (preserving any existing hooks), scaffolds the
# vault, and loads the nightly distill launchd job.
#
# Safe to re-run: hook merge and launchd load are idempotent.
#
#   ./install/install.sh [--vault DIR] [--no-launchd] [-h]
#
# Runs under system bash 3.2 — no bash-4 features here.

set -uo pipefail

# ---- args ----
VAULT_DIR="${RECALL_VAULT:-$HOME/Documents/Vault/recall}"
DO_LAUNCHD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_DIR="$2"; shift 2;;
    --no-launchd) DO_LAUNCHD=0; shift;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
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

# ---- 1. dependency check ----
say "checking dependencies…"
MISSING=""
for dep in claude jq git perl; do
  command -v "$dep" >/dev/null 2>&1 || MISSING="$MISSING $dep"
done
[ -n "$MISSING" ] && die "missing required tools:$MISSING (install them, then re-run)"

# Homebrew bash 4+ (system /bin/bash is 3.2; the distill runner needs mapfile).
BASH_BIN=""
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -x "$b" ] && { BASH_BIN="$b"; break; }
done
if [ -z "$BASH_BIN" ] && command -v bash >/dev/null 2>&1; then
  if [ "$(bash -c 'echo ${BASH_VERSINFO[0]:-0}')" -ge 4 ]; then BASH_BIN="$(command -v bash)"; fi
fi
[ -n "$BASH_BIN" ] || die "need bash 4+ for the distill runner — run: brew install bash"

# Homebrew bin dir (for the launchd PATH).
if command -v brew >/dev/null 2>&1; then
  HOMEBREW_BIN="$(brew --prefix)/bin"
else
  HOMEBREW_BIN="$(dirname "$BASH_BIN")"
fi
say "using bash: $BASH_BIN   homebrew bin: $HOMEBREW_BIN"

# ---- 2. scaffold the vault ----
say "vault: $VAULT_DIR"
mkdir -p "$VAULT_DIR/sessions" \
         "$VAULT_DIR/knowledge/global" \
         "$VAULT_DIR/knowledge/projects" \
         "$VAULT_DIR/inbox"
[ -f "$VAULT_DIR/inbox/proposals.md" ] || printf '# Proposals\n\n' > "$VAULT_DIR/inbox/proposals.md"

# Vault must be inside a git repo (distill commits + pushes knowledge nightly).
GIT_ROOT="$(git -C "$VAULT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$GIT_ROOT" ]; then
  warn "vault is not in a git repo — initializing one at $VAULT_DIR"
  git -C "$VAULT_DIR" init -q
  GIT_ROOT="$VAULT_DIR"
fi
# Keep runner scratch/lock out of version control.
IGNORE="$GIT_ROOT/.gitignore"
for pat in ".distill-scratch/" ".distill.lock/" ".distill.log" ".distill.launchd.log"; do
  grep -qxF "$pat" "$IGNORE" 2>/dev/null || echo "$pat" >> "$IGNORE"
done
git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1 || \
  warn "vault git repo has no 'origin' remote — nightly 'git push' will be skipped until you add one"

# ---- 3. render templates ----
render() { sed \
  -e "s#__REPO_DIR__#$REPO_DIR#g" \
  -e "s#__VAULT_DIR__#$VAULT_DIR#g" \
  -e "s#__BASH__#$BASH_BIN#g" \
  -e "s#__HOMEBREW_BIN__#$HOMEBREW_BIN#g" \
  -e "s#__HOME__#$HOME#g" \
  "$1"; }

HOOKS_GEN="$REPO_DIR/install/recall-hooks.generated.json"
render "$REPO_DIR/install/recall-hooks.json.template" > "$HOOKS_GEN"

# ---- 4. merge hooks into settings.json (idempotent, preserves other hooks) ----
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

# ---- 5. launchd job ----
if [ "$DO_LAUNCHD" -eq 1 ]; then
  PLIST_GEN="$REPO_DIR/install/com.recall.distill.generated.plist"
  render "$REPO_DIR/install/com.recall.distill.plist.template" > "$PLIST_GEN"
  mkdir -p "$LA_DIR"
  cp "$PLIST_GEN" "$PLIST_DST"
  launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
  if launchctl load "$PLIST_DST" >/dev/null 2>&1; then
    say "launchd job loaded — distill runs nightly at 7pm"
  else
    warn "could not load launchd job; load it manually: launchctl load $PLIST_DST"
  fi
else
  say "skipping launchd (--no-launchd); run distill manually: $REPO_DIR/distill/run-distill.sh"
fi

say "done. Inspect state any time with: $REPO_DIR/dashboard/recall.sh status"
