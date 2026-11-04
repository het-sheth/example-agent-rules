# Source after common.sh, profile.sh and adapters.sh. No deployment happens here.

external_catalog_path() {
  case "$2" in
    portable) printf '%s/skills/external.list\n' "$1" ;;
    claude-only) printf '%s/skills/claude-only.list\n' "$1" ;;
    *) warn 'unsupported external catalog scope'; return 2 ;;
  esac
}

external_local_names() {
  local dir
  for dir in "$1"/skills/*/; do
    [ -d "$dir" ] || continue
    basename "${dir%/}"
  done
}

external_skill_selected() {
  case "$3" in claude|codex) ;; *) return 2 ;; esac
  sync_enabled skills || return 1
  adapter_detected "$3"
}

if ! declare -F skills_dest_for >/dev/null; then
  skills_dest_for() {
    case "$1" in
      claude) printf '%s/.claude/skills\n' "$HOME" ;;
      codex) printf '%s/.agents/skills\n' "$HOME" ;;
      *) return 2 ;;
    esac
  }
fi

_external_url_safe() {
  case "$1" in
    https://*)
      [[ "$1" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?/[A-Za-z0-9._~/-]+$ ]] || return 1
      ;;
    file:///*) [[ "$1" =~ ^file:///[A-Za-z0-9._~/-]+$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  case "${1#*://}" in */../*|*/..|*/./*|*/.|*//*|*/) return 1 ;; esac
}

_external_path_safe() {
  [ "$1" = . ] && return 0
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || return 1
  case "$1" in */../*|*/..|*/./*|*/.|*//*|*/) return 1 ;; esac
}

_external_text_safe() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' < "$1" | cmp -s "$1" - \
    || { warn 'external catalog or lock contains control bytes'; return 1; }
}

