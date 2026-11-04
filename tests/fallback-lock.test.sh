#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/lib/common.sh"
real_cat="$(type -P cat)"
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then return 1; fi
  builtin command "$@"
}
wait_for() {
  local count=0
  until "$@"; do
    count=$((count + 1)); [ "$count" -lt 500 ] || return 1
    sleep 0.01
  done
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
refuse_without_read() (
  cat() {
    if [ "${1:-}" = "$lock.d/pid" ]; then touch "$tmp/evidence-read"; return 1; fi
    "$real_cat" "$@"
  }
  with_lock "$lock" touch "$tmp/evidence-entered"
)
if [ "${1:-}" = worker ]; then
  tmp="$2"; mode="$3"; lock="$tmp/install.lock"
  WITH_LOCK_TRIES=1
  if [ "${FALLBACK_FALSE_MKDIR:-0}" = 1 ]; then
    real_mkdir="$(type -P mkdir)"
    mkdir() {
      local status=0
      "$real_mkdir" "$@" || status=$?
      case "${1:-}" in
        "$lock.d.reap")
          if [ "$status" != 0 ] && [ -d "$1" ]; then return 0; fi ;;
      esac
      return "$status"
    }
  fi
  hold() { touch "$tmp/$mode-ready"; wait_for test -e "$tmp/release-$mode"; }
  case "$mode" in
    old|new) with_lock "$lock" hold ;;
    evidence) with_lock "$lock" touch "$tmp/evidence-entered" ;;
    reaper)
      cat() {
        local observed
        observed="$(builtin command cat "$@")"
        touch "$tmp/pid-read"
        wait_for test -e "$tmp/release-read"
        printf '%s\n' "$observed"
      }
      entered() {
        if [ -e "$tmp/new-ready" ] && [ ! -e "$tmp/release-new" ]; then touch "$tmp/overlap"; fi
        touch "$tmp/reaper-entered"
      }
      with_lock "$lock" entered
      ;;
    counter)
      increment() {
        local value
        mkdir "$tmp/active" || return 91
        value="$(cat "$tmp/count")"
        sleep 0.01
        printf '%s\n' "$((value + 1))" > "$tmp/count"
        rmdir "$tmp/active"
      }
      WITH_LOCK_TRIES=100 with_lock "$lock" increment
      ;;
    nested)
      outer() {
        (with_lock "$tmp/cache.lock" touch "$tmp/cache-ready")
        touch "$tmp/nested-ready"
        wait_for test -e "$tmp/release-nested"
      }
      with_lock "$lock" outer
      ;;
  esac
  exit
fi
tmp="$(mktemp -d)"
trap 'touch "$tmp/release-old" "$tmp/release-new" "$tmp/release-read" "$tmp/release-nested"; wait 2>/dev/null || true; rm -rf "$tmp"' EXIT
lock="$tmp/install.lock"; WITH_LOCK_TRIES=1
fifo_timeout="$(builtin command -v timeout || builtin command -v gtimeout || true)"
bash "$0" worker "$tmp" old & old=$!
wait_for test -e "$tmp/old-ready"
bash "$0" worker "$tmp" reaper & reaper=$!
wait_for test -e "$tmp/pid-read"
touch "$tmp/release-old"; wait "$old"
(status=0; bash "$0" worker "$tmp" new || status=$?; printf '%s\n' "$status" > "$tmp/new-status") & new=$!
new_attempt_finished() { [ -e "$tmp/new-ready" ] || [ -e "$tmp/new-status" ]; }
wait_for new_attempt_finished
blocked=false
if [ -e "$tmp/new-status" ] && [ ! -e "$tmp/new-ready" ]; then blocked=true; fi
touch "$tmp/release-read"
wait "$reaper"
touch "$tmp/release-new"; wait "$new"
[ "$blocked" = true ] || fail 'replacement entered while stale PID inspection paused'
[ "$(cat "$tmp/new-status")" -ne 0 ] || fail 'replacement did not refuse guarded acquisition'
[ ! -e "$tmp/overlap" ] || fail 'protected bodies overlapped'
with_lock "$lock" touch "$tmp/retry-entered"
[ -e "$tmp/retry-entered" ] && [ ! -e "$lock.d" ] && [ ! -e "$lock.d.reap" ]
printf 'PASS: stale inspection excludes replacement acquisition and permits retry\n'
printf '0\n' > "$tmp/count"
pids=()
for number in 1 2 3 4 5 6; do bash "$0" worker "$tmp" counter & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done
[ "$(cat "$tmp/count")" = 6 ] || fail 'concurrent protected updates were lost'
printf 'PASS: fallback serializes concurrent protected updates\n'
sleep 0.01 & dead=$!; wait "$dead"
mkdir "$lock.d"; printf '%s\n' "$dead" > "$lock.d/pid"
with_lock "$lock" touch "$tmp/dead-entered"
[ -e "$tmp/dead-entered" ] && [ ! -e "$lock.d" ] && [ ! -e "$lock.d.reap" ]
printf 'PASS: known-dead owner recovers and cleans up\n'
for holder in "$$" '' garbage 0 -1; do
  mkdir "$lock.d"; printf '%s\n' "$holder" > "$lock.d/pid"
  if (with_lock "$lock" touch "$tmp/refused-entry"); then fail 'live or unknown owner was stolen'; fi
  [ ! -e "$tmp/refused-entry" ] && [ "$(cat "$lock.d/pid")" = "$holder" ] && [ ! -e "$lock.d.reap" ]
  rm "$lock.d/pid"; rmdir "$lock.d"
