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

_external_load() {
  local repo="$1" scope file line a b c extra names name i j revision
  _ext_names=() _ext_scopes=() _ext_urls=() _ext_paths=() _ext_revs=()
  _ext_lock_urls=() _ext_lock_revs=()
  file="$repo/skills/external.lock"
  if [ -e "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || { warn 'external lock is unreadable'; return 1; }
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
    [ -e "$file" ] || continue
    [ -f "$file" ] && [ -r "$file" ] || { warn 'external catalog is unreadable'; return 1; }
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
