#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME"
. "$REPO/lib/common.sh"
. "$REPO/lib/profile.sh"
. "$REPO/lib/adapters.sh"
[ -f "$REPO/lib/external-skills.sh" ] || { echo 'FAIL: external source validation unavailable'; exit 1; }
. "$REPO/lib/external-skills.sh"
PASS=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
reject() {
  if "$@" > "$ROOT/out" 2> "$ROOT/err"; then
    printf 'FAIL: accepted invalid input: %s\n' "$*"; exit 1
  fi
  [ -s "$ROOT/err" ] && [ ! -s "$ROOT/out" ]
}
reset_catalog() {
  mkdir -p "$ROOT/rules/skills"
  : > "$ROOT/rules/skills/external.list"
  : > "$ROOT/rules/skills/claude-only.list"
  : > "$ROOT/rules/skills/external.lock"
}
RULES="$ROOT/rules"
SHA=1111111111111111111111111111111111111111
URL=https://example.invalid/team/Repo.git
reset_catalog
external_skills_validate "$RULES"
rm "$RULES/skills/external.list" "$RULES/skills/claude-only.list" "$RULES/skills/external.lock"
external_skills_validate "$RULES"
ok 'missing optional catalogs are empty'
reset_catalog
printf 'demo %s skills/demo\n' "$URL" > "$RULES/skills/external.list"
printf '%s %s\n' "$URL" "$SHA" > "$RULES/skills/external.lock"
external_skills_validate "$RULES"
ok 'valid catalog and immutable lock accepted without fetching'
for row in \
  "demo $URL" "demo $URL skills/demo extra" "../demo $URL skills/demo" \
  "demo $URL /absolute" "demo $URL ../escape" "demo $URL a/../escape" \
  "demo $URL a//b" "demo $URL a/" "demo $URL a/./b" \
  'demo ssh://host/repo skills/demo' 'demo git@host:repo skills/demo' \
  'demo file://relative/repo skills/demo' 'demo https://user@host/repo skills/demo' \
  'demo https://host/repo?branch=main skills/demo' 'demo https://host/repo#part skills/demo' \
  'demo https://host/a/../repo skills/demo' 'demo https://host/repo%20name skills/demo'; do
  printf '%s\n' "$row" > "$RULES/skills/external.list"
  reject external_skills_validate "$RULES"
done
ok 'malformed rows, unsafe paths and ambiguous URL forms rejected'
printf 'demo %s skills/demo\n' "$URL" > "$RULES/skills/external.list"
for lock in "$URL short" "$URL $SHA extra" "$URL $SHA
$URL $SHA" "$URL $SHA
$URL 2222222222222222222222222222222222222222"; do
  printf '%s\n' "$lock" > "$RULES/skills/external.lock"
  reject external_skills_validate "$RULES"
done
: > "$RULES/skills/external.lock"
reject external_skills_validate "$RULES"
printf '%s %s\n' "$URL" "$SHA" > "$RULES/skills/external.lock"
printf 'demo %s skills/other\n' "$URL" > "$RULES/skills/claude-only.list"
reject external_skills_validate "$RULES"
: > "$RULES/skills/claude-only.list"
mkdir "$RULES/skills/demo"
reject external_skills_validate "$RULES"
rmdir "$RULES/skills/demo"
printf 'de\0mo %s skills/demo\n' "$URL" > "$RULES/skills/external.list"
reject external_skills_validate "$RULES"
printf 'demo %s skills/demo\n' "$URL" > "$RULES/skills/external.list"
ok 'missing, duplicate and conflicting locks and cross-source collisions rejected'
external_skill_selected() { case "$3" in claude) return 0 ;; codex) return 1 ;; *) return 2 ;; esac; }
printf 'only %s skills/only\n' "$URL" > "$RULES/skills/claude-only.list"
_external_selected_rows "$RULES" > "$ROOT/selected"
[ "$(wc -l < "$ROOT/selected")" -eq 2 ]
! grep -q '^codex' "$ROOT/selected"
external_skill_selected() { return 2; }
reject _external_selected_rows "$RULES"
external_skill_selected() { return 0; }
_external_selected_rows "$RULES" > "$ROOT/selected"
[ "$(wc -l < "$ROOT/selected")" -eq 3 ]
! grep -q $'^codex\tonly\t' "$ROOT/selected"
ok 'selection callback errors propagate and Claude-only scope bounds selection'
printf '%s parser assertions passed\n' "$PASS"