done
mkdir "$lock.d"
if (with_lock "$lock" touch "$tmp/refused-entry"); then fail 'unpublished owner was stolen'; fi
[ -d "$lock.d" ] && [ ! -e "$lock.d.reap" ]; rmdir "$lock.d"
mkdir "$lock.d.reap"
if (with_lock "$lock" touch "$tmp/refused-entry"); then fail 'unknown recovery guard was stolen'; fi
[ -d "$lock.d.reap" ] && [ ! -e "$lock.d" ]; rmdir "$lock.d.reap"
printf 'PASS: live and unknown owners and recovery guards remain untouched\n'
printf 'guard-sentinel\n' > "$tmp/guard-target"
for artifact in regular fifo symlink dangling; do
  case "$artifact" in
    regular) printf 'guard-sentinel\n' > "$lock.d.reap" ;;
    fifo) mkfifo "$lock.d.reap" ;;
    symlink) ln -s "$tmp/guard-target" "$lock.d.reap" ;;
    dangling) ln -s "$tmp/missing-target" "$lock.d.reap" ;;
  esac
  if [ -n "$fifo_timeout" ]; then
    status=0; "$fifo_timeout" -k 1 2 bash "$0" worker "$tmp" evidence || status=$?
    [ "$status" = 1 ] || fail "guard artifact did not refuse promptly ($artifact status=$status)"
  elif [ "$artifact" != fifo ]; then
    if (with_lock "$lock" touch "$tmp/evidence-entered"); then fail 'guard artifact was stolen'; fi
  fi
  [ ! -e "$tmp/evidence-entered" ] && [ ! -e "$lock.d" ] || fail 'guard artifact admitted a protected command'
  case "$artifact" in
    regular) [ "$(cat "$lock.d.reap")" = guard-sentinel ] || fail 'existing guard was truncated' ;;
    fifo) [ -p "$lock.d.reap" ] || fail 'FIFO guard changed' ;;
    symlink|dangling) [ -L "$lock.d.reap" ] || fail 'guard symlink changed' ;;
  esac
  [ "$(cat "$tmp/guard-target")" = guard-sentinel ] || fail 'guard symlink target changed'
  rm "$lock.d.reap"
done
printf 'PASS: existing guard artifacts remain untouched and do not block inspection\n'
mkdir "$lock.d"; printf '%s\n' "$$" > "$lock.d/pid"
status=0
(
  main_mkdir="$(type -P mkdir)"
  mkdir() {
    local status=0
    "$main_mkdir" "$@" || status=$?
    if [ "${1:-}" = "$lock.d" ] && [ -d "$1" ]; then return 0; fi
    return "$status"
  }
  with_lock "$lock" touch "$tmp/false-main-entered"
) || status=$?
[ "$status" = 1 ] && [ ! -e "$tmp/false-main-entered" ] \
  && [ "$(cat "$lock.d/pid")" = "$$" ] || fail 'false-success mkdir stole a live main lock'
rm "$lock.d/pid"; rmdir "$lock.d"
printf 'PASS: false-success mkdir cannot claim a preexisting main lock\n'


