#!/usr/bin/env bash
# Wire this rulebook into every coding agent installed on the machine.
#
#   install.sh            install / re-wire (idempotent, non-destructive)
#   install.sh --dry-run  print intended actions; change nothing, anywhere
#   install.sh check      verify the wiring; exit nonzero if anything is wrong
#
# Nothing is ever deleted: anything in the way is MOVED into $BACKUP.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO/lib/common.sh"
. "$REPO/lib/profile.sh"
. "$REPO/lib/manifest.sh"
. "$REPO/lib/adapters.sh"

BACKUP="${AGENT_RULES_BACKUP:-$HOME/.agent-rules-backup}"
PROFILE="${PROFILE:-$(read_profile "$REPO/_machine.md")}"

# Two agents installing at once must not interleave writes to the same settings/manifest files.
# Only a real (mutating) install needs this; --dry-run and check never write, so they never wait
# on it. See lib/common.sh for the flock/mkdir fallback.
LOCK="${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/install.lock"

MODE="${1:-install}"
DRY=false
[ "$MODE" = "--dry-run" ] && DRY=true

# ------------------------------------------------------------------ check ---
do_check() {
  local fail=0
  echo "PROFILE: $PROFILE"
  report_adapter_state "$REPO"
  echo "WIRING:"

  if [ ! -f "$REPO/AGENTS.md" ]; then
    echo "FAIL: AGENTS.md not assembled — run: bash assemble.sh"
    fail=1
  fi

  check_claude_adapter "$REPO" || fail=1
  check_codex_adapter  "$REPO" || fail=1
  check_gemini_adapter "$REPO" || fail=1
  check_skills         "$REPO" || fail=1
  # Deployment discipline: every artifact this repo puts on disk is either a symlink (which
  # cannot drift) or a tracked copy whose digest was recorded when it was written. This is the
  # step that catches a deployed file edited in place instead of at its source.
  if manifest_check; then
    echo "PASS: managed artifacts all present; no dangling links, no drifted copies"
  else
    fail=1
  fi

  # A rules file at the home root loads *in addition to* the per-agent one, so the same rules
  # get injected twice and the two copies drift. Flag it; do not silently move it during check.
  local stray
  for stray in "$HOME/CLAUDE.md" "$HOME/AGENTS.md"; do
    if [ -e "$stray" ] || [ -L "$stray" ]; then
      echo "FAIL: stray $stray present (double-load risk) — run install.sh to relocate it"
      fail=1
    else
      echo "PASS: no stray $stray"
    fi
  done

  if [ "$fail" -ne 0 ]; then
    echo "check: FAILED"
    exit 1
  fi
  echo "check: OK"
}

# ---------------------------------------------------------------- install ---
do_install() {
  if $DRY; then
    echo "install (DRY RUN — nothing will change)"
  else
    echo "install"
  fi

  # Seed this machine's identity file on first run. _machine.md is gitignored, so a fresh
  # clone has none and assemble.sh would fall back to the placeholder every time.
  if [ ! -f "$REPO/_machine.md" ]; then
    if $DRY; then
      echo "  would: seed _machine.md from _machine.example.md"
    else
      cp "$REPO/_machine.example.md" "$REPO/_machine.md"
      echo "  seeded _machine.md from the template — EDIT it for this machine, then re-run"
    fi
  fi

  if $DRY; then
    echo "  would: bash $REPO/assemble.sh"
  else
    bash "$REPO/assemble.sh"
  fi

  install_claude_adapter "$REPO"
  install_codex_adapter  "$REPO"
  install_gemini_adapter "$REPO"
  install_skills         "$REPO"

  echo "Home-root files:"
  backup_existing "$HOME/CLAUDE.md"
  backup_existing "$HOME/AGENTS.md"

  if $DRY; then
    echo "Dry run complete. No changes were made."
  else
    echo "Done. Run './install.sh check' to verify and see the capability matrix."
  fi
}

# ------------------------------------------------------------------- main ---
# Only run when executed, not when sourced — so tests can source and call single functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "$MODE" in
    check)      do_check ;;
    --dry-run)  do_install ;;
    install)    mkdir -p "$(dirname "$LOCK")"; with_lock "$LOCK" do_install ;;
    *) echo "usage: install.sh [--dry-run|check]" >&2; exit 2 ;;
  esac
fi
