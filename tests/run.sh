#!/usr/bin/env bash
# tests/run.sh — behavioral regression tests for the fix-wave findings.
#
# Each test builds a throwaway HOME + MANIFEST under a temp dir, sources the libs directly
# (never installs into the real machine), and asserts on their behavior. Run with:
#   bash tests/run.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# fresh_env — set up an isolated HOME/MANIFEST pair and source the libs against it.
# Each test calls this itself so tests never share state.
fresh_env() {
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.gemini"
  unset PROFILE
  unset MANIFEST
  MANIFEST="$HOME/.local/state/agent-rules/links"
  . "$REPO/lib/common.sh"
  . "$REPO/lib/profile.sh"
  . "$REPO/lib/manifest.sh"
  . "$REPO/lib/adapters.sh"
}

# ---------------------------------------------------------------- T5.1 ---
test_assemble_replaces_symlink_atomically() {
  local d; d="$(mktemp -d)"
  cp "$REPO/assemble.sh" "$REPO/_global.md" "$REPO/_machine.example.md" "$d/"
  ( cd "$d" && ln -s /nonexistent AGENTS.md && bash assemble.sh >/dev/null )
  if [ -L "$d/AGENTS.md" ]; then
    fail "T5.1: AGENTS.md is still a symlink after assemble.sh"
  else
    pass "T5.1: assemble.sh replaces a pre-existing symlink with a regular file"
  fi
  rm -rf "$d"
}

# ---------------------------------------------------------------- T5.3 ---
test_managed_link_backs_up_in_the_way_file() {
  fresh_env
  local dest="$HOME/in-the-way" src
  src="$(mktemp)"; echo source > "$src"
  echo "unrelated content" > "$dest"
  export BACKUP="$HOME/.agent-rules-backup"
  managed_link "$src" "$dest"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ] && ls "$BACKUP"/in-the-way.pre-install.* >/dev/null 2>&1; then
    pass "T5.3: managed_link backs up an in-the-way regular file, then replaces it"
  else
    fail "T5.3: managed_link did not back up + replace the in-the-way file"
  fi
}

test_managed_link_propagates_manifest_failure() {
  local shape
  for shape in new same; do
    if (
      fresh_env
      local src="$HOME/source" dest="$HOME/dest" status
      echo source > "$src"
      managed_link "$src" "$HOME/sentinel" >/dev/null
      [ "$shape" != same ] || ln -s "$src" "$dest"
      mv() { return 1; }
      if managed_link "$src" "$dest" >/dev/null; then status=0; else status=$?; fi
      [ "$status" -ne 0 ] && [ -L "$dest" ] \
        && grep -Fq "$HOME/sentinel" "$MANIFEST" && ! grep -Fq "$dest" "$MANIFEST"
    ); then pass "manifest: $shape managed link propagates failed ownership write"
    else fail "manifest: $shape managed link masked failed ownership write"; fi
  done
}

# ---------------------------------------------------------------- T5.5 ---
test_with_lock_serializes_install() {
  fresh_env
  local lock="$HOME/.lock" out="$HOME/order"
  (
    with_lock "$lock" bash -c 'sleep 0.3; echo A >> "'"$out"'"'
  ) &
  local p1=$!
  sleep 0.05
  with_lock "$lock" bash -c 'echo B >> "'"$out"'"'
  wait "$p1"
  if [ "$(cat "$out" | tr -d '\n')" = "AB" ]; then
    pass "T5.5: with_lock serializes two concurrent callers"
  else
    fail "T5.5: with_lock did not serialize (got: $(cat "$out" | tr '\n' ','))"
  fi
}

test_install_uses_with_lock() {
  if grep -q 'with_lock' "$REPO/install.sh"; then
    pass "T5.5: install.sh wires with_lock into the install path"
  else
    fail "T5.5: install.sh never calls with_lock"
  fi
}

# ---------------------------------------------------------------- T5.7 ---
test_profile_switch_removes_skill_links() {
  fresh_env
  mkdir -p "$HOME/repo/skills/demo-skill"
  PROFILE=personal
  install_skills "$HOME/repo"
  local link="$HOME/.claude/skills/demo-skill"
  if [ ! -L "$link" ]; then
    fail "T5.7: setup failed — skill link never installed under personal profile"
    return
  fi
  PROFILE=work
  install_skills "$HOME/repo"
  if [ -e "$link" ] || [ -L "$link" ]; then
    fail "T5.7: skill link still present after switching to work profile"
  else
    pass "T5.7: switching to work profile removes previously-installed skill links"
  fi
}

