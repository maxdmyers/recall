# recall

A self-improving layer for Claude Code: it learns from your sessions, retains
knowledge in a vault, and proposes skills/automations from recurring patterns.

This repo holds the **machinery** (hooks, distill prompt + runner, dashboard,
install config). The **knowledge** lives in a separate vault directory,
partitioned by project — kept out of this repo entirely.

```
capture (Stop hook) ──▶ vault/sessions ──▶ distill (nightly) ──▶ vault/knowledge
                                                       │
        retrieve (SessionStart hook) ◀────────────────┘
                                                       └──▶ inbox/proposals.md ──▶ you approve ──▶ skills
```

## How it works

1. **Capture** — `hooks/capture-session.sh`, wired to Claude Code's `Stop` hook.
   On each session end it writes a raw dump (cwd, project, git diff stat,
   transcript pointer) to the vault. Pure shell + jq, ~zero tokens, never blocks.
2. **Distill** — `distill/run-distill.sh`, a nightly launchd job. Thins each new
   transcript, runs a headless Claude pass to update `knowledge/`, refreshes the
   indexes, and appends pattern observations to `inbox/proposals.md`. Skips (costs
   $0) when there's nothing new.
3. **Retrieve** — `hooks/inject-knowledge.sh`, wired to the `SessionStart` hook.
   Injects the global + per-project knowledge indexes as background context so
   they survive `/clear` and auto-compact.
4. **Gate** — distill only *proposes* into `inbox/proposals.md`. Nothing
   auto-promotes to a skill until you approve it.
5. **Dashboard** — `dashboard/recall.sh` (status CLI) and `build-dashboard.sh`
   (self-contained HTML). `recall.sh open` rebuilds and opens it.

## Prerequisites

