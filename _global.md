# Agent Rules — Global

Rules that are identical on every machine. `assemble.sh` concatenates this file with
`_machine.md` to produce `AGENTS.md`, which every agent reads.

Everything under "Your rules" below is a scaffold: the section headings and the note under each
are the template's; the rules themselves are yours to write. Delete a section you do not want.
Keep this file short — it loads into every session. Anything long goes in `docs/` behind a
pointer line.

## Bootstrap
- Read the nearest `AGENTS.md` (or the repo's own agent doc) before searching; never grep an
  entire home directory.
- Paths, hostnames, and identities differ per machine — take them from `_machine.md`, never
  from memory or from another machine's rules.

## Off-limits — never read or write
- `~/.ssh` `~/.aws` `~/.kube` `~/.gnupg` `~/.config/gh` `~/.secrets`
- Any file matching `*.pem` `*.key` `.env` `.env.*` `*secret*` `*private*key*` `client_secret*`
- Anything listed under "Sensitive — ask before reading" in `_machine.md`.
- If a file looks like credentials or personal legal documents, stop and ask.

## Provenance — upstream over vendored
- Declare plugins, marketplaces, and shared rules from an upstream source a fetch can update.
  Never vendor a copy for convenience: a copy has no live link to its origin, so it drifts and
  never receives upstream fixes, and neither failure announces itself.
- A copy you genuinely must keep is unfinished until it records four things: origin commit,
  reason, the exact re-sync command *and its direction*, and what ends its life.
- The rule, the escape hatch, and how install.sh enforces it -> `docs/provenance.md`

## Living instructions
Corrected twice on the same thing? The rules file is wrong — fix the file instead of
re-explaining in chat. Universal correction -> this file. Harness-specific correction -> that
harness's extras file. Machine fact -> `_machine.md`. Rationale -> `docs/layered-rules.md`

## Your rules — Git
Write your branch, commit-message, and review conventions here; keep the long form in
`docs/git.md` and `docs/pr-reviews.md` and leave a pointer line to each.

## Your rules — Working
Write how you want an agent to verify its work (tests, linters, exit codes), when to plan
before coding, and what needs approval before it starts.

## Your rules — Output style
Write how you want answers formatted: length, structure, what to lead with, and the cases
where the default is allowed to break.