# ---------------------------------------------------------------- T6.1 ---
test_manifest_check_fails_without_hasher() {
  fresh_env
  local dest="$HOME/shim"
  echo hello | managed_copy "$dest"
  # Force a no-hasher record regardless of what's installed on this machine.
  printf 'copy\t%s\t-\n' "$dest" > "$MANIFEST"
  if manifest_check >/tmp/mc.$$ 2>&1; then
    fail "T6.1: manifest_check passed with a no-hasher ('-') digest record"
  else
    pass "T6.1: manifest_check hard-fails a managed copy recorded without a hasher"
  fi
  rm -f /tmp/mc.$$
}

# ---------------------------------------------------------------- T6.2 ---
test_manifest_check_catches_swapped_copy_for_link() {
  fresh_env
  local src dest; src="$(mktemp)"; echo x > "$src"; dest="$HOME/link"
  managed_link "$src" "$dest"
  rm -f "$dest"
  echo "not a link anymore" > "$dest"
  if manifest_check >/tmp/mc2.$$ 2>&1; then
    fail "T6.2: manifest_check passed after a managed link was swapped for a regular file"
  else
    pass "T6.2: manifest_check detects a managed link swapped for a regular file"
  fi
  rm -f /tmp/mc2.$$
}

test_manifest_check_catches_retargeted_link() {
  fresh_env
  local src1 src2 dest
  src1="$(mktemp)"; echo one > "$src1"
  src2="$(mktemp)"; echo two > "$src2"
  dest="$HOME/link2"
  managed_link "$src1" "$dest"
  rm -f "$dest"; ln -s "$src2" "$dest"
  if manifest_check >/tmp/mc3.$$ 2>&1; then
    fail "T6.2: manifest_check passed after a managed link was retargeted to a different source"
  else
    pass "T6.2: manifest_check detects a managed link retargeted to a different source"
  fi
  rm -f /tmp/mc3.$$
}

# ---------------------------------------------------------------- T6.3 ---
test_manifest_check_fails_when_manifest_missing() {
  fresh_env
  rm -f "$MANIFEST"
  if manifest_check >/tmp/mc4.$$ 2>&1; then
    fail "T6.3: manifest_check passed (exit 0) with no manifest file at all"
  else
    pass "T6.3: manifest_check fails when the manifest itself is missing"
  fi
  rm -f /tmp/mc4.$$
}

# ---------------------------------------------------------------- T9.F3 ---
test_empty_skills_dir_prints_none_line() {
  fresh_env
  mkdir -p "$HOME/repo/skills"
  PROFILE=personal
  local out; out="$(install_skills "$HOME/repo")"
  if printf '%s\n' "$out" | grep -qi "none to install"; then
    pass "T9.F3: install_skills prints a 'none to install' line for an empty skills/ dir"
  else
    fail "T9.F3: install_skills printed nothing for an empty skills/ dir (got: $out)"
  fi
}

# ------------------------------------------------------- codex round 2 ---
test_with_lock_refuses_live_holder() {
  fresh_env
  local lock="$HOME/test.lock" out rc
  mkdir "$lock.d"
  sleep 30 & local holder=$!
  printf '%s' "$holder" > "$lock.d/pid"
  out="$( (unset -f flock; command -v flock >/dev/null && exit 77; WITH_LOCK_TRIES=3 with_lock "$lock" true) 2>&1 )"; rc=$?
  kill "$holder" 2>/dev/null; rm -rf "$lock.d"
  if [ "$rc" -eq 77 ]; then pass "R2-lock: (flock present; fallback path not exercised on this runner)"; return; fi
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "held by running pid"; then
    pass "R2-lock: live holder's lock is refused, not stolen"
  else
    fail "R2-lock: expected refusal for live holder (rc=$rc out=$out)"
  fi
}

test_with_lock_steals_dead_holder() {
  fresh_env
  local lock="$HOME/test.lock" rc
  mkdir "$lock.d"
  sleep 0.1 & local dead=$!; wait "$dead" 2>/dev/null
  printf '%s' "$dead" > "$lock.d/pid"
  (unset -f flock; command -v flock >/dev/null && exit 77; WITH_LOCK_TRIES=3 with_lock "$lock" true) 2>/dev/null; rc=$?
  rm -rf "$lock.d"
  if [ "$rc" -eq 77 ]; then pass "R2-lock: (flock present; fallback path not exercised on this runner)"; return; fi
  if [ "$rc" -eq 0 ]; then
    pass "R2-lock: dead holder's stale lock is stolen and the command runs"
  else
    fail "R2-lock: expected stale lock steal to succeed (rc=$rc)"
  fi
}

