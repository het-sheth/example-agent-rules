#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/state"
MANIFEST="$XDG_STATE_HOME/agent-rules/links"
BACKUP="$ROOT/backups"
mkdir -p "$HOME" "$ROOT/rules/skills" "$ROOT/cache/demo"
printf 'skill\n' > "$ROOT/cache/demo/SKILL.md"
printf 'demo https://example.invalid/source skills/demo\n' > "$ROOT/rules/skills/external.list"
printf 'https://example.invalid/source 1111111111111111111111111111111111111111\n' > "$ROOT/rules/skills/external.lock"
. "$REPO/lib/common.sh"
. "$REPO/lib/profile.sh"
. "$REPO/lib/manifest.sh"
. "$REPO/lib/adapters.sh"
. "$REPO/lib/external-skills.sh"
[ -f "$REPO/lib/external-deploy.sh" ] || { echo 'FAIL: deployment preflight unavailable'; exit 1; }
. "$REPO/lib/external-deploy.sh"
RULES="$ROOT/rules"
PLAN="$ROOT/desired.tsv"
CLAUDE="$HOME/.claude/skills/demo"
CODEX="$HOME/.agents/skills/demo"
PASS=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
row() { printf '%s\tdemo\t%s\t%s\n' "$1" "$2" "${3:-$ROOT/cache/demo}"; }
reject() {
  if "$@" > "$ROOT/out" 2> "$ROOT/err"; then
    printf 'FAIL: accepted invalid input: %s\n' "$*"; exit 1
  fi
  [ -s "$ROOT/err" ] && [ ! -s "$ROOT/out" ] || exit 1
}
row claude "$CLAUDE" > "$PLAN"
row codex "$CODEX" >> "$PLAN"
_external_deploy_plan "$RULES" "$PLAN"
[ "${#_ed_paths[@]}" -eq 2 ] && [ ! -e "$XDG_STATE_HOME" ] && [ ! -e "$HOME/.claude" ] || exit 1
ok 'preflight accepts a complete both-agent plan without mutation'
for kind in duplicate agent destination target missing extra empty nul; do
  row claude "$CLAUDE" > "$PLAN"
  case "$kind" in
    duplicate) row claude "$CLAUDE" >> "$PLAN" ;;
    agent) row gemini "$CLAUDE" >> "$PLAN" ;;
    destination) row codex "$HOME/elsewhere/demo" >> "$PLAN" ;;
    target) row codex "$CODEX" relative >> "$PLAN" ;;
    missing) row codex "$CODEX" "$ROOT/cache/missing" >> "$PLAN" ;;
    extra) printf 'codex\tdemo\t%s\t%s\textra\n' "$CODEX" "$ROOT/cache/demo" >> "$PLAN" ;;
    empty) printf 'codex\t\t%s\t%s\n' "$CODEX" "$ROOT/cache/demo" >> "$PLAN" ;;
    nul) printf 'co\0dex\tdemo\t%s\t%s\n' "$CODEX" "$ROOT/cache/demo" >> "$PLAN" ;;
  esac
  reject _external_deploy_plan "$RULES" "$PLAN"
  [ ! -e "$XDG_STATE_HOME" ] && [ ! -e "$HOME/.claude" ] || exit 1
done
ok 'duplicates and malformed late rows fail before any mutation'
mv "$RULES/skills/external.list" "$RULES/skills/claude-only.list"
row codex "$CODEX" > "$PLAN"
reject _external_deploy_plan "$RULES" "$PLAN"
printf 'unknown https://example.invalid/source skills/demo\n' > "$RULES/skills/claude-only.list"
row claude "$CLAUDE" > "$PLAN"
reject _external_deploy_plan "$RULES" "$PLAN"
: > "$PLAN"
printf 'malformed catalog\n' > "$RULES/skills/claude-only.list"
_external_deploy_plan "$RULES" "$PLAN"
[ "${#_ed_paths[@]}" -eq 0 ]
ok 'catalog applicability enforced and empty cleanup bypasses disabled catalogs'
printf 'demo https://example.invalid/source skills/demo\n' > "$RULES/skills/external.list"
: > "$RULES/skills/claude-only.list"
printf '%s deployment assertions passed\n' "$PASS"

