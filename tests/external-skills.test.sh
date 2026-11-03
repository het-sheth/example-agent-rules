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
  printf 'source root\n' > "$SOURCE/SKILL.md"
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
  tar -cf "$CASE/external.tar" -C "$CASE" home/.claude/skills home/.agents/skills state/agent-rules/links state/agent-rules/external-installed.tsv state/agent-rules/external-relinquished.tsv
}
source_repo
fresh empty
require run
require run check
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
select_source "$SECOND"
printf 'late file://%s/unavailable only\n' "$ROOT" >> "$BOOK/skills/claude-only.list"
printf 'file://%s/unavailable %s\n' "$ROOT" "$FIRST" >> "$BOOK/skills/external.lock"
reject
external_snapshot
require cmp -s "$CASE/before.tar" "$CASE/external.tar"
ok 'failure preparing a later source preserves every earlier-agent deployment and ownership record'

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
readonly_run() {
  local expected="$1" status=0
  shift
  tar -cf "$ROOT/readonly-before.tar" --exclude=./output -C "$CASE" .
  run "$@" || status=$?
  tar -cf "$ROOT/readonly-after.tar" --exclude=./output -C "$CASE" .
  require cmp -s "$ROOT/readonly-before.tar" "$ROOT/readonly-after.tar"
  if [ "$expected" = pass ]; then require test "$status" -eq 0
  else require test "$status" -ne 0; fi
}
fresh offline-check
select_source "$FIRST"
require run
TARGET_ONE="$(readlink "$CLAUDE")"
ENTRY="${TARGET_ONE%/portable}"
mv "$SOURCE" "$ROOT/source-offline"
readonly_run pass check
readonly_run pass --dry-run
ok 'offline valid-cache check and dry-run preserve the complete checkout, HOME, state and cache'
git -C "$ENTRY" config remote.origin.url file:///unavailable/source
readonly_run fail check
ok 'offline check rejects a cache with the wrong origin without repairing it'
git -C "$ENTRY" config remote.origin.url "$URL"
git -C "$ENTRY" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm drift
readonly_run fail check
git -C "$ENTRY" update-ref HEAD "$FIRST"
printf 'cache drift\n' >> "$ENTRY/portable/SKILL.md"
readonly_run fail check
git -C "$ENTRY" checkout -q -- portable/SKILL.md
ok 'offline check rejects wrong revision and dirty source content without writes'
mv "$ENTRY" "$ROOT/unavailable-cache"
readonly_run fail check
require absent "$ENTRY"
mv "$ROOT/unavailable-cache" "$ENTRY"
ok 'missing required cache fails offline check without preparation or cache creation'
cp -p "$MANIFEST" "$ROOT/saved-manifest"
awk -F '\t' -v p="$CLAUDE" '$2 != p' "$MANIFEST" > "$ROOT/changed-manifest"
cp "$ROOT/changed-manifest" "$MANIFEST"
readonly_run fail check
cp "$ROOT/saved-manifest" "$MANIFEST"
cp -p "$INSTALLED" "$ROOT/saved-installed"
: > "$INSTALLED"
readonly_run fail check
cp "$ROOT/saved-installed" "$INSTALLED"
ok 'check requires both installed selection and exact typed manifest ownership'
rm "$CLAUDE"
ln -s "$TARGET_ONE"$'\n' "$CLAUDE"
readonly_run fail check
rm "$CLAUDE"
ln -s "$TARGET_ONE" "$CLAUDE"
printf 'malformed state\n' > "$LOST"
readonly_run fail check
: > "$LOST"
mkdir "$XDG_STATE_HOME/agent-rules/.external-deploy.interrupted"
readonly_run fail check
readonly_run fail --dry-run
rmdir "$XDG_STATE_HOME/agent-rules/.external-deploy.interrupted"
ok 'retargeted links, malformed tombstones and recovery evidence fail check without mutation'
: > "$BOOK/skills/external.list"
readonly_run fail check
TEST_PROFILE=work readonly_run fail check
ok 'removed selections and profile disablement report stale installed state'
mv "$ROOT/source-offline" "$SOURCE"
TEST_PROFILE=work require run
printf 'claude\tportable\t%s\t%s\n' "$CLAUDE" "$TARGET_ONE" > "$LOST"
printf 'preserved user content\n' > "$CLAUDE"
TEST_PROFILE=work readonly_run fail check
rm "$CLAUDE"
TEST_PROFILE=work readonly_run fail check
: > "$LOST"
TEST_PROFILE=work readonly_run pass check
ok 'occupied and stale relinquished evidence is reported until reconciliation clears it'
fresh missing-dry-run
select_source "$FIRST"
mv "$SOURCE" "$ROOT/source-offline"
readonly_run pass --dry-run
require absent "$CACHE"
require absent "$XDG_STATE_HOME"
readonly_run fail check
require absent "$CACHE"
ok 'dry-run reports unavailable selected sources without fetching or creating cache/state'
printf 'malformed catalog\n' > "$BOOK/skills/external.list"
readonly_run fail --dry-run
TEST_PROFILE=work readonly_run pass --dry-run
TEST_PROFILE=work readonly_run fail check
require absent "$CACHE"
mv "$ROOT/source-offline" "$SOURCE"
ok 'dry-run validates enabled catalogs and disabled dry-run bypasses malformed catalogs'
fresh planner
select_source "$FIRST"
require run
PROFILE=personal bash -c '. "$1/install.sh"; external_skills_plan "$1" "$2"' _ "$BOOK" "$CACHE" > "$ROOT/plan.tsv"
require cmp -s "$ROOT/plan.tsv" "$INSTALLED"
if PROFILE=personal bash -c '. "$1/install.sh"; skills_dest_for() { printf "relative\n"; }; external_skills_plan "$1" "$2"' _ "$BOOK" "$CACHE" > "$ROOT/plan.tsv" 2> "$ROOT/plan-error"; then
  echo 'FAIL: offline planner accepted an invalid destination resolver'; exit 1