[ "$(type -t external_skills_prepare || true)" = function ] || { echo 'FAIL: cache preparation unavailable'; exit 1; }
source_repo() {
  local dir="$1"
  mkdir -p "$dir/skills/demo" "$dir/skills/only" "$dir/skills/leaf"
  git init -q "$dir"
  git -C "$dir" config user.name Fixture
  git -C "$dir" config user.email fixture@example.invalid
  printf 'first\n' > "$dir/skills/demo/SKILL.md"
  printf 'only\n' > "$dir/skills/only/SKILL.md"
  ln -s "$ROOT/outside" "$dir/skills/escape"
  ln -s "$ROOT/outside/SKILL.md" "$dir/skills/leaf/SKILL.md"
  printf '*.md filter=fixture\n' > "$dir/.gitattributes"
  git -C "$dir" add .
  git -C "$dir" commit -qm initial
}
mkdir -p "$ROOT/outside"
printf 'outside\n' > "$ROOT/outside/SKILL.md"
A="$ROOT/a/shared" B="$ROOT/b/shared"
source_repo "$A"
source_repo "$B"
SHA_A="$(git -C "$A" rev-parse HEAD)"
SHA_B="$(git -C "$B" rev-parse HEAD)"
printf 'second\n' > "$A/skills/demo/SKILL.md"
git -C "$A" commit -qam second
URL_A="file://$A" URL_B="file://$B"
reset_catalog
printf 'alpha %s skills/demo\nbeta %s skills/demo\n' "$URL_A" "$URL_B" > "$RULES/skills/external.list"
printf 'only %s skills/only\n' "$URL_A" > "$RULES/skills/claude-only.list"
printf '%s %s\n%s %s\n' "$URL_A" "$SHA_A" "$URL_B" "$SHA_B" > "$RULES/skills/external.lock"
CACHE="$ROOT/cache"
external_skills_prepare "$RULES" "$CACHE" > "$ROOT/prepared"
ALPHA="$(awk -F '\t' '$1=="claude" && $2=="alpha" {print $3}' "$ROOT/prepared")"
BETA="$(awk -F '\t' '$1=="claude" && $2=="beta" {print $3}' "$ROOT/prepared")"
ENTRY_A="${ALPHA%/skills/demo}" ENTRY_B="${BETA%/skills/demo}"
[ "$ENTRY_A" != "$ENTRY_B" ] && [ "$(cat "$ALPHA/SKILL.md")" = first ]
[ "$(git -C "$ENTRY_A" rev-parse HEAD)" = "$SHA_A" ]
[ "$(wc -l < "$ROOT/prepared")" -eq 5 ]
! grep -q $'^codex\tonly\t' "$ROOT/prepared"
ok 'equal basenames have separate cache entries at exact selected revisions'
REAL_GIT="$(command -v git)"
mkdir "$ROOT/bin"
cat > "$ROOT/bin/git" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  if [ "$arg" = fetch ]; then
    printf '%s\n' "$*" >> "$FETCH_LOG"
    case "${FETCH_MODE:-normal}" in
      offline) exit 91 ;;
      interrupt) kill -KILL "$PPID"; exit 92 ;;
      slow) touch "$FETCH_READY"; sleep 0.8 ;;
    esac
  fi
