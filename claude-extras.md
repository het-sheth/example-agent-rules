# Claude-only preferences

Imported by `~/.claude/CLAUDE.md` on top of the shared rulebook. Claude loads it; Codex and
Gemini never see it. See `docs/layered-rules.md` for why the split exists and how to decide
which layer a rule belongs in.

This file is a scaffold — the headings are the template's, the rules are yours. Add a section
per harness-specific concern; delete what you do not need. If you add another harness with its
own import surface, copy this file (e.g. `<harness>-extras.md`) and wire it in
`lib/adapters.sh` rather than piling harness-specific rules into `_global.md`.

## Explanation style
Claude-specific formatting of explanations — when to expand, when to stay terse. Only put it
here if the instruction depends on how Claude formats output; otherwise it belongs in
`_global.md` under Output style.

## Context management
When to clear the conversation, when to hand off to a fresh session, how much of a task to
attempt in one context. These are properties of the harness's session model, not of your work,
which is why they live here.

## Tool and slash-command notes
Per-command behaviour worth stating once: which command to prefer for a recurring task, what a
given slash command does in your setup, which tool is the wrong reflex for a job.

## Living instructions
Corrections that only apply to this harness go here rather than in `_global.md`, one bullet
each. State the failure and the rule that prevents it — the reason is what stops the same
mistake reappearing in a slightly different form.