mkdir "$lock.d"; printf '%s\n' "$$" > "$lock.d/pid"
if (
  kill() { return 1; }
  with_lock "$lock" touch "$tmp/inaccessible-entry"
); then fail 'inaccessible live owner was stolen'; fi
[ ! -e "$tmp/inaccessible-entry" ] && [ "$(cat "$lock.d/pid")" = "$$" ]
rm "$lock.d/pid"; rmdir "$lock.d"
for inspection in unavailable empty malformed missing-self; do
  mkdir "$lock.d"; printf '%s\n' "$dead" > "$lock.d/pid"
  if (
    ps() {
      case "$inspection" in unavailable) return 127 ;; empty) return 0 ;; malformed) echo unknown ;; missing-self) echo 1 ;; esac
    }
    with_lock "$lock" touch "$tmp/unknown-entry"
  ); then fail 'ambiguous process inspection authorized recovery'; fi
  [ ! -e "$tmp/unknown-entry" ] && [ "$(cat "$lock.d/pid")" = "$dead" ]
  rm "$lock.d/pid"; rmdir "$lock.d"
done
printf 'PASS: inaccessible live owners and ambiguous process inspection refuse recovery\n'
for evidence in -O -r -x; do
  mkdir "$lock.d"; printf '%s\n' "$dead" > "$lock.d/pid"
  status=0
  (
    [() {
      if builtin [ "$1" = "$evidence" ] && { builtin [ "${2:-}" = "$lock.d" ] || builtin [ "${2:-}" = "$lock.d/pid" ]; }; then return 1; fi
      builtin [ "$@"
    }
    refuse_without_read
  ) || status=$?
  [ "$status" = 1 ] || fail 'foreign-owned or unreadable evidence was recovered'
  [ ! -e "$tmp/evidence-read" ] && [ ! -e "$tmp/evidence-entered" ] \
    && [ "$(cat "$lock.d/pid")" = "$dead" ] || fail 'unsafe owner evidence was read or modified'
  rm "$lock.d/pid"; rmdir "$lock.d"
done
printf 'PASS: foreign-owned or unreadable lock evidence is preserved\n'
mkdir "$lock.d"; mkfifo "$lock.d/pid"
if [ -n "$fifo_timeout" ]; then
  status=0
  "$fifo_timeout" -k 1 2 bash "$0" worker "$tmp" evidence || status=$?
  [ "$status" = 1 ] || fail "FIFO owner inspection did not refuse within budget (status=$status)"
else
  printf 'SKIP: timeout unavailable; FIFO no-read assertion still runs\n'
fi
if refuse_without_read; then fail 'FIFO owner evidence was accepted'; fi
[ -p "$lock.d/pid" ] && [ ! -e "$tmp/evidence-read" ] \
  && [ ! -e "$tmp/evidence-entered" ] && [ ! -e "$lock.d.reap" ] || fail 'FIFO evidence was read or changed'
rm "$lock.d/pid"; rmdir "$lock.d"
printf 'PASS: FIFO owner evidence is refused without reading or waiting for a writer\n'

mkdir "$tmp/foreign-dir"; printf '%s\n' "$dead" > "$tmp/foreign-dir/pid"
ln -s "$tmp/foreign-dir" "$lock.d"
if refuse_without_read; then fail 'symlink lock directory was recovered'; fi
[ ! -e "$tmp/evidence-read" ] && [ ! -e "$tmp/evidence-entered" ] || fail 'symlink evidence was read'
[ -L "$lock.d" ] && [ "$(cat "$tmp/foreign-dir/pid")" = "$dead" ]; rm "$lock.d"
mkdir "$lock.d"; ln -s "$tmp/foreign-dir/pid" "$lock.d/pid"
if refuse_without_read; then fail 'symlink owner evidence was recovered'; fi
[ ! -e "$tmp/evidence-read" ] && [ ! -e "$tmp/evidence-entered" ] || fail 'symlink evidence was read'
[ -L "$lock.d/pid" ] && [ "$(cat "$tmp/foreign-dir/pid")" = "$dead" ]
rm "$lock.d/pid"; rmdir "$lock.d"
printf 'PASS: symlink lock directories and owner evidence remain untouched\n'
for replacement in regular fifo symlink directory; do
  status=0
  (
    printf() {
      builtin printf "$@"
      if ${guard_owned:-false} && ${dir_owned:-false}; then
        if [ -d "$dir.reap" ] && [ ! -L "$dir.reap" ]; then rmdir "$dir.reap"; else rm "$dir.reap"; fi
        case "$replacement" in
          regular) builtin printf 'substituted-guard\n' > "$dir.reap" ;;
          fifo) mkfifo "$dir.reap" ;;
          symlink) ln -s "$tmp/guard-target" "$dir.reap" ;;
          directory) mkdir "$dir.reap" ;;
        esac
      fi
    }
    with_lock "$lock" touch "$tmp/retarget-entered"
  ) || status=$?
  [ "$status" = 1 ] && [ ! -e "$tmp/retarget-entered" ] || fail "substituted guard was accepted ($replacement)"
  case "$replacement" in
    regular) [ "$(cat "$lock.d.reap")" = substituted-guard ] || fail 'substituted guard was removed' ;;
    fifo) [ -p "$lock.d.reap" ] || fail 'substituted FIFO guard was removed' ;;
    symlink) [ -L "$lock.d.reap" ] || fail 'retargeted guard was removed' ;;
    directory) [ -d "$lock.d.reap" ] || fail 'substituted guard directory was removed' ;;
  esac
  if [ "$replacement" = directory ]; then rmdir "$lock.d.reap"; else rm "$lock.d.reap"; fi