done
exec "$REAL_GIT" "$@"
WRAPPER
chmod +x "$ROOT/bin/git"
export REAL_GIT PATH="$ROOT/bin:$PATH" FETCH_LOG="$ROOT/fetch-log" FETCH_READY="$ROOT/fetch-ready"
: > "$FETCH_LOG"
export FETCH_MODE=offline
external_skills_prepare "$RULES" "$CACHE" > "$ROOT/reused"
cmp "$ROOT/prepared" "$ROOT/reused"
[ ! -s "$FETCH_LOG" ]
printf 'dirty\n' >> "$ALPHA/SKILL.md"
reject external_skills_prepare "$RULES" "$CACHE"
grep -q dirty "$ALPHA/SKILL.md"
git -C "$ENTRY_A" checkout -- skills/demo/SKILL.md
printf 'untracked\n' > "$ENTRY_A/untracked"
reject external_skills_prepare "$RULES" "$CACHE"
rm "$ENTRY_A/untracked"
git -C "$ENTRY_A" remote set-url origin "$URL_B"
reject external_skills_prepare "$RULES" "$CACHE"
[ "$(git -C "$ENTRY_A" remote get-url origin)" = "$URL_B" ]
git -C "$ENTRY_A" remote set-url origin "$URL_A"
git -C "$ENTRY_A" checkout -q --detach "$SHA_A"
printf 'hidden dirty\n' >> "$ALPHA/SKILL.md"
git -C "$ENTRY_A" update-index --assume-unchanged skills/demo/SKILL.md
reject external_skills_prepare "$RULES" "$CACHE"
git -C "$ENTRY_A" update-index --no-assume-unchanged skills/demo/SKILL.md
git -C "$ENTRY_A" checkout -- skills/demo/SKILL.md
NEW_SHA="$(git -C "$A" rev-parse HEAD)"
"$REAL_GIT" -C "$ENTRY_A" fetch -q --depth=1 origin "$NEW_SHA"
git -C "$ENTRY_A" checkout -q --detach "$NEW_SHA"
reject external_skills_prepare "$RULES" "$CACHE"
[ "$(git -C "$ENTRY_A" rev-parse HEAD)" = "$NEW_SHA" ]
git -C "$ENTRY_A" checkout -q --detach "$SHA_A"
git -C "$ENTRY_A" replace "$SHA_A" "$NEW_SHA"
git -C "$ENTRY_A" checkout -q -f --detach "$SHA_A"
[ "$(cat "$ALPHA/SKILL.md")" = second ]
tar --format=ustar -cf "$ROOT/cache-before.tar" -C "$ENTRY_A" .
reject external_skills_prepare "$RULES" "$CACHE"
tar --format=ustar -cf "$ROOT/cache-after.tar" -C "$ENTRY_A" .
cmp "$ROOT/cache-before.tar" "$ROOT/cache-after.tar"
git -C "$ENTRY_A" replace -d "$SHA_A" >/dev/null
git -C "$ENTRY_A" checkout -q -f --detach "$SHA_A"
ok 'replacement-backed cache content is refused without changing its files or Git metadata'
printf 'first\n' > "$ROOT/locked-content"
printf '#!/bin/sh\ntouch "%s"\ncat "%s"\n' "$ROOT/local-filter-executed" "$ROOT/locked-content" > "$ROOT/local-clean-filter"
chmod +x "$ROOT/local-clean-filter"
for config in direct include; do
  if [ "$config" = direct ]; then
    git -C "$ENTRY_A" config filter.fixture.clean "$ROOT/local-clean-filter"
  else
    git config --file "$ROOT/included-config" filter.fixture.clean "$ROOT/local-clean-filter"
    git -C "$ENTRY_A" config include.path "$ROOT/included-config"
  fi
  printf 'evil!\n' > "$ALPHA/SKILL.md"
  tar --format=ustar -cf "$ROOT/cache-before.tar" -C "$ENTRY_A" .
  reject external_skills_prepare "$RULES" "$CACHE"
  [ ! -e "$ROOT/local-filter-executed" ]
  tar --format=ustar -cf "$ROOT/cache-after.tar" -C "$ENTRY_A" .
  cmp "$ROOT/cache-before.tar" "$ROOT/cache-after.tar"
  if [ "$config" = direct ]; then git -C "$ENTRY_A" config --unset filter.fixture.clean
  else git -C "$ENTRY_A" config --unset include.path; fi
  git -C "$ENTRY_A" checkout -q -f --detach "$SHA_A"
done
ok 'cache-local and included filters are refused without executing or changing cache metadata'
ok 'offline reuse never fetches and invalid final caches remain untouched'
reset_catalog
printf '%s %s\n' "$URL_A" "$SHA_A" > "$RULES/skills/external.lock"
for path in skills/missing skills/escape skills/leaf; do
  printf 'bad %s %s\n' "$URL_A" "$path" > "$RULES/skills/external.list"
  reject external_skills_prepare "$RULES" "$CACHE"
  [ "$(git -C "$ENTRY_A" rev-parse HEAD)" = "$SHA_A" ]