_external_load() {
  local repo="$1" scope file line a b c extra names name i j revision
  _ext_names=() _ext_scopes=() _ext_urls=() _ext_paths=() _ext_revs=()
  _ext_lock_urls=() _ext_lock_revs=()
  file="$repo/skills/external.lock"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || { warn 'external lock is unreadable'; return 1; }
    _external_text_safe "$file" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      read -r a b extra <<< "$line"
      [ -n "$a" ] || continue
      [[ "$a" = \#* ]] && continue
      if [ -n "$extra" ] || ! _external_url_safe "$a" || ! [[ "$b" =~ ^[0-9a-f]{40}$ ]]; then
        warn 'invalid external lock row (expected URL and full lowercase SHA-1)'; return 1
      fi
      for name in "${_ext_lock_urls[@]}"; do
        [ "$name" != "$a" ] || { warn "duplicate external lock: $a"; return 1; }
      done
      _ext_lock_urls+=("$a") _ext_lock_revs+=("$b")
    done < "$file"
  fi
  names="$(external_local_names "$repo")" || { warn 'cannot list local skills'; return 1; }
  local seen=()
  while IFS= read -r name; do
    [ -n "$name" ] && seen+=("$name")
  done <<< "$names"
  for scope in portable claude-only; do
    file="$(external_catalog_path "$repo" "$scope")" || { warn 'cannot resolve external catalog'; return 1; }
    [ -e "$file" ] || [ -L "$file" ] || continue
    [ -f "$file" ] && [ -r "$file" ] || { warn 'external catalog is unreadable'; return 1; }
    _external_text_safe "$file" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      read -r a b c extra <<< "$line"
      [ -n "$a" ] || continue
      [[ "$a" = \#* ]] && continue
      if [ -n "$extra" ] || ! [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || ! _external_url_safe "$b" || ! _external_path_safe "$c"; then
        warn 'invalid external catalog row (expected safe name URL relative-path)'; return 1
      fi
      for name in "${seen[@]}"; do
        [ "$name" != "$a" ] || { warn "duplicate skill name: $a"; return 1; }
      done
      revision=''
      for ((j=0; j<${#_ext_lock_urls[@]}; j++)); do
        [ "${_ext_lock_urls[j]}" != "$b" ] || revision="${_ext_lock_revs[j]}"
      done
      [ -n "$revision" ] || { warn "missing external lock: $b"; return 1; }
      seen+=("$a")
      _ext_names+=("$a") _ext_scopes+=("$scope") _ext_urls+=("$b")
      _ext_paths+=("$c") _ext_revs+=("$revision")
    done < "$file"
  done
}

external_skills_validate() {
  _external_load "$1"
}

# TSV: agent, name, exact URL, relative path, locked revision.
_external_selected_rows() {
  _external_load "$1" || return 1
  local i agent rc result=''
  for ((i=0; i<${#_ext_names[@]}; i++)); do
    for agent in claude codex; do
      [ "${_ext_scopes[i]}" != claude-only ] || [ "$agent" = claude ] || continue
      if external_skill_selected "$1" "${_ext_names[i]}" "$agent"; then rc=0; else rc=$?; fi
      case "$rc" in
        0) result+="$(printf '%s\t%s\t%s\t%s\t%s' "$agent" "${_ext_names[i]}" \
             "${_ext_urls[i]}" "${_ext_paths[i]}" "${_ext_revs[i]}")"$'\n' ;;
        1) ;;
        *) warn "external selection failed: ${_ext_names[i]} ($agent)"; return "$rc" ;;
      esac
    done
  done
  printf '%s' "$result"
}

_external_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_EXEC_PATH
  unset GIT_REPLACE_REF_BASE GIT_GRAFT_FILE GIT_NAMESPACE
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.fileMode=true -c submodule.recurse=false \
    -c protocol.allow=never -c protocol.https.allow=always -c protocol.file.allow=always \
    -c credential.helper= "$@"
)

_external_cache_entry() {
  local cache="$1" url="$2" revision="$3" digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s\n%s\n' "$url" "$revision" | shasum -a 256)" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\n%s\n' "$url" "$revision" | sha256sum)" || return 1
  else
    warn 'external cache requires shasum or sha256sum'; return 1
  fi
  printf '%s/%s\n' "$cache" "${digest%% *}"
}

_external_content_path() {
  local entry="$1" relative="$2" dir file parent target hops=0
  dir="$(cd -P "$entry/$relative" 2>/dev/null && pwd)" || return 1
  case "$dir" in "$entry"|"$entry"/*) ;; *) return 1 ;; esac
  file="$dir/SKILL.md"
  while [ -L "$file" ]; do
    hops=$((hops + 1)); [ "$hops" -le 40 ] || return 1
    target="$(readlink "$file")" || return 1
    case "$target" in /*) file="$target" ;; *) file="$(dirname "$file")/$target" ;; esac
  done
  parent="$(cd -P "$(dirname "$file")" 2>/dev/null && pwd)" || return 1
  case "$parent" in "$entry"|"$entry"/*) ;; *) return 1 ;; esac
  [ -f "$parent/$(basename "$file")" ] || return 1
  printf '%s\n' "$dir"
}

_external_cache_config_safe() {
  local entry="$1" keys name
  [ -f "$entry/.git/config" ] && [ ! -L "$entry/.git/config" ] \
    || { warn 'external cache config is missing or a symlink'; return 1; }
  _external_text_safe "$entry/.git/config" || return 1
  keys="$(_external_git config --file "$entry/.git/config" --no-includes --name-only --list)" || return 1
  while IFS= read -r name; do
    case "$name" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|core.ignorecase|core.precomposeunicode|remote.origin.url|remote.origin.fetch) ;;
      *) warn "unsupported external cache config: $name"; return 1 ;;
    esac
  done <<< "$keys"
}

_external_verify_entry() {
  local entry="$1" url="$2" revision="$3" paths="$4" path top actual origin status flags
  [ -d "$entry" ] && [ ! -L "$entry" ] && [ -d "$entry/.git" ] && [ ! -L "$entry/.git" ] \
    && [ ! -e "$entry/.git/objects/info/alternates" ] \
    && [ ! -e "$entry/.git/info/grafts" ] && [ ! -L "$entry/.git/info/grafts" ] \
    || { warn "invalid external cache directory: $entry"; return 1; }
  _external_cache_config_safe "$entry" || return 1
  top="$(_external_git -C "$entry" rev-parse --show-toplevel)" || return 1
  origin="$(_external_git -C "$entry" config --local --no-includes --get-all remote.origin.url && printf '.')" || return 1
  actual="$(_external_git -C "$entry" rev-parse --verify 'HEAD^{commit}')" || return 1
  [ "$top" = "$entry" ] && [ "$origin" = "$url"$'\n.' ] && [ "$actual" = "$revision" ] \
    || { warn "external cache origin or revision mismatch: $entry"; return 1; }
  flags="$(_external_git -C "$entry" ls-files -v)" || return 1
  case "$flags" in [a-zS]\ *|*$'\n'[a-zS]\ *)
    warn "external cache hides index changes: $entry"; return 1 ;;
  esac
  status="$(_external_git -C "$entry" status --porcelain --untracked-files=all --ignored)" || return 1
  [ -z "$status" ] || { warn "dirty external cache (left unchanged): $entry"; return 1; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    _external_content_path "$entry" "$path" >/dev/null \
      || { warn "missing or escaping external SKILL.md: $path"; return 1; }
  done <<< "$paths"
}

_external_prepare_one() (
  local cache="$1" url="$2" revision="$3" paths="$4" entry stage
  entry="$(_external_cache_entry "$cache" "$url" "$revision")" || return 1
  if [ -e "$entry" ] || [ -L "$entry" ]; then
    _external_verify_entry "$entry" "$url" "$revision" "$paths"
    return
  fi
  stage="$(mktemp -d "$cache/.agent-rules-stage.XXXXXX")" || return 1
  trap 'rm -rf "$stage"' EXIT
  printf '%s\n' agent-rules-external-cache-v1 > "$stage/installer-stage" || return 1
  _external_git init -q --template= "$stage/repo" \
    && _external_git -C "$stage/repo" remote add origin "$url" \
    && _external_git -C "$stage/repo" fetch --no-tags --depth=1 origin "$revision" >&2 \
    && _external_git -C "$stage/repo" checkout -q --detach "$revision" \
    && _external_verify_entry "$stage/repo" "$url" "$revision" "$paths" \
    || { warn "cannot prepare locked external source: $url ($revision)"; return 1; }
  mv "$stage/repo" "$entry" || return 1
)

_external_prepare_locked() {
  local cache="$1" rows="$2" agent name url path revision entry key seen='' paths
  local other_agent other_name other_url other_path other_revision
  while IFS=$'\t' read -r agent name url path revision; do
    [ -n "$agent" ] || continue
    entry="$(_external_cache_entry "$cache" "$url" "$revision")" || return 1
    key="${entry##*/}"
    case "$seen" in *"|$key|"*) continue ;; esac
    paths=''
    while IFS=$'\t' read -r other_agent other_name other_url other_path other_revision; do
      if [ "$other_url" = "$url" ] && [ "$other_revision" = "$revision" ]; then
        paths+="$other_path"$'\n'
      fi
    done <<< "$rows"
    _external_prepare_one "$cache" "$url" "$revision" "$paths" || return 1
    seen+="|$key|"
  done <<< "$rows"
  local result='' target
  while IFS=$'\t' read -r agent name url path revision; do
    [ -n "$agent" ] || continue
    entry="$(_external_cache_entry "$cache" "$url" "$revision")" || return 1
    target="$(_external_content_path "$entry" "$path")" || return 1
    result+="$(printf '%s\t%s\t%s' "$agent" "$name" "$target")"$'\n'
  done <<< "$rows"
  printf '%s' "$result"
}

# TSV: agent, name, absolute prepared skill directory. No partial result on failure.
external_skills_prepare() {
  local rows cache="$2"
  rows="$(_external_selected_rows "$1")" || return 1
  [ -n "$rows" ] || return 0
  case "$cache" in *$'\n'*|*$'\t'*|'') warn 'invalid external cache path'; return 1 ;; esac
  mkdir -p "$cache" || return 1
  cache="$(cd -P "$cache" && pwd)" || return 1
  [ ! -L "$cache/.prepare.lock" ] || { warn 'external cache lock is a symlink'; return 1; }
  # with_lock owns fd 9; a child must replace it while the parent retains its install lock.
  (with_lock "$cache/.prepare.lock" _external_prepare_locked "$cache" "$rows")
}