[ "$(type -t external_deploy_all || true)" = function ] || { echo 'FAIL: deployment transaction unavailable'; exit 1; }
INSTALLED="$XDG_STATE_HOME/agent-rules/external-installed.tsv"
RELINQUISHED="$XDG_STATE_HOME/agent-rules/external-relinquished.tsv"
both() { row claude "$CLAUDE" > "$PLAN"; row codex "$CODEX" >> "$PLAN"; }
link_is() { [ -L "$1" ] && readlink "$1" | cmp -s - <(printf '%s\n' "$2"); }
reject external_deploy_all "$RULES" "$PLAN"
[ ! -e "$XDG_STATE_HOME" ]
ok 'caller must establish installation-lock state before deployment'
mkdir -p "$(dirname "$MANIFEST")"
both
( MANIFEST="$ROOT/cache/demo/ownership"; reject external_deploy_all "$RULES" "$PLAN" )
[ ! -e "$ROOT/cache/demo/ownership" ] && [ ! -e "$CLAUDE" ] && [ ! -e "$CODEX" ] || exit 1
ok 'metadata cannot be placed inside prepared source content'
external_deploy_all "$RULES" "$PLAN"
link_is "$CLAUDE" "$ROOT/cache/demo" && link_is "$CODEX" "$ROOT/cache/demo" || exit 1
cmp -s "$PLAN" "$INSTALLED"
printf 'link\t%s\t%s\nlink\t%s\t%s\n' "$CLAUDE" "$ROOT/cache/demo" "$CODEX" "$ROOT/cache/demo" > "$ROOT/expected"
cmp -s "$ROOT/expected" "$MANIFEST"
cp -p "$INSTALLED" "$ROOT/installed.before"
external_deploy_all "$RULES" "$PLAN"
cmp -s "$ROOT/installed.before" "$INSTALLED" && [ ! -e "$BACKUP" ] || exit 1
ok 'fresh both-agent deployment and idempotence preserve typed ownership'
: > "$PLAN"
( MANIFEST="$ROOT/cache/demo/ownership"; reject external_deploy_all "$RULES" "$PLAN" )
[ ! -e "$ROOT/cache/demo/ownership" ] && link_is "$CLAUDE" "$ROOT/cache/demo" || exit 1
ok 'empty cleanup also protects prior prepared source locations'

row claude "$CLAUDE" > "$PLAN"
mv "$RULES/skills/external.list" "$RULES/skills/claude-only.list"
external_deploy_all "$RULES" "$PLAN"
[ ! -e "$CODEX" ] && [ ! -L "$CODEX" ] && [ -d "$ROOT/cache/demo" ] || exit 1
: > "$PLAN"
external_deploy_all "$RULES" "$PLAN"
[ ! -L "$CLAUDE" ] && [ ! -s "$INSTALLED" ] && [ ! -s "$MANIFEST" ] || exit 1
ok 'scope narrowing and empty disabled selection remove owned links with live sources'
mv "$RULES/skills/claude-only.list" "$RULES/skills/external.list"
ln -s "$ROOT/cache/demo"$'\n\n' "$CLAUDE"
both
external_deploy_all "$RULES" "$PLAN"
link_is "$CLAUDE" "$ROOT/cache/demo"
link_is "$(find "$BACKUP" -type l)" "$ROOT/cache/demo"$'\n\n'
: > "$PLAN"
external_deploy_all "$RULES" "$PLAN"
ok 'unowned newline-suffixed links are backed up and replaced with the exact desired target'
for kind in live broken file newline; do
  both
  external_deploy_all "$RULES" "$PLAN"
  rm "$CLAUDE"
  case "$kind" in
    live) ln -s "$ROOT/cache/demo" "$ROOT/user-target"; ln -s "$ROOT/user-target" "$CLAUDE" ;;
    broken) ln -s "$ROOT/missing" "$CLAUDE" ;;
    newline) ln -s "$ROOT/cache/demo"$'\n\n' "$CLAUDE" ;;
    file) printf 'user content\n' > "$CLAUDE" ;;
  esac
  cp -a "$CLAUDE" "$ROOT/preserved"
  reject external_deploy_all "$RULES" "$PLAN"
  : > "$PLAN"
  external_deploy_all "$RULES" "$PLAN"
  [ ! -s "$MANIFEST" ] && [ ! -s "$INSTALLED" ] && [ -s "$RELINQUISHED" ] || exit 1
  if [ "$kind" = file ]; then cmp -s "$CLAUDE" "$ROOT/preserved"
  else readlink "$CLAUDE" > "$ROOT/actual-target"; readlink "$ROOT/preserved" > "$ROOT/expected-target"
    cmp -s "$ROOT/actual-target" "$ROOT/expected-target"; fi
  grep -Fqx "$(row claude "$CLAUDE")" "$RELINQUISHED"
  both
  reject external_deploy_all "$RULES" "$PLAN"
  rm "$CLAUDE" "$ROOT/preserved"
  external_deploy_all "$RULES" "$PLAN"
  [ ! -s "$RELINQUISHED" ]