- **macOS** (the scheduler uses launchd; the scripts assume BSD `date`/`stat`).
- **[Claude Code](https://claude.com/claude-code)** — the `claude` CLI on your `PATH`.
- **Homebrew bash 4+** — `brew install bash` (system `/bin/bash` is 3.2 and lacks `mapfile`).
- **jq**, **git**, **perl** — `jq` via `brew install jq`; `git`/`perl` ship with macOS.

## Install

Clone the repo **anywhere you like** — `~/Sites/recall` below is just an example;
`~/dev/recall`, `~/code/recall`, etc. are all fine. The installer locates itself,
so the repo path is never hardcoded.

```sh
git clone <this-repo> ~/Sites/recall   # or wherever you prefer
cd ~/Sites/recall
./install/install.sh                    # interactive
```

The installer is **interactive** and will ask:

- **where the vault lives** — point it at an existing Obsidian vault (recall lives
  in a `recall/` subfolder, syncing alongside your notes) or let it create one;
- **whether to init git** — only if the chosen directory isn't already a repo, and
  it offers to skip if you manage git via the **obsidian-git** plugin instead;
- **what time distill runs** — defaults to 19:00 (7pm);
- **whether to add a recall block to `~/.claude/CLAUDE.md`** — a short, idempotent
  note telling Claude the vault is auto-injected and read-only in sessions.

It then checks dependencies, scaffolds the vault, merges the two hooks into
`~/.claude/settings.json` **without** disturbing existing hooks (backup written to
`settings.json.recall-bak`), and loads the launchd job. Safe to re-run.

Non-interactive / scripted installs:

```sh
./install/install.sh -y                 # accept all defaults, no prompts
./install/install.sh --vault ~/notes/recall --time 22:30
./install/install.sh --no-git --no-launchd
```

| Flag | Effect |
|---|---|
| `-y`, `--yes` | No prompts; accept defaults. |
| `--vault DIR` | Set the recall data dir explicitly (skips the vault question). |
| `--time HH:MM` | Nightly distill time, 24h. |
| `--no-git` | Never `git init` the vault. |
| `--no-launchd` | Skip the scheduler (run distill by hand). |
| `--no-claude-md` | Don't add the recall block to `~/.claude/CLAUDE.md`. |

> For knowledge to sync across machines the vault needs a git `origin` remote (the
> nightly job commits + pushes) — or let the obsidian-git plugin handle sync.
> Without either, distilled knowledge is still saved locally.

## Configuration

All optional — sensible defaults apply.

| Variable | Default | What |
|---|---|---|
| `RECALL_VAULT` | `~/Documents/Vault/recall` | Vault data dir (sessions, knowledge, inbox). |
| `RECALL_DISTILL_THRESHOLD` | `1` | Min undistilled sessions before a nightly run does work. |
| `RECALL_DISTILL_MODEL` | `sonnet` | Model for the distill pass. |
| `RECALL_DISTILL_BUDGET` | `1.50` | Max USD per distill run. |
| `RECALL_DISTILL_STALE_MIN` | `30` | Skip sessions touched within this many minutes (still active). |
| `RECALL_INJECT_MAX_LINES` | `200` | Cap on lines of knowledge injected per session (mirrors Claude Code memory). |
| `RECALL_INJECT_MAX_BYTES` | `25600` | Cap on bytes injected per session; overflow is truncated with a visible marker. |

The installer bakes `RECALL_VAULT` into the launchd plist, so a custom `--vault`
is respected by the nightly job. For the hooks/CLI to use a custom vault in your
interactive shell, export `RECALL_VAULT` in your shell profile.

## Usage

```sh
dashboard/recall.sh            # overall health (default)
dashboard/recall.sh sessions   # per-project session breakdown
dashboard/recall.sh knowledge  # notes by area + recent additions
dashboard/recall.sh proposals  # pending + implemented proposals
dashboard/recall.sh distill    # recent runs (cost, duration, outcome)
dashboard/recall.sh open       # rebuild + open the HTML dashboard
dashboard/recall.sh update     # self-update (git pull + re-apply install)
dashboard/recall.sh all        # everything

distill/run-distill.sh         # run a distill pass now (instead of waiting for 7pm)
```

## Updating

recall runs in place from the clone, so updating is just pulling the latest code
and re-applying the install (to pick up any changed hook/launchd templates):

```sh
dashboard/recall.sh update
```

This does `git pull --ff-only` then re-runs `install.sh` non-interactively using
the settings saved at install time (`<vault>/.recall-install`). The installed
version is shown by `recall.sh status` and in the dashboard footer; when your
clone is behind its remote, both surface an "update available" hint (the nightly
distill refreshes that check).

## Vault layout

```
<RECALL_VAULT>/                 default: ~/Documents/Vault/recall
  sessions/                     raw dumps, tagged by project
  knowledge/
    global/        <topic>.md   cross-project
    projects/<proj>/<topic>.md  project-specific
  inbox/proposals.md            skill/automation candidates (you approve)
  dashboard.html                generated dashboard
```

## Scoping: global + per-project

Knowledge and skills land at the narrowest scope that fits, and promote to global
only when a pattern generalizes.

- Pattern in **one** project → project-local skill (`<proj>/.claude/skills/`)
- Pattern across **≥2** projects → global skill (`~/.claude/skills/`)

## Design decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Knowledge store | **Hybrid** | Tiny always-on index → on-demand vault reads. Flat per-session token cost as knowledge grows. |
| Capture | **Auto Stop hook, raw dump** | Pure shell, no LLM call (~zero tokens), never forgets. Summarizing deferred to distill. |
| Automation gate | **Human-approval** | Distill only *proposes* into an inbox. Nothing auto-promotes until trusted. |
| Project identity | **git repo root**, else launch dir | Subdirs of one repo = same project; loose folders scoped to launch dir. |

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.recall.distill.plist
rm ~/Library/LaunchAgents/com.recall.distill.plist
# then remove the two recall entries from ~/.claude/settings.json
# (restore ~/.claude/settings.json.recall-bak if you want the pre-install state)
```

The vault is never touched by uninstall — delete `~/Documents/Vault/recall`
yourself if you want the captured data gone.

## Inspiration

recall was inspired by Andrej Karpathy's
[**LLM Wiki**](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f):
the idea that instead of re-deriving answers from raw sources every time, an LLM
should incrementally maintain a *persistent, compounding* markdown knowledge base —
cross-referenced notes that build up over time, with the tedious bookkeeping left
to the model.

recall applies that loop to Claude Code, with the same three layers Karpathy
describes — **raw sources → wiki → schema**:

- **raw sources** → captured session dumps (`sessions/`)
- **the wiki** → the distilled, cross-linked (`[[...]]`) knowledge vault (`knowledge/`)
- **the schema** → the distill prompt + indexes that govern how the wiki is maintained

The nightly **distill** pass is what does the bookkeeping: reading the day's raw
sessions and folding them into the wiki so each new session starts from accumulated
knowledge rather than cold.
