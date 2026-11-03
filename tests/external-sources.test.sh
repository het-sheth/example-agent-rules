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
