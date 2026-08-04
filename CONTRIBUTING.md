# Contributing

This file covers contributions to the **template itself** — the install, assemble, and check
machinery. The rules a rulebook contains are yours, not ours: what belongs in `_global.md`,
`_machine.md`, and `docs/` is documented in the README and in `docs/layered-rules.md`, and
coding agents load the assembled `AGENTS.md` automatically.

## Issues

Open a GitHub issue. Describe the friction, not the fix — which machine, which agent surface,
and what you expected `install.sh` or `assemble.sh` to do. Reports that this template's own
instructions were unclear or wrong are just as welcome as feature ideas.

## Pull requests

1. Keep the scope small — one problem per PR.
2. Run the gates before opening it:

   ```bash
   bash tests/run.sh    # the full test suite
   ./assemble.sh        # AGENTS.md must stay under the 100-line budget
   ```

   CI (`.github/workflows/lint.yml`) additionally runs the secret guard, pointer-target check,
   and an `install.sh --dry-run` in a throwaway `HOME` — a PR that passes the two commands
   above and adds no tracked secrets should pass CI.

3. Shell changes keep the house style: fail closed, write through the atomic helpers in
   `lib/common.sh`, and never leave a manifest half-written.

## Scope

In scope: `install.sh`, `assemble.sh`, `lib/`, `tests/`, the CI workflow, and the docs. Out of
scope: anything on the README's v2 roadmap (cut on purpose), and the content of anyone's actual
rules — the scaffold stays a scaffold.
