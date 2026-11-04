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
  (
    local dir="${lock}.d" tries=0 max="${WITH_LOCK_TRIES:-50}" holder rc
    local guard_owned=false dir_owned=false pid_written=false
    local processes owner self="${BASHPID:-$$}" self_seen owner_seen
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || { warn 'invalid lock retry budget'; return 1; }
    _with_lock_release_guard() {
      local recorded
      guard_owned=false
      if [ -f "$dir.reap" ] && [ ! -L "$dir.reap" ] && [ -O "$dir.reap" ] && [ -r "$dir.reap" ] \
        && recorded="$(cat "$dir.reap" 2>/dev/null)" && [ "$recorded" = "$self" ]; then
        rm "$dir.reap" || { warn "cannot release lock guard $dir.reap"; return 1; }
      else
        warn "lock guard evidence changed; preserving $dir.reap"; return 1
      fi
    }
    _with_lock_cleanup() {
      local result=$? recorded
      if $dir_owned; then
        dir_owned=false
        if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] && {
          if [ -f "$dir/pid" ] && [ ! -L "$dir/pid" ] && [ -O "$dir/pid" ] && [ -r "$dir/pid" ]; then
            recorded="$(cat "$dir/pid" 2>/dev/null)" && [ "$recorded" = "$self" ]
          else
            ! $pid_written && [ ! -e "$dir/pid" ] && [ ! -L "$dir/pid" ]
          fi
        }; then
          if rm -f "$dir/pid" && rmdir "$dir"; then :
          else warn "cannot clean up owned lock $dir"; [ "$result" != 0 ] || result=1; fi
        else
          warn "lock owner evidence changed; preserving $dir"; [ "$result" != 0 ] || result=1
        fi
      fi
      if $guard_owned; then _with_lock_release_guard || { [ "$result" != 0 ] || result=1; }; fi
      exit "$result"
    }
    trap '_with_lock_cleanup' EXIT
    trap 'exit 1' HUP INT TERM
    while :; do
      if [ ! -e "$dir.reap" ] && [ ! -L "$dir.reap" ] \
        && (set -C; printf '%s\n' "$self" > "$dir.reap") 2>/dev/null; then
        guard_owned=true
        if [ ! -e "$dir" ] && [ ! -L "$dir" ] && mkdir "$dir" 2>/dev/null; then dir_owned=true; break; fi
        tries=$((tries + 1))
        if [ "$tries" -ge "$max" ]; then
          holder=''
          if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] \
            && [ -f "$dir/pid" ] && [ ! -L "$dir/pid" ] && [ -O "$dir/pid" ] && [ -r "$dir/pid" ]; then
            holder="$(cat "$dir/pid" 2>/dev/null)" || holder=''
          fi
          if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
            _with_lock_release_guard || return 1
            continue
          fi
          processes=''; self_seen=false; owner_seen=true
          if [ -O "$dir" ] && [ -r "$dir" ] && [ -O "$dir/pid" ] && [ -r "$dir/pid" ] \
            && [[ "$holder" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$holder" 2>/dev/null \
            && processes="$(ps -e -o pid= 2>/dev/null)"; then
            owner_seen=false
            while read -r owner; do
              [[ "$owner" =~ ^[1-9][0-9]*$ ]] || { owner_seen=true; break; }
              [ "$owner" != "$self" ] || self_seen=true
              [ "$owner" != "$holder" ] || owner_seen=true
            done <<< "$processes"
          fi
          if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/pid" ] && [ ! -L "$dir/pid" ] \
            && $self_seen && ! $owner_seen; then
            rm "$dir/pid" && rmdir "$dir" && mkdir "$dir" \
              || { warn "cannot recover stale lock $dir"; return 1; }
            dir_owned=true
            break
          fi
          warn "lock $dir has a live or unknown holder; refusing to steal it"; return 1
        fi
        _with_lock_release_guard || return 1
      else
        tries=$((tries + 1))
        if [ "$tries" -ge "$max" ]; then
          warn "lock acquisition or recovery in progress: $dir"; return 1
        fi
      fi
      sleep 0.1
    done
    printf '%s\n' "$self" > "$dir/pid" || return 1
    pid_written=true
    _with_lock_release_guard || return 1
    "$@"; rc=$?
    return "$rc"
  )
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
