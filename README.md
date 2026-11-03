# example-agent-rules

A template for one cross-agent rulebook: write your rules once, and every coding agent on the
machine reads them from the same source. Works across several machines, each keeping its own
local identity, and across several agents, each wired through its own supported surface.

This repository ships the mechanism and leaves the rules to you. `_global.md` and the files in
`docs/` are scaffolds — headings, guidance on what belongs in each section, and the reasoning
behind the structure. The install and check machinery is complete and working.

## Read order — the bootstrap contract

An agent starting a session in a repository that uses this rulebook reads, in this order:

1. **`AGENTS.md`** (generated) — the shared rules plus this machine's identity and paths.
   Loaded automatically by every wired agent; never edit it directly.
2. **`claude-extras.md`** — harness-specific rules, loaded on top of `AGENTS.md` by that
   harness only. Claude reads it via the `@`-import shim; Codex and Gemini never see it.
3. **The repository's own agent doc** — a project's `AGENTS.md`, `CLAUDE.md`, or `README.md`
   overrides the global rules where they conflict. Local context wins.
4. **A `docs/*.md` pointer target** — only when the task calls for it, and only by following a
   pointer line from one of the layers above. Never read speculatively.

The contract in one sentence: layers 1 and 2 are always loaded and must stay short, layer 3 is
whatever the project says, and layer 4 costs nothing until it is needed. `docs/layered-rules.md`
explains how to decide which layer a given rule belongs in.

## Layout

```
_global.md              shared rules, identical on every machine       (source, committed)
_machine.md             this machine's identity, paths, comms index    (source, gitignored)
_machine.example.md     template for a new machine's _machine.md
claude-extras.md        harness-only rules, loaded on top of AGENTS.md
assemble.sh             _global.md + _machine.md -> AGENTS.md
AGENTS.md               the generated rulebook                         (gitignored)
install.sh              wire the repo into every detected agent
lib/common.sh           logging, locking, atomic writes, backups
lib/profile.sh          read the per-machine profile; gate optional sync
lib/manifest.sh         track the links and copies this repo owns; fail-closed
lib/adapters.sh         one function per agent, per-agent surfaces only
skills/                 one directory per skill, synced to every agent
plugins/                example plugin/marketplace config: upstream sources only
capabilities/matrix.tsv what each adapter actually installs
docs/                   pointer targets, read on demand
CONTRIBUTING.md         how to contribute to the template itself (issues, PRs, gates)
.github/workflows/      CI: size budget, pointer targets, secret guard
```

## Quick start

```sh
git clone <this-repo> ~/.agent-rules
cd ~/.agent-rules
cp _machine.example.md _machine.md   # then edit it for this machine
./install.sh --dry-run               # see exactly what would change
./install.sh                         # wire it up
./install.sh check                   # verify, and print the capability matrix
```

Then write your rules into `_global.md`, run `bash assemble.sh`, and open a new agent session.

## Assembling

`AGENTS.md` is generated, never edited:

- `_global.md` — rules identical on every machine. Committed.
- `_machine.md` — this machine's identity, paths, active work, and comms index. Gitignored, so
  each machine keeps its own and nothing personal is ever published.

Run `bash assemble.sh` after editing either. `install.sh` runs it for you. If `_machine.md` is
absent — a fresh clone, or CI — assemble falls back to `_machine.example.md` so the build
always works.

## Installing

```sh
./install.sh            # wire the repo into every detected agent
./install.sh --dry-run  # print intended actions; change nothing, anywhere
./install.sh check      # verify wiring; nonzero exit if anything is wrong
```

Each agent is wired through the surface it actually documents:

- **Claude** — `~/.claude/CLAUDE.md` becomes a two-line shim importing `AGENTS.md` and then
  `claude-extras.md`.
- **Codex** — `~/.codex/AGENTS.md` is symlinked to the generated `AGENTS.md`.
- **Gemini** — `~/.gemini/GEMINI.md` is symlinked to the same file.

Codex skills are linked into `~/.agents/skills`; Claude skills remain in `~/.claude/skills`.
On a personal-profile install, owned legacy `~/.codex/skills` links move only after the new
link deploys successfully. Foreign links and regular files in the legacy location survive.
Migration evidence under `${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/migrations/codex-skills/`
records the prior manifest entries, both targets and any collision backup before legacy cleanup.
To reverse one completed migration, use the exact record directory printed by install:
`./install.sh rollback-codex-skills RECORD`. Run from the same checkout, HOME, state and backup
configuration. This restores the old link, prior manifest records and any displaced destination.
Reversal refuses changed destinations or ownership and missing backups. A subsequent install
migrates forward again. Fresh installations have no migration record. A work profile removes
still-owned links in both Codex locations. Check requires the new location; dry-run never migrates or writes evidence.

An agent that is not installed gets nothing and is reported as absent. An agent with no
documented surface for a feature has that gap recorded in `capabilities/matrix.tsv` rather than
worked around by guessing at a config format.

`install.sh` is **idempotent and non-destructive**. Anything already correct is left alone.
Anything in the way is *moved* to `~/.agent-rules-backup/`, never deleted. A stray `~/CLAUDE.md`
or `~/AGENTS.md` at the home root is relocated there too, because it double-loads the global
rules and the two copies then drift apart.

Artifacts this repo deploys are tracked in a per-machine manifest under
`~/.local/state/agent-rules/`, never in the repo. That is what lets `check` distinguish a link
or copy it owns from a file you put there yourself, which it will not touch. `check` only
reports what it finds — it never repairs anything, which is what makes it safe to run anywhere,
including CI or someone else's machine. Repair is `install.sh`'s job, on the next run.