done
external_skill_selected() { return 1; }
external_skills_prepare "$RULES" "$ROOT/excluded-cache" > "$ROOT/excluded"
[ ! -e "$ROOT/excluded-cache" ] && [ ! -s "$ROOT/excluded" ]
external_skill_selected() { return 0; }
export FETCH_MODE=normal
for path in skills/missing skills/escape skills/leaf; do
  printf 'bad %s %s\n' "$URL_A" "$path" > "$RULES/skills/external.list"
  reject external_skills_prepare "$RULES" "$ROOT/bad-content-cache"
  [ "$(find "$ROOT/bad-content-cache" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ]
done
ok 'missing and escaping selected content fails before cache publication; excluded content is untouched'
printf 'alpha %s skills/demo\n' "$URL_A" > "$RULES/skills/external.list"
printf '%s %s\n' "$URL_A" 0000000000000000000000000000000000000000 > "$RULES/skills/external.lock"
reject external_skills_prepare "$RULES" "$ROOT/missing-cache"
[ "$(find "$ROOT/missing-cache" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ]
printf '%s %s\n' "$URL_A" "$SHA_A" > "$RULES/skills/external.lock"
export FETCH_MODE=interrupt
reject external_skills_prepare "$RULES" "$ROOT/retry-cache"
STAGING="$(find "$ROOT/retry-cache" -name installer-stage -print)"
[ -n "$STAGING" ]
export FETCH_MODE=normal
external_skills_prepare "$RULES" "$ROOT/retry-cache" > "$ROOT/retried"
[ -f "$STAGING" ] && [ -s "$ROOT/retried" ]
ok 'missing revisions fail cleanly and interrupted staging cannot block retry or get deleted'
: > "$FETCH_LOG"
export FETCH_MODE=slow
external_skills_prepare "$RULES" "$ROOT/concurrent-cache" > "$ROOT/one" & ONE=$!
external_skills_prepare "$RULES" "$ROOT/concurrent-cache" > "$ROOT/two" & TWO=$!
wait "$ONE"; wait "$TWO"
cmp "$ROOT/one" "$ROOT/two"
[ "$(wc -l < "$FETCH_LOG")" -eq 1 ]
grep -q "fetch --no-tags --depth=1 origin $SHA_A$" "$FETCH_LOG"
ok 'concurrent callers publish once and fetch exactly the locked revision'
mkdir -p "$ROOT/template/hooks"
printf '#!/bin/sh\ntouch "%s"\ncat\n' "$ROOT/executed" > "$ROOT/filter"
cp "$ROOT/filter" "$ROOT/template/hooks/post-checkout"
chmod +x "$ROOT/filter" "$ROOT/template/hooks/post-checkout"
git config --file "$ROOT/host-config" init.templateDir "$ROOT/template"
git config --file "$ROOT/host-config" filter.fixture.smudge "$ROOT/filter"
FETCH_MODE=normal GIT_CONFIG_GLOBAL="$ROOT/host-config" external_skills_prepare "$RULES" "$ROOT/no-execution-cache" > "$ROOT/no-execution"
[ ! -e "$ROOT/executed" ]
ok 'Git preparation does not execute inherited hooks or content filters'

wait_for_file() {
  local i
  for ((i=0; i<100; i++)); do [ ! -f "$1" ] || return 0; sleep 0.03; done
  printf 'FAIL: timed out waiting for %s\n' "$1"; return 1
}
outer_action() {
  external_skills_prepare "$RULES" "$ROOT/outer-cache-$1" > "$ROOT/outer-result-$1" || return 1
  touch "$ROOT/cache-complete-$1"
  wait_for_file "$ROOT/release-$1"
}
for mode in flock fallback; do
  if [ "$mode" = fallback ]; then
    command() { if [ "$*" = '-v flock' ]; then return 1; else builtin command "$@"; fi; }
  fi
  rm -f "$FETCH_READY"
  (with_lock "$ROOT/install-$mode.lock" outer_action "$mode") & OUTER=$!
  wait_for_file "$FETCH_READY"
  (with_lock "$ROOT/install-$mode.lock" touch "$ROOT/entered-$mode") & OTHER=$!
  wait_for_file "$ROOT/cache-complete-$mode"
  sleep 0.1
  [ ! -e "$ROOT/entered-$mode" ]
  touch "$ROOT/release-$mode"
  wait "$OUTER"; wait "$OTHER"
  [ -f "$ROOT/entered-$mode" ]
  unset -f command 2>/dev/null || true
done
ok 'cache subshell preserves outer install lock with flock and portable fallback'
printf '%s external source assertions passed\n' "$PASS"
