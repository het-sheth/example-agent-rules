#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0
fresh() {
  CASE="$ROOT/$1"
  export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state"
  export MANIFEST="$XDG_STATE_HOME/agent-rules/links" AGENT_RULES_BACKUP="$CASE/backups"
  BOOK="$CASE/book"
  mkdir -p "$HOME/.codex/skills" "$BOOK/lib" "$BOOK/capabilities" "$BOOK/skills/demo" "$(dirname "$MANIFEST")"
  cp "$REPO/install.sh" "$REPO/assemble.sh" "$REPO/_global.md" \
    "$REPO/_machine.example.md" "$REPO/claude-extras.md" "$BOOK/"
  cp "$REPO"/lib/*.sh "$BOOK/lib/"
  cp "$REPO/capabilities/matrix.tsv" "$BOOK/capabilities/"
  OLD="$HOME/.codex/skills/demo" NEW="$HOME/.agents/skills/demo"
  TARGET="$BOOK/skills/demo"
}
run_install() { PROFILE="${1:-personal}" bash "$BOOK/install.sh" > "$CASE/output" 2>&1; }
assert() {
  if "$@"; then PASS=$((PASS + 1)); else
    echo "FAIL: $CASE: $*"; cat "$CASE/output"; FAIL=$((FAIL + 1))
  fi
}
link_is() { [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
legacy() {
  ln -s "$TARGET" "$OLD"
  if [ "$1" = bare ]; then printf '%s\n' "$OLD" > "$MANIFEST"
  else printf 'link\t%s\t%s\n' "$OLD" "$TARGET" > "$MANIFEST"; fi
}
records() { find "$XDG_STATE_HOME/agent-rules/migrations/codex-skills" -name complete 2>/dev/null || true; }
snapshot() {
  find "$CASE" -type f ! -name output ! -name before ! -name after -exec sha256sum {} +
  find "$CASE" -type l -printf '%p %l\n'
  find "$CASE" -type d
}
fresh fresh
assert run_install
assert link_is "$NEW" "$TARGET"
assert absent "$OLD"
assert test -z "$(records)"
for kind in typed bare relative typed-relative; do
  fresh "$kind"
  legacy "$kind"
  if [ "$kind" = relative ] || [ "$kind" = typed-relative ]; then
    rm "$OLD"
    ln -s ../../../book/skills/demo "$OLD"
    if [ "$kind" = relative ]; then printf '%s\n' "$OLD" > "$MANIFEST"
    else printf 'link\t%s\t%s\n' "$OLD" ../../../book/skills/demo > "$MANIFEST"; fi
  fi
  assert run_install
  assert link_is "$NEW" "$TARGET"
  assert absent "$OLD"
  assert test -n "$(records)"
  cp "$MANIFEST" "$CASE/expected"
  count="$(records)"
  assert run_install
  assert cmp -s "$MANIFEST" "$CASE/expected"
  assert test "$(records)" = "$count"
done
fresh check
legacy typed
assert run_install
assert env PROFILE=personal bash "$BOOK/install.sh" check
rm -f "$NEW"
ln -sf "$TARGET" "$OLD"
if PROFILE=personal bash "$BOOK/install.sh" check > "$CASE/output" 2>&1; then
  echo 'FAIL: legacy-only check passed'; FAIL=$((FAIL + 1))
else PASS=$((PASS + 1)); fi
for kind in foreign retargeted broken file; do
  fresh "$kind"
  case "$kind" in
    file) echo user-content > "$OLD" ;;
    *)
      ln -s "$HOME/foreign/missing" "$OLD"
      if [ "$kind" != foreign ]; then
        printf 'link\t%s\t%s\n' "$OLD" "$TARGET" > "$MANIFEST"
      fi
      ;;
  esac
  assert run_install
  if [ "$kind" = file ]; then assert test "$(cat "$OLD")" = user-content
  else assert link_is "$OLD" "$HOME/foreign/missing"; fi
done
fresh failure
legacy typed
mkdir -p "$HOME/.agents"
echo blocked > "$HOME/.agents/skills"
if run_install; then echo 'FAIL: blocked destination install passed'; FAIL=$((FAIL + 1))
else PASS=$((PASS + 1)); fi
assert link_is "$OLD" "$TARGET"
assert grep -Fq "$OLD" "$MANIFEST"
fresh work
legacy typed
assert run_install
ln -s "$TARGET" "$OLD"
printf 'link\t%s\t%s\n' "$OLD" "$TARGET" >> "$MANIFEST"
assert run_install work
assert absent "$OLD"
assert absent "$NEW"
for profile in personal work; do
  fresh "dry-$profile"
  legacy bare
  snapshot | sort > "$CASE/before"
  assert env PROFILE="$profile" bash "$BOOK/install.sh" --dry-run
  snapshot | sort > "$CASE/after"
  assert cmp -s "$CASE/before" "$CASE/after"
done
fresh retired-work
legacy typed
assert run_install
ln -s "$TARGET" "$OLD"
printf 'link\t%s\t%s\n' "$OLD" "$TARGET" >> "$MANIFEST"
rmdir "$TARGET"
assert run_install work
assert absent "$OLD"
assert absent "$NEW"
rollback() { bash "$BOOK/install.sh" rollback-codex-skills "$1" > "$CASE/output" 2>&1; }
for kind in missing same file symlink directory; do
  fresh "reverse-$kind"
  legacy bare
  mkdir -p "$(dirname "$NEW")"
  case "$kind" in
    same) ln -s "$TARGET" "$NEW" ;;
    file) echo displaced > "$NEW" ;;
    symlink) ln -s "$HOME/foreign/missing" "$NEW" ;;
    directory) mkdir "$NEW"; echo displaced > "$NEW/content" ;;
  esac
  if [ "$kind" = same ]; then
    printf 'link\t%s\t%s\n' "$NEW" "$TARGET" >> "$MANIFEST"
  fi
  assert run_install
  record="$(dirname "$(records)")"
  assert rollback "$record"
  assert link_is "$OLD" "$TARGET"
  assert grep -Fxq "$OLD" "$MANIFEST"
  case "$kind" in
    missing) assert absent "$NEW" ;;
    same) assert link_is "$NEW" "$TARGET" ;;
    file) assert test "$(cat "$NEW")" = displaced ;;
    symlink) assert link_is "$NEW" "$HOME/foreign/missing" ;;
    directory) assert test "$(cat "$NEW/content")" = displaced ;;
  esac
done
for kind in old new new-file manifest missing-backup; do
  fresh "reject-$kind"
  legacy typed
  assert run_install
  record="$(dirname "$(records)")"
  case "$kind" in
    old) ln -s "$HOME/user/missing" "$OLD" ;;
    new) rm "$NEW"; ln -s "$HOME/user/missing" "$NEW" ;;
    new-file) rm "$NEW"; echo user-content > "$NEW" ;;
    manifest) printf 'link\t%s\t%s\n' "$NEW" "$HOME/user/missing" > "$MANIFEST" ;;
    missing-backup) printf '%s\n' backup > "$CASE/state-change"
      sed '$s/missing/backup/' "$record/paths" > "$CASE/paths"
      mv "$CASE/paths" "$record/paths"
      printf '%s\n' "$AGENT_RULES_BACKUP/codex-skills-$(basename "$record")/demo.pre-install.missing" > "$record/backup-path" ;;

  esac
  snapshot | sort > "$CASE/before"
  if rollback "$record"; then echo "FAIL: rollback accepted changed $kind"; FAIL=$((FAIL + 1))
  else PASS=$((PASS + 1)); fi
  snapshot | sort > "$CASE/after"
  assert cmp -s "$CASE/before" "$CASE/after"
done
fresh pending
legacy typed
assert run_install
record="$(dirname "$(records)")"
rm "$record/complete"
ln -s "$TARGET" "$OLD"
printf 'link\t%s\t%s\n' "$OLD" "$TARGET" >> "$MANIFEST"
assert rollback "$record"
assert link_is "$OLD" "$TARGET"
assert absent "$NEW"
fresh state-failure
legacy typed
mkdir -p "$XDG_STATE_HOME/agent-rules/migrations"
echo blocked > "$XDG_STATE_HOME/agent-rules/migrations/codex-skills"
if run_install; then echo 'FAIL: missing evidence install passed'; FAIL=$((FAIL + 1))
else PASS=$((PASS + 1)); fi
assert link_is "$OLD" "$TARGET"
assert absent "$NEW"
fresh no-record
assert run_install
snapshot | sort > "$CASE/before"
if rollback "$XDG_STATE_HOME/agent-rules/migrations/codex-skills/nonexistent"; then
  echo 'FAIL: rollback accepted a fresh install'; FAIL=$((FAIL + 1))
else PASS=$((PASS + 1)); fi
snapshot | sort > "$CASE/after"
assert cmp -s "$CASE/before" "$CASE/after"
echo "$PASS passed, $FAIL failed (Codex migration)"
[ "$FAIL" -eq 0 ]
