# lib/manifest.sh — track the artifacts this repo deploys, fail-closed.
# Source after common.sh.
#
# The manifest lives in per-machine state, never in the repo, because which artifacts exist is a
# property of the machine. It is what lets `install.sh check` distinguish "something we deployed
# and that is now wrong" from "a file the user put there", and lets us clean up only our own.
#
# Two kinds of record, because there are two ways to deploy an artifact:
#
#   link<TAB>/path/to/dest              a symlink we created; the source is the repo file
#   copy<TAB>/path/to/dest<TAB>DIGEST   a file whose content we generated, plus its sha256
#
# Known limitation (not fixed here — pathological input, tracked as a V2 item): a path
# containing a newline splits across manifest records, since records are newline-delimited and
# tab-separated. This repo's own paths never contain one; treat a manifest that looks corrupt
# after installing into an unusual HOME as a symptom of this rather than a new bug.
#
# A link cannot drift — it has no content of its own, so reading it always yields the repo. A
# copy can: once bytes are duplicated onto disk, someone can edit the copy and the two versions
# diverge silently, with the agent loading the stale one forever. Recording the digest at deploy
# time is what makes that divergence detectable instead of invisible. Every artifact install.sh
# deploys goes through `managed_link` or `managed_copy`; nothing is written to a user path
# outside them. See docs/provenance.md.

: "${MANIFEST:=${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/links}"

# _manifest_digest <path> — sha256 of a file, or "-" when it cannot be computed.
# Three implementations because no single one is present everywhere: macOS ships shasum,
# most Linux ships sha256sum, and openssl is the fallback. "-" means "recorded without a
# digest"; check reports those as unverifiable rather than silently passing them.
_manifest_digest() {
  local f="$1"
  [ -f "$f" ] || { printf '%s\n' '-'; return 0; }
  if   command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$f"     | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"         | awk '{print $1}'
  elif command -v openssl   >/dev/null 2>&1; then openssl dgst -sha256 "$f" | awk '{print $NF}'
  else printf '%s\n' '-'
  fi
}

# _manifest_record <kind> <path> [digest] — upsert one record, keyed on path.
# Upsert rather than append: re-deploying a copy must replace its old digest, or check would
# compare the new file against a stale hash and report drift on every correct install.
_manifest_record() {
  local kind="$1" path="$2" digest="${3:-}" tmp
  mkdir -p "$(dirname "$MANIFEST")"; touch "$MANIFEST"
  # Stage beside the manifest, not in /tmp: the replacing mv is only atomic within one
  # filesystem, and a truncated manifest loses track of artifacts already on disk.
  tmp="$(mktemp "$(dirname "$MANIFEST")/.links.XXXXXX")"
  # Drop any existing record for this path, whatever its kind, then write the current one.
  # If the rewrite itself fails (I/O error, awk missing), the temp file may be truncated —
  # replacing the manifest with it would silently discard every ownership record, so abort
  # and leave the real manifest untouched instead.
  if ! awk -F'\t' -v p="$path" '$0 !~ /^$/ && $2 != p && $1 != p' "$MANIFEST" > "$tmp"; then
    rm -f "$tmp"; die "manifest rewrite failed for $path; manifest left untouched"
  fi
  if [ -n "$digest" ]; then
    printf '%s\t%s\t%s\n' "$kind" "$path" "$digest" >> "$tmp"
  else
    printf '%s\t%s\n' "$kind" "$path" >> "$tmp"
  fi
  mv -f "$tmp" "$MANIFEST"
}

# _manifest_parse <line> — split a record into _mf_kind / _mf_path / _mf_digest.
# Earlier versions wrote a bare path per line and only ever tracked links, so a line with no
# tab is a link record. Reading an old manifest must not error; it predates the format.
_manifest_parse() {
  local line="$1" rest tab
  tab="$(printf '\t')"
  _mf_kind=link; _mf_path="$line"; _mf_digest='-'
  case "$line" in
    *"$tab"*)
      _mf_kind="${line%%"$tab"*}"
      rest="${line#*"$tab"}"
      case "$rest" in
        *"$tab"*) _mf_path="${rest%%"$tab"*}"; _mf_digest="${rest#*"$tab"}" ;;
        *)        _mf_path="$rest" ;;
      esac
      ;;
  esac
}

