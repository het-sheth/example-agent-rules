# Pull requests and written communication

A pointer target, like `docs/git.md` — loaded when an agent is writing something a person will
read, not on every turn.

Replace the contents below with your own format. The one thing worth keeping whatever you
write: a stated *structure*. Agents produce reasonable prose and unreasonable organization, so
the structure is the part that needs specifying.

## Two audiences, one artifact

Anything both people and agents will read — PR descriptions, review comments, bug reports,
design feedback — has two readers with opposite needs. A person wants the verdict in thirty
seconds. An agent picking the work up later wants everything needed to act without asking a
follow-up question. Writing for one shortchanges the other, so write both, in two labelled
sections:

**For humans** — what changed, what was found, the verdict, and anything that needs a decision.
Short enough to read without scrolling.

**For agents** — methodology, reproduction steps, findings ordered by severity, coverage gaps,
and what was deliberately not done. Length is fine here; ambiguity is not.

## Specifying it well

- Name the sections exactly. An agent given "be thorough" will pad; an agent given a section
  list will fill the sections.
- Say what goes in the summary, not how long it should be. "The verdict and any blocking
  finding" is checkable; "brief" is not.
- Say what to do with uncertainty. Findings an agent is unsure about should be marked as such
  rather than dropped or asserted — decide which, and write it down.
- If review comments have a severity vocabulary, list the levels. An unlisted scale gets
  invented per review and becomes uncomparable.