test_manifest_forget_removes_legacy_bare_link() {
  fresh_env
  mkdir -p "$(dirname "$MANIFEST")"
  local link="$HOME/.claude/skills-legacy"
  ln -s "$REPO/skills" "$link"
  printf '%s\n' "$link" > "$MANIFEST"   # pre-format record: bare path, no kind, no target
  manifest_forget "$link" >/dev/null 2>&1
  if [ ! -L "$link" ] && ! grep -q "$link" "$MANIFEST"; then
    pass "R2-manifest: legacy bare record's in-repo link is removed with its record"
  else
    fail "R2-manifest: legacy bare link left behind (link=$([ -L "$link" ] && echo present || echo gone))"
  fi
}

test_prune_requires_typed_target_ownership() {
  fresh_env
  local agent dest src foreign record
  for agent in claude codex external; do
    dest="$HOME/.$agent/skills/retargeted"
    src="$HOME/cache/$agent/original"
    foreign="$HOME/foreign/$agent/missing"
    mkdir -p "$(dirname "$src")"
    echo source > "$src"
    managed_link "$src" "$dest" >/dev/null
    record="$(cat "$MANIFEST" | tail -1)"
    rm "$dest"
    ln -s "$foreign" "$dest"
    manifest_prune_dangling >/dev/null
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$foreign" ] \
       && grep -Fqx "$record" "$MANIFEST"; then
      pass "prune: $agent retargeted dangling link and record survive"
    else
      fail "prune: $agent retargeted dangling link or record was removed"
    fi
    dest="$HOME/.$agent/skills/owned"
    managed_link "$src" "$dest" >/dev/null
    rm "$src"
    manifest_prune_dangling >/dev/null
    if [ ! -L "$dest" ] && ! grep -Fq "$dest" "$MANIFEST"; then
      pass "prune: $agent owned dangling link and record are removed"
    else
      fail "prune: $agent owned dangling link or record survived"
    fi
  done
}

test_prune_bounds_legacy_skill_ownership() {
  fresh_env
  local REPO="$HOME/rulebook" name target dest
  mkdir -p "$REPO/skills" "$REPO/docs" "$HOME/foreign" "$HOME/.claude/skills"
  ln -s "$HOME/foreign" "$REPO/skills/escape"
  ln -s "$HOME/foreign/missing" "$REPO/skills/leaf-escape"
  mkdir -p "$(dirname "$MANIFEST")"
  for name in owned relative foreign other-repo-path prefix traversal escape leaf-escape unresolved; do
    case "$name" in
      owned) target="$REPO/skills/missing" ;;
      relative) target="../../rulebook/skills/missing" ;;
      foreign) target="$HOME/foreign/missing" ;;
      other-repo-path) target="$REPO/docs/missing" ;;
      prefix) target="$REPO/skills-other/missing" ;;
      traversal) target="$REPO/skills/../docs/missing" ;;
      escape) target="$REPO/skills/escape/missing" ;;
      leaf-escape) target="$REPO/skills/leaf-escape" ;;
      unresolved) target="$REPO/skills/missing-parent/missing" ;;
    esac
    dest="$HOME/.claude/skills/$name"
    ln -s "$target" "$dest"
    printf '%s\n' "$dest" >> "$MANIFEST"
    manifest_prune_dangling >/dev/null
    case "$name" in
      owned|relative)
        if [ ! -L "$dest" ] && ! grep -Fxq "$dest" "$MANIFEST"; then
          pass "prune: legacy $name skill link is removed"
        else
          fail "prune: legacy $name skill link or record survived"
        fi
        ;;
      *)
        if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$target" ] \
           && grep -Fxq "$dest" "$MANIFEST"; then
          pass "prune: legacy $name target survives"
        else
          fail "prune: legacy $name target or record was removed"
        fi
        ;;
    esac
  done
}