done
ok 'live, broken, newline-retargeted links and files survive cleanup and later selection'
: > "$PLAN"
external_deploy_all "$RULES" "$PLAN"
printf 'foreign file\n' > "$CLAUDE"
mkdir -p "$CODEX"
printf 'foreign directory\n' > "$CODEX/kept"
both
external_deploy_all "$RULES" "$PLAN"
[ "$(find "$BACKUP" -type f | wc -l)" -eq 2 ]
find "$BACKUP" -type f -exec cat {} + > "$ROOT/backup-content"
grep -q 'foreign file' "$ROOT/backup-content" && grep -q 'foreign directory' "$ROOT/backup-content"
ok 'foreign file and directory collisions receive public-style backups'
cp -p "$MANIFEST" "$ROOT/manifest.safe"
printf 'malformed state\n' > "$RELINQUISHED"
reject external_deploy_all "$RULES" "$PLAN"
cmp -s "$ROOT/manifest.safe" "$MANIFEST"
: > "$RELINQUISHED"
ok 'malformed persisted conflict evidence fails without deployment mutation'

mkdir -p "$ROOT/cache/new"
printf 'new skill\n' > "$ROOT/cache/new/SKILL.md"
row claude "$CLAUDE" "$ROOT/cache/new" > "$PLAN"
row codex "$CODEX" "$ROOT/cache/new" >> "$PLAN"
cp -p "$MANIFEST" "$ROOT/manifest.before"
cp -p "$INSTALLED" "$ROOT/installed.before"
cp -p "$RELINQUISHED" "$ROOT/relinquished.before"
find "$BACKUP" -mindepth 1 | sort > "$ROOT/backups.before"
ln() { if [ "${*: -1}" = "$CODEX" ]; then return 1; fi; command ln "$@"; }
reject external_deploy_all "$RULES" "$PLAN"
unset -f ln
link_is "$CLAUDE" "$ROOT/cache/demo" && link_is "$CODEX" "$ROOT/cache/demo" || exit 1
cmp -s "$MANIFEST" "$ROOT/manifest.before" && cmp -s "$INSTALLED" "$ROOT/installed.before" || exit 1
cmp -s "$RELINQUISHED" "$ROOT/relinquished.before"
find "$BACKUP" -mindepth 1 | sort > "$ROOT/backups.after"
cmp -s "$ROOT/backups.before" "$ROOT/backups.after"
ok 'second-agent failure restores both agents, backups and exact metadata bytes'
printf 'local copy\n' > "$HOME/local-copy"
_manifest_record copy "$HOME/local-copy" "$(_manifest_digest "$HOME/local-copy")"
printf 'user ghost\n' > "$HOME/.claude/skills/ghost"
printf 'claude\tghost\t%s\t%s\n' "$HOME/.claude/skills/ghost" "$ROOT/cache/demo" > "$RELINQUISHED"
cp -p "$MANIFEST" "$ROOT/manifest.before"
cp -p "$RELINQUISHED" "$ROOT/relinquished.before"
for selection in replacement removal; do
  [ "$selection" != removal ] || : > "$PLAN"
  mv() { local last="${*: -1}"; command mv "$@" || return; [ "$last" != "$INSTALLED" ]; }
  reject external_deploy_all "$RULES" "$PLAN"
  unset -f mv
  link_is "$CLAUDE" "$ROOT/cache/demo" && link_is "$CODEX" "$ROOT/cache/demo" || exit 1
  cmp -s "$MANIFEST" "$ROOT/manifest.before" && cmp -s "$INSTALLED" "$ROOT/installed.before" || exit 1
  cmp -s "$RELINQUISHED" "$ROOT/relinquished.before"
  [ "$(cat "$HOME/local-copy")" = 'local copy' ]
done
ok 'failure after selection rename restores replacements, removals and all typed metadata'

