#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export PATH=/usr/bin:/bin
PASS=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fresh() {
  CASE="$ROOT/$1"
  export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" XDG_CACHE_HOME="$CASE/xdg-cache"
  export MANIFEST="$XDG_STATE_HOME/agent-rules/links" AGENT_RULES_BACKUP="$CASE/backups"
  unset AGENT_RULES_SKILL_CACHE
  BOOK="$CASE/book"
  CACHE="$XDG_CACHE_HOME/agent-rules/skills"
  INSTALLED="$XDG_STATE_HOME/agent-rules/external-installed.tsv"
  LOST="$XDG_STATE_HOME/agent-rules/external-relinquished.tsv"
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$BOOK/lib" "$BOOK/skills" "$BOOK/capabilities"
  cp "$REPO/install.sh" "$REPO/assemble.sh" "$REPO/_global.md" \
    "$REPO/_machine.example.md" "$REPO/claude-extras.md" "$BOOK/"
  cp "$REPO"/lib/*.sh "$BOOK/lib/"
  cp "$REPO"/skills/*.list "$REPO/skills/external.lock" "$BOOK/skills/"
  cp "$REPO/capabilities/matrix.tsv" "$BOOK/capabilities/"
  CLAUDE="$HOME/.claude/skills/portable" CODEX="$HOME/.agents/skills/portable"
}
run() { PROFILE="${TEST_PROFILE:-personal}" bash "$BOOK/install.sh" "$@" > "$CASE/output" 2>&1; }
require() { if ! "$@"; then echo "FAIL: $CASE: $*"; cat "$CASE/output"; exit 1; fi; }
reject() { if run "$@"; then echo "FAIL: unexpectedly accepted $*"; cat "$CASE/output"; exit 1; fi; }
link_is() { [ -L "$1" ] && readlink "$1" | cmp -s - <(printf '%s\n' "$2"); }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
source_repo() {
  SOURCE="$ROOT/source"
  mkdir -p "$SOURCE/portable" "$SOURCE/only"
  printf 'version one\n' > "$SOURCE/portable/SKILL.md"
  printf 'Claude only\n' > "$SOURCE/only/SKILL.md"
  git init -q --template= "$SOURCE"
  git -C "$SOURCE" add .
  git -C "$SOURCE" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm first
  FIRST="$(git -C "$SOURCE" rev-parse HEAD)"
  printf 'version two\n' > "$SOURCE/portable/SKILL.md"
  git -C "$SOURCE" add .
  git -C "$SOURCE" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm second
  SECOND="$(git -C "$SOURCE" rev-parse HEAD)"
  URL="file://$SOURCE"
}
select_source() {
  printf 'portable %s portable\n' "$URL" > "$BOOK/skills/external.list"
  printf 'only %s only\n' "$URL" > "$BOOK/skills/claude-only.list"
  printf '%s %s\n' "$URL" "$1" > "$BOOK/skills/external.lock"
}
external_snapshot() {
  tar -cf "$CASE/external.tar" -C "$CASE" home/.claude/skills home/.agents/skills state/agent-rules/external-installed.tsv state/agent-rules/external-relinquished.tsv
}
source_repo
fresh empty
require run
require test ! -s "$INSTALLED"
require absent "$CACHE"
ok 'empty shipped defaults install without a source cache'
fresh install
select_source "$FIRST"
require run
TARGET_ONE="$(readlink "$CLAUDE")"
require link_is "$CODEX" "$TARGET_ONE"
require test "$(cat "$CLAUDE/SKILL.md")" = 'version one'
require test -L "$HOME/.claude/skills/only"
require absent "$HOME/.agents/skills/only"
require test "$(wc -l < "$INSTALLED")" -eq 3
cp "$INSTALLED" "$CASE/expected"
require run
require cmp -s "$INSTALLED" "$CASE/expected"
ok 'portable and Claude-only union installs idempotently to the public destinations'
select_source "$SECOND"
require run
TARGET_TWO="$(readlink "$CLAUDE")"
require test "$TARGET_ONE" != "$TARGET_TWO"
require test "$(cat "$CLAUDE/SKILL.md")" = 'version two'
select_source "$FIRST"
mv "$SOURCE" "$ROOT/source-offline"
require run
require link_is "$CLAUDE" "$TARGET_ONE"
require test -d "$(dirname "$TARGET_TWO")"
mv "$ROOT/source-offline" "$SOURCE"
ok 'explicit lock advancement and retained-cache rollback work offline'
external_snapshot
cp "$CASE/external.tar" "$CASE/before.tar"
printf 'late %s missing\n' "$URL" >> "$BOOK/skills/claude-only.list"
reject
external_snapshot
require cmp -s "$CASE/before.tar" "$CASE/external.tar"
ok 'a later selected missing path fails before any external deployment changes'
select_source "$FIRST"
mkdir "$BOOK/skills/portable"
reject
require link_is "$CLAUDE" "$TARGET_ONE"
rmdir "$BOOK/skills/portable"
ok 'local and external name collisions refuse installation'
select_source "$SECOND"
mkdir "$CASE/bin"
cat > "$CASE/bin/ln" <<'SH'
#!/usr/bin/env bash
if [ "${*: -1}" = "$HOME/.agents/skills/portable" ]; then exit 1; fi
exec /usr/bin/ln "$@"
SH
chmod +x "$CASE/bin/ln"
cp "$INSTALLED" "$CASE/expected"
cp "$MANIFEST" "$CASE/manifest"
if PATH="$CASE/bin:$PATH" run; then echo 'FAIL: injected deployment accepted'; exit 1; fi
require link_is "$CLAUDE" "$TARGET_ONE"
require link_is "$CODEX" "$TARGET_ONE"
require cmp -s "$INSTALLED" "$CASE/expected"
require cmp -s "$MANIFEST" "$CASE/manifest"
ok 'second-agent deployment failure compensates both agent links and selection state'
select_source "$FIRST"
printf 'portable %s portable\nonly %s only\n' "$URL" "$URL" > "$BOOK/skills/claude-only.list"
: > "$BOOK/skills/external.list"
require run
require absent "$CODEX"
require link_is "$CLAUDE" "$TARGET_ONE"
printf 'malformed catalog\n' > "$BOOK/skills/external.list"
printf 'invalid lock\n' > "$BOOK/skills/external.lock"
TEST_PROFILE=work require run
require absent "$CLAUDE"
require test ! -s "$INSTALLED"
ok 'scope narrowing removes Codex and disabled profile bypasses malformed catalog cleanup'
fresh absent-agent
select_source "$FIRST"
rmdir "$HOME/.codex"
require run
require test -L "$CLAUDE"
require absent "$CODEX"
require test "$(wc -l < "$INSTALLED")" -eq 2
ok 'an absent agent has no external deployment'
fresh disabled
select_source "$FIRST"
printf 'malformed catalog\n' > "$BOOK/skills/external.list"
TEST_PROFILE=work require run
require absent "$CACHE"
require test ! -s "$INSTALLED"
ok 'disabled skills never parse or fetch malformed external sources'
fresh override
select_source "$FIRST"
export AGENT_RULES_SKILL_CACHE="$CASE/override"
require run
case "$(readlink "$CLAUDE")" in "$CASE/override/"*) ;; *) exit 1 ;; esac
require absent "$CACHE"
ok 'explicit cache override controls source identity location'
printf '%s integration assertions passed\n' "$PASS"
