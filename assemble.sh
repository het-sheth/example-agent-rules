#!/usr/bin/env bash
# Regenerate AGENTS.md from its two sources. Run after editing either one.
#
#   _global.md   shared rules, identical on every machine (committed)
#   _machine.md  this machine's identity and paths        (gitignored)
#
# install.sh runs this for you and then wires the generated AGENTS.md into each agent.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# _machine.md is per-machine and gitignored, so it is absent on a fresh clone and in CI.
# Fall back to the committed placeholder so assemble (and therefore CI) always works.
MACHINE="$DIR/_machine.md"
if [ ! -f "$MACHINE" ]; then
  MACHINE="$DIR/_machine.example.md"
  echo "note: _machine.md not found — using _machine.example.md (placeholder)" >&2
fi

# Write to a temp file in the same directory, then rename over the destination. A direct `>`
# redirection would truncate AGENTS.md before `cat` runs (so a missing source leaves an empty
# file despite `set -e`) and would write through a pre-existing symlink into whatever it points
# at instead of replacing it. mv -f replaces the destination itself, symlink or not, atomically.
TMP="$(mktemp "$DIR/.AGENTS.md.XXXXXX")"
# A failed cat/mv must not litter the checkout with temp files; the trap clears on success
# because mv removes the source. rm -f on a moved path is a no-op.
trap 'rm -f "$TMP"' EXIT
cat "$DIR/_global.md" <(echo) "$MACHINE" > "$TMP"
mv -f "$TMP" "$DIR/AGENTS.md"
echo "assembled AGENTS.md ($(wc -l < "$DIR/AGENTS.md" | tr -d ' ') lines)"
