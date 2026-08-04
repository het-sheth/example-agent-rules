# Agent Rules — <MACHINE NAME>

Copy to `_machine.md` (gitignored) and edit. Everything personal lives here and only here —
`_global.md` and `docs/` stay machine-agnostic and safe to publish.

## Machine identity
| Key         | Value                          |
|-------------|--------------------------------|
| Machine     | <hostname>                     |
| User        | <username>                     |
| Git forge   | <github.com or your host>      |
| Forge user  | <username on that forge>       |

## Paths
- `<path>` — <what lives here: work repos, personal repos, OSS clones, docs>

## Active work
- `<path>` — <one line: what this is and why an agent should know about it>

## Sensitive — ask before reading
- `<path>` — <why>

## Comms index
Empty on purpose. This is where you record the workspace identifiers an agent would otherwise
burn a search resolving — chat channel IDs, wiki page IDs, ticket project keys — one line each:
`- <#channel-or-page-name>  <ID>  <one-line purpose>`.

**Write-through:** when a session resolves an identifier that is not listed here, append it
before moving on, then re-run `assemble.sh`. That is what keeps the index growing instead of
every session re-resolving the same handful of IDs.

**Staleness:** these IDs are a cache, not a source of truth. Channels get archived, pages get
moved, projects get renamed. Treat a lookup failure as a stale entry — re-resolve it, correct
the line here, and continue. Prune entries you have stopped using; a long stale index costs
more context than it saves.

## Profile (controls what install.sh syncs)
<!-- agent-rules:profile=work -->
<!-- values:
     work      — shared rulebook only (least privilege; the default)
     personal  — shared rulebook plus skills sync -->