test_prune_preserves_other_manifest_artifacts() {
  fresh_env
  echo content | managed_copy "$HOME/copy"
  echo content | managed_copy "$HOME/copy-missing"
  rm "$HOME/copy-missing"
  echo content | managed_copy "$HOME/copy-symlink"
  rm "$HOME/copy-symlink"
  ln -s "$HOME/missing" "$HOME/copy-symlink"
  managed_link "$HOME/missing" "$HOME/replaced-link" >/dev/null
  rm "$HOME/replaced-link"
  echo user-content > "$HOME/replaced-link"
  echo user-content > "$HOME/bare-file"
  printf '%s\n' "$HOME/bare-file" >> "$MANIFEST"
  managed_link "$HOME/copy" "$HOME/live-link" >/dev/null
  ln -s "$REPO/skills/missing" "$HOME/unverifiable-link"
  printf 'link\t%s\n' "$HOME/unverifiable-link" >> "$MANIFEST"
  cp "$MANIFEST" "$HOME/expected-manifest"
  manifest_prune_dangling >/dev/null
  if cmp -s "$HOME/expected-manifest" "$MANIFEST" \
     && [ "$(cat "$HOME/copy")" = content ] \
     && [ ! -e "$HOME/copy-missing" ] \
     && [ -L "$HOME/copy-symlink" ] \
     && [ "$(readlink "$HOME/copy-symlink")" = "$HOME/missing" ] \
     && [ "$(cat "$HOME/replaced-link")" = user-content ] \
     && [ "$(cat "$HOME/bare-file")" = user-content ] \
     && [ "$(readlink "$HOME/live-link")" = "$HOME/copy" ] \
     && [ -L "$HOME/unverifiable-link" ]; then
    pass "prune: copies, regular files, live links and targetless typed records survive unchanged"
  else
    fail "prune: an artifact without dangling-link ownership proof changed"
  fi
}

test_install_preserves_retargeted_dangling_links() {
  fresh_env
  local repo="$HOME/rulebook" agent dest foreign record
  mkdir -p "$repo/lib" "$repo/skills/retired"
  cp "$REPO/install.sh" "$REPO/assemble.sh" "$REPO/_global.md" \
     "$REPO/_machine.example.md" "$REPO/claude-extras.md" "$repo/"
  cp "$REPO"/lib/*.sh "$repo/lib/"
  if ! env HOME="$HOME" XDG_STATE_HOME="$HOME/.local/state" PROFILE=personal \
       MANIFEST="$MANIFEST" AGENT_RULES_BACKUP="$HOME/backups" \
       bash "$repo/install.sh" > "$HOME/install.log" 2>&1; then
    cat "$HOME/install.log"
    fail "prune install: initial fixture install failed"
    return
  fi
  for agent in claude codex external; do
    if [ "$agent" = codex ]; then dest="$(skills_dest_for codex)/retired"
    else dest="$HOME/.$agent/skills/retired"; fi
    if [ "$agent" = external ]; then
      managed_link "$HOME/cache/retired" "$dest" >/dev/null
    fi
    rm "$dest"
    ln -s "$HOME/foreign/$agent/missing" "$dest"
  done
  rmdir "$repo/skills/retired"
  cp "$MANIFEST" "$HOME/before-reinstall"
  if ! env HOME="$HOME" XDG_STATE_HOME="$HOME/.local/state" PROFILE=personal \
       MANIFEST="$MANIFEST" AGENT_RULES_BACKUP="$HOME/backups" \
       bash "$repo/install.sh" > "$HOME/install.log" 2>&1; then
    cat "$HOME/install.log"
    fail "prune install: reinstall failed"
    return
  fi
  for agent in claude codex external; do
    if [ "$agent" = codex ]; then dest="$(skills_dest_for codex)/retired"
    else dest="$HOME/.$agent/skills/retired"; fi
    foreign="$HOME/foreign/$agent/missing"
    record="$(grep -F "$dest" "$HOME/before-reinstall")"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$foreign" ] \
       && grep -Fqx "$record" "$MANIFEST"; then
      pass "prune install: $agent retargeted dangling link survives final pruning"
    else
      fail "prune install: $agent retargeted dangling link or record was removed"
    fi
  done
}

# --------------------------------------------------------------------------
main() {
  test_assemble_replaces_symlink_atomically
  test_managed_link_backs_up_in_the_way_file
  test_managed_link_propagates_manifest_failure
  test_with_lock_serializes_install
  test_install_uses_with_lock
  test_profile_switch_removes_skill_links
  test_manifest_check_fails_without_hasher
  test_manifest_check_catches_swapped_copy_for_link
  test_manifest_check_catches_retargeted_link
  test_manifest_check_fails_when_manifest_missing
  test_empty_skills_dir_prints_none_line
  test_with_lock_refuses_live_holder
  test_with_lock_steals_dead_holder
  test_manifest_forget_removes_legacy_bare_link
  test_prune_requires_typed_target_ownership
  test_prune_bounds_legacy_skill_ownership
  test_prune_preserves_other_manifest_artifacts
  test_install_preserves_retargeted_dangling_links
  if bash "$REPO/tests/codex-skills-migration.test.sh"; then pass "Codex migration suite"
  else fail "Codex migration suite"; fi

  echo "----------------------------------------"
  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

main