Every deployed artifact is either a **symlink**, which cannot drift because it has no content of
its own, or a **tracked copy**, whose SHA-256 is recorded at deploy time. Only one artifact needs
the second treatment — the harness shim, whose text is generated from this machine's repo path,
so there is no repo file to point at. Edit a deployed copy by hand and `check` fails with the
path and the reason; `install.sh` then restores it from source, backing up your edited version
rather than discarding it. `docs/provenance.md` explains why a copy with no live link to its
origin is the failure this design is built around.

## Profiles

Optional sync is gated per machine by a marker comment in `_machine.md`:

```
<!-- agent-rules:profile=personal -->
```

| profile | rulebook | skills |
|---|---|---|
| `work` (default) | yes | no |
| `personal` | yes | yes |

Setting the `PROFILE` environment variable (`PROFILE=personal ./install.sh`) overrides the
marker comment for that one invocation — a documented, explicit escape hatch for a one-off run,
not a replacement for editing `_machine.md`. Leave it unset to use the marker.

Anything missing, unrecognized, or malformed resolves to `work` — the least-privilege profile.
A shared or centrally-managed machine that never edits `_machine.md` therefore gets the rules
and nothing else, which is the safe direction to fail.

## Adding a rule

Edit the source, never `AGENTS.md`:

| Rule kind | Edit | Loads |
|---|---|---|
| Universal | `_global.md` | always — keep it lean |
| Machine-specific | `_machine.md` | always, this machine only |
| Harness-specific | `claude-extras.md` | that harness only |
| Long or situational | `docs/<topic>.md` + a pointer line | on demand |

Then run `bash assemble.sh`. `docs/layered-rules.md` covers how to choose, and what to do when
a rule looks like it belongs in two places.

## Adding an adapter

Keep the shared intent in `AGENTS.md` and `skills/`. Add a row to `capabilities/matrix.tsv`
describing what the agent can and cannot take, then add install and check functions to
`lib/adapters.sh`. Three constraints: use `managed_link` for a file the agent reads directly
from the repo, or `managed_copy` when the content must be generated per-machine (as the Claude
shim's import lines are) so drift is still tracked; validate and atomically write any structured
config; and report an unsupported feature rather than inventing a file format for it.

## Plugins and provenance

Plugins and marketplaces are declared from an upstream source a fetch can update — never from a
local directory copied into place. A directory source works instantly and then silently stops
being maintained: it pins you to whatever was on disk that day, receives no upstream fixes, and
reports nothing to update, because a directory has nothing to fetch.

`plugins/marketplace.example.json` shows the upstream form in its three variants — default
branch, pinned tag, non-GitHub git URL. The vendored-directory pattern appears once, in
`plugins/README.md`, as a fenced code block labelled "do not copy this", kept outside the JSON
so it cannot be loaded by accident. Alongside it are the four things a local copy must record if
you truly need one: origin commit, reason, re-sync command *and its direction*, and what ends
its life. `docs/provenance.md` is the full rule.

## Related: the knowledge wiki

This rulebook pairs with [example-second-brain](https://github.com/het-sheth/example-second-brain), a companion template for a personal
knowledge wiki that is plain Markdown plus one validator. The two split cleanly: this repo is
the behavior layer, loaded into every session and therefore kept short; the wiki is the
knowledge store, read only when a task needs it and free to grow. They join through one line in
your `_machine.md` **Paths** section naming the wiki clone, which is what makes an agent consult
it instead of guessing.

`docs/composing.md` **in that repo** is the full version: what belongs on which side, both
pointers, and the order to install them in (this one first — it is what makes every later
session read a repo's agent doc before searching).

## CI

`.github/workflows/lint.yml` runs on every push and pull request:

- **Size budget** — `AGENTS.md` must stay under 100 lines. It loads into every session, so
  length is a cost paid on every task; the budget is what forces detail into `docs/`.
- **Pointer targets** — every `docs/*.md` file named by a pointer line must exist.
- **Secret guard** — refuses tracked PEM keys, credential filenames, and binary keystores, and
  fails if a gitignored per-machine file has been force-added.
- **Syntax check and dry-run** — every shell file parses, and `install.sh --dry-run` provably
  changes nothing in a throwaway `HOME` or in the repo.

Fixes and features for the template itself go through `CONTRIBUTING.md` — issues, pull
requests, and the gates to run. The rules your rulebook contains are yours to write; agents
load the assembled `AGENTS.md` automatically.

## Roadmap (v2)

- **Audience profiles.** Today the profile marker in `_machine.md` is binary — work/personal —
  and gates only what `install.sh` places. v2 generalizes it to N named profiles with per-profile
  rule files: `_global.md` slims down to the core that is true for *everyone*, and
  `profiles/<name>.md` holds the rules only that audience loads. `assemble.sh` concatenates
  core + the machine's profile, so each machine gets an `AGENTS.md` sized for its owner. A
  profile is a scope, and in this repo scopes are files — which also gives per-profile ownership
  (review rules per path) for free. Motivating case: an organization where one giant prompt is
  loaded by every employee — the "rule in too broad a layer" failure at company scale. Per-team
  profiles (an engineering assembly vs a sales assembly over a small shared core) are the layered
  alternative, and each team owns its file. Solo users get the same feature as role profiles
  (day-job vs open-source-maintainer). Scope cap: profiles stay additive concatenation over one
  manifest schema; CI exercises the canonical two, not the full matrix. Out of scope even in v2:
  org distribution (fleet install, update push, attestation) — that is a different product this
  template can only inspire.
- **Paths with embedded newlines** are unsupported by the manifest format — a documented
  limitation, not a planned fix, unless real use surfaces it.