fi
require test ! -s "$ROOT/plan.tsv"
ok 'public offline planner returns the complete deployment schema and refuses invalid resolver output'
fresh root-path
printf 'root %s .\n' "$URL" > "$BOOK/skills/external.list"
printf '%s %s\n' "$URL" "$FIRST" > "$BOOK/skills/external.lock"
readonly_run pass --dry-run
require run
require test "$(cat "$HOME/.claude/skills/root/SKILL.md")" = 'source root'
readonly_run pass check
ok 'source-root selections share valid paths in dry-run, installation and offline check'
fresh failed-sort
select_source "$FIRST"
require run
: > "$BOOK/skills/external.list"
: > "$BOOK/skills/claude-only.list"
readonly_run fail check
mkdir "$CASE/bin"
printf '#!/usr/bin/env bash\nexit 23\n' > "$CASE/bin/sort"
chmod +x "$CASE/bin/sort"
PATH="$CASE/bin:$PATH" readonly_run fail check
ok 'failed selection sorting cannot turn stale installed state into a passing read-only check'
for unused in xdg-space override-space override-relative; do
  fresh "$unused"
  select_source "$FIRST"
  require run
  printf 'malformed catalog\n' > "$BOOK/skills/external.list"
  case "$unused" in
    xdg-space) export XDG_CACHE_HOME="$CASE/unused cache" ;;
    override-space) export AGENT_RULES_SKILL_CACHE="$CASE/unused cache" ;;
    override-relative) export AGENT_RULES_SKILL_CACHE=relative ;;
  esac
  TEST_PROFILE=work readonly_run fail check
  require grep -Fq 'external installed selection differs' "$CASE/output"
  TEST_PROFILE=work readonly_run pass --dry-run
  TEST_PROFILE=work require run
  require absent "$CLAUDE"
  require absent "$CODEX"
  require test ! -s "$INSTALLED"
  TEST_PROFILE=work readonly_run pass check
  TEST_PROFILE=work readonly_run pass --dry-run
  require absent "$CASE/unused cache"
  readonly_run fail --dry-run
  require grep -Fq 'external cache must be an absolute path without whitespace' "$CASE/output"
done
ok 'disabled install, check and dry-run ignore unused invalid caches while enabled caches remain restricted'
for location in default canonical-alias; do
  fresh "orphan-$location"
  select_source "$FIRST"
  if [ "$location" = canonical-alias ]; then
    mkdir "$CASE/physical-cache"
    ln -s "$CASE/physical-cache" "$CASE/cache-alias"
    export AGENT_RULES_SKILL_CACHE="$CASE/cache-alias"
  fi
  require run
  if [ "$location" = canonical-alias ]; then export AGENT_RULES_SKILL_CACHE=relative; fi
  printf 'malformed catalog\n' > "$BOOK/skills/external.list"
  : > "$INSTALLED"
  TEST_PROFILE=work readonly_run fail check
  require grep -Fq 'external manifest link lacks installed selection' "$CASE/output"
  rm "$INSTALLED"
  TEST_PROFILE=work readonly_run fail check
  require grep -Fq 'external manifest link lacks installed selection' "$CASE/output"
done
ok 'disabled check detects retained typed external links with empty or missing selection state independently of cache aliases or changed settings'
fresh local-control
mkdir "$BOOK/skills/local"
printf 'local skill\n' > "$BOOK/skills/local/SKILL.md"
require run
TEST_PROFILE=work readonly_run pass check
ok 'disabled orphan scan preserves existing handling of exact local skill targets, rule links and tracked copies'
printf '%s integration assertions passed\n' "$PASS"
