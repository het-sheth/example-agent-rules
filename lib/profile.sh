# lib/profile.sh — read the per-machine profile and gate optional sync. Source me.
#
# The profile is a marker comment in _machine.md, so it is per-machine and never committed:
#     <!-- agent-rules:profile=personal -->
#
# Unrecognized, missing, or malformed -> `work`, the least-privilege profile. A shared or
# employer-managed machine that never edits _machine.md therefore gets the rulebook and
# nothing else, which is the safe failure direction.

read_profile() {
  local f="$1" val
  [ -f "$f" ] || { echo work; return 0; }
  val="$(sed -n 's/<!--[[:space:]]*agent-rules:profile=\([a-z-]*\)[[:space:]]*-->.*/\1/p' "$f" 2>/dev/null | head -1)"
  case "$val" in
    personal) echo personal ;;
    *)        echo work ;;
  esac
}

# sync_enabled <feature> — is <feature> synced under the current $PROFILE?
#   personal — every optional feature this repo installs (currently: skills)
#   work     — nothing optional; the shared rulebook only
# An unrecognized feature name is also refused, so adding a gate to install.sh without
# declaring it here fails closed rather than silently installing everywhere.
sync_enabled() {
  local feature="$1"
  case "$feature" in
    skills) ;;
    *) warn "sync_enabled: unknown feature '$feature'; refusing"; return 1 ;;
  esac
  case "${PROFILE:-work}" in
    personal) return 0 ;;
    *)        return 1 ;;
  esac
}
