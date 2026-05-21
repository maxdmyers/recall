# agentic-os

A self-improving layer for Claude Code: it learns from sessions, retains knowledge
in an Obsidian vault, and proposes skills/automations from recurring patterns.

This repo holds the **machinery** (hooks, distill prompt + runner, install config).
The **knowledge** lives in a separate Obsidian vault, partitioned by project.

## Design decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Knowledge store | **Hybrid** | Tiny always-on native index → on-demand vault reads. Flat per-session token cost as knowledge grows. |
| Capture | **Auto Stop hook, raw dump** | Pure shell, no LLM call (~zero tokens), never forgets. Summarizing deferred to distill. |
| Automation gate | **Human-approval** | Distill only *proposes* into an inbox. Nothing auto-promotes until trusted. |
| First build | **Memory + learning core** | capture → distill → vault. Everything else needs accrued data first. |
| Project identity | **git repo root**, else launch dir | Subdirs of one repo = same project; loose folders scoped to launch dir. |

## Scoping: global + per-project

Knowledge and skills land at the narrowest scope that fits, promote to global only
when a pattern generalizes.

- Pattern in **one** project → project-local skill (`<proj>/.claude/skills/`)
- Pattern across **≥2** projects → global skill (`~/.claude/skills/`)

## Components

1. **Capture** — `hooks/capture-session.sh`, wired to Claude Code `Stop` hook. Writes a
   raw session dump (cwd, project, git diff stat, transcript pointer) to the vault.
2. **Distill** — `distill/` prompt + runner. **Local** cron/launchd job (needs to read
   `~/.claude/projects` transcripts + write the vault). Updates `knowledge/`, refreshes
   the native index, appends pattern observations to `inbox/proposals.md`.
3. **Retrieve** — two-tier native index: global `MEMORY.md` (every session) +
   per-project index (only in that project).
4. **Gate** — manual approval of `inbox/proposals.md` → skills / automations.

## Vault layout

```
<vault>/agentic-os/
  sessions/                       raw dumps, tagged by project
  knowledge/
    global/        <topic>.md     cross-project
    projects/<proj>/<topic>.md    project-specific
  inbox/proposals.md              skill/automation candidates (you approve)
```

## Status

Scaffolding. Capture hook next.