: > "$PLAN"
external_deploy_all "$RULES" "$PLAN"
printf 'displaced\n' > "$CLAUDE"
rm "$MANIFEST" "$INSTALLED" "$RELINQUISHED"
both
ln() { if [ "${*: -1}" = "$CODEX" ]; then return 1; fi; command ln "$@"; }
reject external_deploy_all "$RULES" "$PLAN"
unset -f ln
[ "$(cat "$CLAUDE")" = displaced ] && [ ! -L "$CODEX" ] && [ ! -e "$CODEX" ] || exit 1
[ ! -e "$MANIFEST" ] && [ ! -e "$INSTALLED" ] && [ ! -e "$RELINQUISHED" ] || exit 1
ok 'failed fresh install restores displaced files and originally absent metadata'
rm "$CLAUDE"
mkdir -p "$CLAUDE/inside"
printf 'nested source\n' > "$CLAUDE/inside/SKILL.md"
ln -s "$CLAUDE/inside" "$ROOT/cache/alias"
row claude "$CLAUDE" "$ROOT/cache/alias" > "$PLAN"
reject external_deploy_all "$RULES" "$PLAN"
[ -f "$CLAUDE/inside/SKILL.md" ] && [ ! -L "$CLAUDE" ] || exit 1
rm -r "$CLAUDE"
printf 'displaced\n' > "$CLAUDE"
both
ok 'physical source aliases inside a displaced destination are refused before mutation'

(
  fixture="$ROOT/retained-fixture"
  export HOME="$fixture/home" XDG_STATE_HOME="$fixture/state"
  MANIFEST="$XDG_STATE_HOME/agent-rules/links"
  BACKUP="$fixture/backups"
  INSTALLED="$XDG_STATE_HOME/agent-rules/external-installed.tsv"
  RELINQUISHED="$XDG_STATE_HOME/agent-rules/external-relinquished.tsv"
  PLAN="$fixture/desired.tsv"
  CLAUDE="$HOME/.claude/skills/demo"
  CODEX="$HOME/.agents/skills/demo"
  old_source="$fixture/cache/old"
  new_source="$fixture/cache/new"
  mkdir -p "$(dirname "$MANIFEST")" "$old_source" "$new_source"
  printf 'retained source bytes\n' > "$old_source/SKILL.md"
  printf 'new source bytes\n' > "$new_source/SKILL.md"
  row claude "$CLAUDE" "$old_source" > "$PLAN"
  external_deploy_all "$RULES" "$PLAN"
  rm "$CLAUDE"
  printf 'preserved user artifact\n' > "$CLAUDE"
  : > "$PLAN"
  external_deploy_all "$RULES" "$PLAN"
  [ ! -s "$INSTALLED" ] && [ -s "$RELINQUISHED" ] || exit 1
  for overlap in metadata backup destination; do
    (
      case "$overlap" in
        metadata) MANIFEST="$old_source/SKILL.md" ;;
        backup) BACKUP="$old_source/backups"
          mkdir -p "$(dirname "$CODEX")"; printf 'foreign collision\n' > "$CODEX" ;;
        destination) CODEX="$old_source/demo"
          skills_dest_for() { printf '%s\n' "$old_source"; } ;;
      esac
      row codex "$CODEX" "$new_source" > "$PLAN"
      tar -cf "$ROOT/retained-before.tar" -C "$fixture" .
      reject external_deploy_all "$RULES" "$PLAN"
      tar -cf "$ROOT/retained-after.tar" -C "$fixture" .
      cmp -s "$ROOT/retained-before.tar" "$ROOT/retained-after.tar"
    )
  done
)
ok 'tombstone-only source targets block metadata, backup and destination mutation'

ln() { if [ "${*: -1}" = "$CODEX" ]; then return 1; fi; command ln "$@"; }
cp() { case "$1:$2" in -a:*/paths/*) return 1 ;; esac; command cp "$@"; }
if external_deploy_all "$RULES" "$PLAN" > "$ROOT/out" 2> "$ROOT/err"; then
  echo 'FAIL: rollback failure reported success'; exit 1
else [ "$?" -eq 2 ]; fi
unset -f ln cp
recovery="$(find "$XDG_STATE_HOME/agent-rules" -maxdepth 1 -name '.external-deploy.*' -type d)"
[ -n "$recovery" ] && [ -f "$recovery/paths/0" ] && grep -Fq "$recovery" "$ROOT/err" || exit 1
[ -f "$recovery/snapshots-complete" ]
grep -Fq "$(printf '0\tpresent\t%s' "$CLAUDE")" "$recovery/paths.tsv"
grep -Fq "$(printf 'absent\t%s' "$MANIFEST")" "$recovery/paths.tsv"
reject external_deploy_all "$RULES" "$PLAN"
ok 'failed compensation has distinct status, retained recovery evidence and retry refusal'
printf '%s deployment assertions passed\n' "$PASS"
