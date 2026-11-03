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
  [ -s "$ROOT/err" ] && [ ! -s "$ROOT/out" ]
}
row claude "$CLAUDE" > "$PLAN"
row codex "$CODEX" >> "$PLAN"
_external_deploy_plan "$RULES" "$PLAN"
[ "${#_ed_paths[@]}" -eq 2 ] && [ ! -e "$XDG_STATE_HOME" ] && [ ! -e "$HOME/.claude" ]
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
  [ ! -e "$XDG_STATE_HOME" ] && [ ! -e "$HOME/.claude" ]
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
