# Git conventions

A pointer target: `_global.md` carries one line about git, and an agent reads this file only
when the task is actually about branches, commits, or history. See `docs/layered-rules.md` for
the pattern.

Replace the contents below with your own conventions. They are written out rather than left
blank so you can see the level of specificity that works: each rule is checkable by an agent
without asking you a follow-up question.

## Branching

- Say if direct pushes to the default branch are allowed. If they are not, state it as an
  absolute — an agent will treat "prefer a branch" as permission to skip the branch when it
  judges the change small.
- State the branch naming scheme, if you have one, as a pattern rather than an example.

## Commit messages

- State the mood and the subject-length limit as numbers ("imperative, subject <= 50 chars"),
  not adjectives. "Concise" is not a rule an agent can verify against.
- If you use Conventional Commits, list the exact prefixes you accept. An open-ended list
  invites invented ones.
- Say what the body is for. The useful instruction is usually "explain why, not what" plus a
  wrap width.
- State your position on tool attribution and co-author trailers explicitly — agents add them
  by default, so silence reads as consent.

## History

- Say which of merge commits, squashes, or rebases you expect, and if force-pushing a shared
  branch is ever acceptable.
- Say what an agent must never do without asking: rewriting pushed history and deleting
  branches are the two worth naming, because both are hard to undo.

## Scope of these rules

Say if these conventions apply to every repository or only some. If your work and
personal repositories differ, that difference belongs in `_machine.md`, not here — this file
is machine-independent.
