# lib/common.sh — shared helpers. Source me; do not execute.

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# with_lock <lockfile> <command...> — serialize a config mutation.
# Two agents installing at once must not interleave writes to the same settings file.
with_lock() {
  local lock="$1"; shift
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" || die "cannot open lock $lock"
    flock -w 5 9 || die "could not acquire lock $lock within 5s"
    "$@"; local rc=$?
    flock -u 9
    return $rc
  fi
  # Portable fallback where flock is absent (macOS ships without it): mkdir is an atomic
  # mutex. Spin up to ~5s to match `flock -w 5`. Unlike flock, a mkdir lock is NOT released
  # when the holding process dies — but "held past the budget" alone does not make it stale:
  # a legitimate install can outlast 5s, and stealing its lock would defeat the serialization
  # this function exists for. The holder records its PID; steal only when that process is
  # provably gone, and fail loudly when it is alive.
  local dir="${lock}.d" i=0 max="${WITH_LOCK_TRIES:-50}"
  while ! mkdir "$dir" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then
      local holder; holder="$(cat "$dir/pid" 2>/dev/null || true)"
      if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        die "lock $dir held by running pid $holder; wait for it to finish (rm -rf the dir only if you know it is wrong)"
      fi
      warn "stale lock $dir (holder exited without cleanup); overriding"
      rm -rf "$dir"; mkdir "$dir" 2>/dev/null || die "could not acquire lock $lock"
      break
    fi
    sleep 0.1
  done
  printf '%s' "$$" > "$dir/pid" 2>/dev/null || true
  "$@"; local rc=$?
  rm -rf "$dir" 2>/dev/null || true
  return $rc
}

# backup_existing <path> — move anything in the way into $BACKUP. Never rm.
# The installer's core promise is that it cannot lose a file you wrote yourself, so every
# destructive-looking step routes through here. Honours $DRY.
backup_existing() {
  local path="$1" base dest n=1
  [ -e "$path" ] || [ -L "$path" ] || return 0
  base="$BACKUP/$(basename "$path").pre-install.$(date +%Y%m%d-%H%M%S)"
  dest="$base"
  # Two files sharing a basename backed up in the same second must not collide.
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    dest="$base.$n"; n=$((n + 1))
  done
  if ${DRY:-false}; then
    log "  would: mv $path -> $dest"
  else
    mkdir -p "$BACKUP"
    mv "$path" "$dest"
    log "  backed up $path -> $dest"
  fi
}

# atomic_write <dest> — write stdin to dest via a temp file + rename.
# A partially written settings file is worse than no settings file.
atomic_write() {
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"; mkdir -p "$dir"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  cat > "$tmp"
  if command -v sync >/dev/null; then sync "$tmp" 2>/dev/null || sync; fi
  mv -f "$tmp" "$dest"
}

# write_if_changed <dest> — atomic_write, but leave dest untouched when content matches.
# Keeps mtimes stable so repeated installs are genuinely idempotent.
write_if_changed() {
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"; mkdir -p "$dir"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  if command -v sync >/dev/null; then sync "$tmp" 2>/dev/null || sync; fi
  mv -f "$tmp" "$dest"
}