done
printf 'PASS: guard cleanup preserves substituted artifacts and reports failure\n'
retarget_pid() {
  rm "$lock.d/pid"
  case "$replacement" in
    regular) printf 'substituted-owner\n' > "$lock.d/pid" ;;
    symlink) ln -s "$tmp/guard-target" "$lock.d/pid" ;;
  esac
}
for replacement in regular symlink; do
  status=0; with_lock "$lock" retarget_pid || status=$?
  [ "$status" = 1 ] && [ -e "$lock.d/pid" ] \
    && [ "$(cat "$tmp/guard-target")" = guard-sentinel ] || fail 'main cleanup removed substituted owner evidence'
  if [ "$replacement" = regular ]; then
    [ "$(cat "$lock.d/pid")" = substituted-owner ] || fail 'main cleanup changed substituted PID evidence'
  else
    [ -L "$lock.d/pid" ] || fail 'main cleanup removed retargeted PID evidence'
  fi
  rm "$lock.d/pid"; rmdir "$lock.d"
done
replacement=regular
retarget_pid_error() { retarget_pid; return 23; }
status=0; with_lock "$lock" retarget_pid_error || status=$?
[ "$status" = 23 ] && [ "$(cat "$lock.d/pid")" = substituted-owner ] || fail 'cleanup refusal hid the protected command error'
rm "$lock.d/pid"; rmdir "$lock.d"
printf 'PASS: main cleanup preserves retargeted PID evidence and reports failure\n'

status=0
with_lock "$lock" bash -c 'exit 23' || status=$?
[ "$status" = 23 ] && [ ! -e "$lock.d" ] && [ ! -e "$lock.d.reap" ]
if bash -e -c '. "$1/lib/common.sh"; command() { if [ "$*" = "-v flock" ]; then return 1; fi; builtin command "$@"; }; with_lock "$2" bash -c "exit 24"' _ "$REPO" "$lock"; then
  fail 'errexit protected error disappeared'
else
  [ "$?" = 24 ] && [ ! -e "$lock.d" ] && [ ! -e "$lock.d.reap" ]
fi
with_lock "$lock" true
status=0
bash -e -c '
  . "$1/lib/common.sh"
  command() { if [ "$*" = "-v flock" ]; then return 1; fi; builtin command "$@"; }
  action() { false; touch "$3/continued-after-error"; }
  with_lock "$2" action "$@"
' _ "$REPO" "$lock" "$tmp" || status=$?
[ "$status" = 1 ] && [ ! -e "$tmp/continued-after-error" ] \
  && [ ! -e "$lock.d" ] && [ ! -e "$lock.d.reap" ] || fail 'callback internal error bypassed errexit'
printf 'PASS: protected-command errors propagate and release ownership\n'
bash "$0" worker "$tmp" nested & nested=$!
wait_for test -e "$tmp/nested-ready"
[ -e "$tmp/cache-ready" ] && [ ! -e "$tmp/cache.lock.d" ]
if (with_lock "$lock" touch "$tmp/parent-overlap"); then fail 'nested child released parent install lock'; fi
[ ! -e "$tmp/parent-overlap" ]
touch "$tmp/release-nested"; wait "$nested"
with_lock "$lock" touch "$tmp/parent-retry"
[ -e "$tmp/parent-retry" ] && [ ! -e "$lock.d" ]
printf 'PASS: child cache lock preserves waiting parent install lock\n'

before_options="$-"
with_lock "$lock" true
[ "$before_options" = "$-" ] || fail 'claim changed parent shell options'
(
  set -C
  with_lock "$lock" true
  case "$-" in *C*) ;; *) fail 'claim disabled inherited noclobber' ;; esac
)
printf 'PASS: guard claims preserve parent and inherited noclobber options\n'
if [ "${FALLBACK_FALSE_MKDIR:-0}" = 0 ]; then
  FALLBACK_FALSE_MKDIR=1 bash "$0"
  printf 'PASS: false-success mkdir cannot bypass fallback ownership\n'
fi
