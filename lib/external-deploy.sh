# Source after common.sh, manifest.sh, adapters.sh and external-skills.sh.
# Caller must hold the install lock for the entire external_deploy_all call.

_external_deploy_absolute() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in /|*/|*//*|*/./*|*/.|*/../*|*/..) return 1 ;; esac
  [[ "$1" != *[[:space:][:cntrl:]]* ]]
}

# Resolve the parent physically while retaining a possibly absent leaf.
_external_deploy_location() {
  local path="$1" suffix="/${1##*/}" parent
  parent="$(dirname "$path")"
  while [ ! -d "$parent" ]; do
    [ ! -e "$parent" ] && [ ! -L "$parent" ] || return 1
    suffix="/${parent##*/}$suffix"
    parent="$(dirname "$parent")"
  done
  parent="$(cd -P "$parent" && pwd)" || return 1
  printf '%s%s\n' "${parent%/}" "$suffix"
}

# Read a strict four-field deployment record, including historic rows with absent sources.
_external_deploy_read() {
  local file="$1" line agent name path target extra key seen=() tab=$'\t'
  _ed_agents=() _ed_names=() _ed_paths=() _ed_targets=()
  [ -f "$file" ] && [ -r "$file" ] || { warn "unreadable deployment rows: $file"; return 1; }
  _external_text_safe "$file" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    IFS="$tab" read -r agent name path target extra <<< "$line"
    if [ -n "$extra" ] || [ "$line" != "$agent$tab$name$tab$path$tab$target" ] \
      || ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
      || ! _external_deploy_absolute "$path" || ! _external_deploy_absolute "$target" \
      || [ "${path##*/}" != "$name" ]; then
      warn 'invalid external deployment row'; return 1
    fi
    case "$agent" in claude|codex) ;; *) warn 'unsupported external deployment agent'; return 1 ;; esac
    key="$(_external_deploy_location "$path")" || { warn "invalid deployment parent: $path"; return 1; }
    for extra in "${seen[@]}"; do
      case "$key/" in "$extra/"*) warn 'overlapping external destinations'; return 1 ;; esac
      case "$extra/" in "$key/"*) warn 'overlapping external destinations'; return 1 ;; esac
    done
    seen+=("$key")
    _ed_agents+=("$agent") _ed_names+=("$name") _ed_paths+=("$path") _ed_targets+=("$target")
  done < "$file"
}

# Validate every desired row before deployment; an empty set can clean up a disabled profile.
_external_deploy_plan() {
  local repo="$1" file="$2" i j found root
  _external_deploy_read "$file" || return 1
  [ "${#_ed_paths[@]}" -gt 0 ] || return 0
  _external_load "$repo" || return 1
  for ((i=0; i<${#_ed_paths[@]}; i++)); do
    found=false
    for ((j=0; j<${#_ext_names[@]}; j++)); do
      [ "${_ed_names[i]}" = "${_ext_names[j]}" ] || continue
      [ "${_ext_scopes[j]}" != claude-only ] || [ "${_ed_agents[i]}" = claude ] || continue
      found=true
    done
    $found || { warn "inapplicable external skill: ${_ed_names[i]}"; return 1; }
    root="$(skills_dest_for "${_ed_agents[i]}")" || { warn 'cannot resolve skills destination'; return 1; }
    if ! _external_deploy_absolute "$root" || [ "${_ed_paths[i]}" != "$root/${_ed_names[i]}" ] \
      || [ ! -d "${_ed_targets[i]}" ] || [ ! -f "${_ed_targets[i]}/SKILL.md" ]; then
      warn "invalid external destination or missing prepared source: ${_ed_paths[i]}"; return 1
    fi
  done
}
