# Workspace layout — <MACHINE NAME>

Copy to `docs/workspace.md` (gitignored) and fill in this machine's real paths. It stays out of
git for the same reason `_machine.md` does: directory layouts leak employer names, client
names, and project names.

**One purpose per top-level code directory, and they do not mix.** The value to an agent is
that "where does this repo go" and "is this repo work or personal" become lookups instead of
guesses.

## `<path>` — work

<Which repositories live here, which forge and organization they come from.>

## `<path>` — personal

<Your own repositories; the account or namespace they belong to.>

## `<path>` — third-party

<Clones and forks of other people's code. Kept separate because an agent must never open a PR
against a repository you do not own.>

## `<path>` — documents

<Non-code material: notes, exports, generated reports.>

## Placing a new repository

- work -> `<path>`
- personal -> `<path>`
- third-party -> `<path>`
- documents -> `<path>`

## Multi-account git

If this machine talks to more than one git forge or account, describe the routing here: which
directory implies which account, and how the credential is selected. If it is single-account,
say so explicitly — that is the fact that stops an agent from looking for a rule that does not
exist.