# managed_link <src> <dest> — symlink dest -> src and record it.
# Never delete: anything already at dest that is not already our link is the user's, so it is
# backed up (via backup_existing, same as every other in-the-way file) before dest is replaced
# — matching the README/matrix claim that nothing in the way is ever silently skipped or lost.
managed_link() {
  local src="$1" dest="$2"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    _manifest_record link "$dest" "$src"; return 0
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    backup_existing "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest" || { warn "failed to link $dest -> $src"; return 1; }
  _manifest_record link "$dest" "$src"
  log "linked $dest -> $src"
}

# manifest_forget <path> — drop the manifest record for <path>, and if it is still exactly the
# link we recorded, remove it. Used when a profile change stops syncing something previously
# installed (e.g. skills on a personal -> work switch): the record must not survive un-synced.
manifest_forget() {
  local path="$1" tmp
  [ -f "$MANIFEST" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _manifest_parse "$line"
    if [ "$_mf_path" = "$path" ] && [ "$_mf_kind" = "link" ] && [ -L "$path" ]; then
      if [ "$(readlink "$path")" = "$_mf_digest" ]; then
        rm -f "$path"
        log "removed $path (no longer synced under this profile)"
      elif [ "$_mf_digest" = "-" ] && [ -n "${REPO:-}" ] \
           && case "$(readlink "$path")" in "$REPO"/*) true ;; *) false ;; esac; then
        # Pre-format bare record: no target was stored, but the live link points into this
        # repo, so it is ours — remove it rather than orphan it while dropping its record.
        rm -f "$path"
        log "removed $path (legacy record; link target confirmed in-repo)"
      fi
    fi
  done < "$MANIFEST"
  tmp="$(mktemp "$(dirname "$MANIFEST")/.links.XXXXXX")"
  # Same fail-closed rule as _manifest_record: never replace the manifest with the output of
  # a rewrite that did not succeed.
  if ! awk -F'\t' -v p="$path" '$0 !~ /^$/ && $2 != p && $1 != p' "$MANIFEST" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die "manifest rewrite failed for $path; manifest left untouched"
  fi
  mv -f "$tmp" "$MANIFEST"
}

# managed_copy <dest> — write stdin to dest as a tracked copy, recording its digest.
# For the artifacts that genuinely cannot be symlinks: a shim whose content is generated
# per-machine, not a file that exists in the repo. Anything already at dest that we did not
# write is the user's and is backed up first, never overwritten in place.
#
# Reconciliation direction: install rewrites a drifted copy (after backing the drifted version
# up, so nothing is lost); check only reports it. Repair belongs to install; check stays
# read-only so it is safe to run anywhere, including CI.
managed_copy() {
  local dest="$1" dir tmp
  # Dry run returns before anything touches the filesystem — not even the mkdir below, since
  # creating the parent directory would already break the promise that --dry-run changes
  # nothing. Stdin is drained so the process producing the content does not die on SIGPIPE.
  if ${DRY:-false}; then
    cat > /dev/null
    log "  would: write managed copy $dest"
    return 0
  fi

  # The staging file lives in the destination directory, not /tmp: mv is only atomic within a
  # filesystem, and a half-written rules file is worse than an absent one.
  dir="$(dirname "$dest")"; mkdir -p "$dir"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  cat > "$tmp"

  # -L as well as -f: a symlink at dest resolves to a file, so cmp alone would call it correct
  # and record it as a copy, which check then reports as replaced-by-symlink. Install and check
  # must agree on what "correct" means, so treat a link here as something to replace.
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$tmp" "$dest"; then
    # Already correct. Still record it: the file may predate the manifest, or the manifest may
    # have been lost, and an untracked-but-correct copy would escape drift detection forever.
    rm -f "$tmp"
    _manifest_record copy "$dest" "$(_manifest_digest "$dest")"
    return 0
  fi
  backup_existing "$dest"
  if command -v sync >/dev/null; then sync "$tmp" 2>/dev/null || sync; fi
  mv -f "$tmp" "$dest"
  _manifest_record copy "$dest" "$(_manifest_digest "$dest")"
}

# manifest_prune_dangling — remove links we own whose target no longer exists
# (e.g. a skill directory that was renamed or deleted). Only touches manifest entries.
# Copies are never pruned: a missing copy is a fact to report, not a stale pointer to clean up.
# Typed links require the recorded target. Legacy bare records require an existing physical
# parent inside this rulebook's skills directory; unresolved paths and symlink leaves survive.
manifest_prune_dangling() {
  [ -f "$MANIFEST" ] || return 0
  local keep line target owned tab skills_root target_parent
  tab="$(printf '\t')"
  keep="$(mktemp "$(dirname "$MANIFEST")/.links.XXXXXX")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _manifest_parse "$line"
    if [ "$_mf_kind" = "link" ] && [ -L "$_mf_path" ] && [ ! -e "$_mf_path" ]; then
      owned=false
      target="$(readlink "$_mf_path")"
      case "$line" in
        *"$tab"*)
          if [ "$_mf_digest" != '-' ] && [ "$target" = "$_mf_digest" ]; then
            owned=true
          fi
          ;;
        *)
          if [ -n "${REPO:-}" ] && [ -d "$REPO/skills" ]; then
            case "$target" in
              /*) ;;
              *) target="$(dirname "$_mf_path")/$target" ;;
            esac
            if [ ! -L "$target" ] \
               && skills_root="$(cd -P "$REPO/skills" && pwd)" \
               && target_parent="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)"; then
              case "$target_parent" in
                "$skills_root"|"$skills_root"/*) owned=true ;;
              esac
            fi
          fi
          ;;
      esac
      if $owned; then
        rm -f "$_mf_path"; log "pruned dangling link $_mf_path"
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$keep"
  done < "$MANIFEST"
  mv -f "$keep" "$MANIFEST"
}

# manifest_check — report managed artifacts that are missing, dangling, or drifted.
# Never repairs; `install.sh` does that. Returns nonzero if anything is wrong.
#
# A missing manifest is NOT treated as "nothing to check, so pass": on a machine that has
# actually run install.sh, the manifest existing is itself part of what's being verified, and on
# a machine that never has, `check` has nothing to say and should not claim otherwise. Either
# way, silently returning success here is how "check" stops meaning anything.
manifest_check() {
  if [ ! -f "$MANIFEST" ]; then
    echo "WARN: no manifest at $MANIFEST — nothing has been installed, or state was lost; run install.sh"
    return 1
  fi
  local line now bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _manifest_parse "$line"
    case "$_mf_kind" in
      link)
        if [ ! -L "$_mf_path" ]; then
          if [ -e "$_mf_path" ]; then
            # Deployed as a link, found as content: someone replaced the pointer with a real
            # file, so what loads is no longer sourced from the repo.
            echo "FAIL: managed link $_mf_path was replaced by a regular file"; bad=1
          else
            echo "FAIL: missing managed link $_mf_path"; bad=1
          fi
        elif [ ! -e "$_mf_path" ]; then
          echo "FAIL: dangling managed link $_mf_path"; bad=1
        elif [ "$_mf_digest" != '-' ] && [ "$(readlink "$_mf_path")" != "$_mf_digest" ]; then
          # _mf_digest holds the recorded link target for link records (see _manifest_record).
          # A legacy record with no target recorded ('-') skips this check rather than false-failing.
          echo "FAIL: managed link $_mf_path points to $(readlink "$_mf_path"), expected $_mf_digest"
          bad=1
        fi
        ;;
      copy)
        if [ ! -e "$_mf_path" ]; then
          echo "FAIL: missing managed copy $_mf_path"; bad=1
        elif [ -L "$_mf_path" ]; then
          # Deployed as content, found as a link: someone replaced the artifact with a
          # pointer somewhere else, so what loads is no longer what we wrote.
          echo "FAIL: managed copy $_mf_path was replaced by a symlink"; bad=1
        elif [ "$_mf_digest" = "-" ]; then
          # Recorded without a digest means drift here is undetectable by construction — that is
          # a check failure, not a note, or a machine with no hasher silently gets no protection.
          echo "FAIL: managed copy $_mf_path recorded without a digest (no hasher available at"
          echo "      deploy time) — drift on this artifact cannot be detected; install a hasher"
          echo "      (shasum, sha256sum, or openssl) and re-run install.sh"
          bad=1
        else
          now="$(_manifest_digest "$_mf_path")"
          if [ "$now" != "$_mf_digest" ]; then
            echo "FAIL: drifted managed copy $_mf_path — edited outside this repo; the source of"
            echo "      truth and the deployed file no longer match. Re-run install.sh to"
            echo "      restore it (the drifted version is backed up, not discarded)."
            bad=1
          fi
        fi
        ;;
      *)
        echo "FAIL: unrecognized manifest record kind '$_mf_kind' for $_mf_path"; bad=1
        ;;
    esac
  done < "$MANIFEST"
  return $bad
}
