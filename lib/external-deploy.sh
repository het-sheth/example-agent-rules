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

_external_deploy_owned() {
  local path="$1" target="$2" line matches=0 valid=false
  [ -L "$path" ] && [ "$(readlink "$path")" = "$target" ] && [ -f "$MANIFEST" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    _manifest_parse "$line"
    [ "$_mf_path" = "$path" ] || continue
    matches=$((matches + 1))
    [ "$line" != "link"$'\t'"$path"$'\t'"$target" ] || valid=true
  done < "$MANIFEST"
  [ "$matches" -eq 1 ] && $valid
}

# Track only directories absent before this attempt, including a partly failed mkdir.
_external_deploy_mkdir() {
  local dir="$1" parent="$1"
  while [ ! -d "$parent" ]; do
    _ed_dirs+=("$parent")
    printf '%s\n' "$parent" >> "$_ed_txn/directories.tsv" || return 1
    parent="$(dirname "$parent")"
  done
  mkdir -p "$dir"
}

_external_deploy_backup() {
  local path="$1" base dest n=1
  base="$BACKUP/${path##*/}.pre-install.$(date +%Y%m%d-%H%M%S)"
  dest="$base"
  while [ -e "$dest" ] || [ -L "$dest" ]; do dest="$base.$n"; n=$((n + 1)); done
  _external_deploy_mkdir "$BACKUP" || return 1
  _ed_backups+=("$dest")
  printf '%s\t%s\n' "$path" "$dest" >> "$_ed_txn/backups.tsv" || return 1
  mv "$path" "$dest"
}

# Recover only paths touched by this attempt; failed recovery retains all snapshots.
_external_deploy_rollback() {
  local i path bad=0
  for ((i=${#_ed_all[@]}-1; i>=0; i--)); do
    [ "${_ed_touched[i]:-false}" = true ] || continue
    path="${_ed_all[i]}"
    if ! rm -rf "$path"; then bad=1; continue; fi
    if [ -e "$_ed_txn/paths/$i" ] || [ -L "$_ed_txn/paths/$i" ]; then
      cp -a "$_ed_txn/paths/$i" "$path" || bad=1
    fi
  done
  [ "$bad" -eq 0 ] || return 1
  for path in "${_ed_backups[@]}"; do rm -rf "$path" || bad=1; done
  return "$bad"
}

_external_deploy_apply() {
  local i j path target wanted line keep
  : > "$_ed_txn/manifest" || return 1
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      _manifest_parse "$line"
      keep=true
      for path in "${_ed_all[@]}"; do [ "$_mf_path" != "$path" ] || keep=false; done
      if $keep; then printf '%s\n' "$line" >> "$_ed_txn/manifest" || return 1; fi
    done < "$MANIFEST"
  fi
  for ((i=0; i<${#_ed_old_paths[@]}; i++)); do
    path="${_ed_old_paths[i]}"
    wanted=false
    for target in "${_ed_want_paths[@]}"; do [ "$path" != "$target" ] || wanted=true; done
    if ! $wanted && _external_deploy_owned "$path" "${_ed_old_targets[i]}"; then
      for ((j=0; j<${#_ed_all[@]}; j++)); do [ "${_ed_all[j]}" != "$path" ] || _ed_touched[j]=true; done
      rm -f "$path" || return 1
    fi
  done
  for ((i=0; i<${#_ed_want_paths[@]}; i++)); do
    path="${_ed_want_paths[i]}"; target="${_ed_want_targets[i]}"
    if [ ! -L "$path" ] || [ "$(readlink "$path")" != "$target" ]; then
      for ((j=0; j<${#_ed_all[@]}; j++)); do [ "${_ed_all[j]}" != "$path" ] || _ed_touched[j]=true; done
      if [ -e "$path" ] || [ -L "$path" ]; then _external_deploy_backup "$path" || return 1; fi
      _external_deploy_mkdir "$(dirname "$path")" || return 1
      ln -s "$target" "$path" || return 1
    fi
    printf 'link\t%s\t%s\n' "$path" "$target" >> "$_ed_txn/manifest" || return 1
  done
  for ((i=0; i<3; i++)); do
    path="${_ed_metadata[i]}"
    if [ -f "$path" ] && cmp -s "$_ed_txn/${_ed_staged[i]}" "$path"; then continue; fi
    _external_deploy_mkdir "$(dirname "$path")" || return 1
    _ed_touched[${#_ed_all[@]}-3+i]=true
    mv -f "$_ed_txn/${_ed_staged[i]}" "$path" || return 1
  done
}

# One reported-failure transaction across all agents. No cache writes or process-death guarantee.
# desired_tsv is a file with agent, name, absolute destination and expected target columns.
external_deploy_all() {
  local repo="$1" plan="$2" state="${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules" path key other i j line rc=0
  local _ed_agents=() _ed_names=() _ed_paths=() _ed_targets=()
  _external_deploy_plan "$repo" "$plan" || return 1
  local _ed_want_paths=("${_ed_paths[@]}") _ed_want_targets=("${_ed_targets[@]}")
  local _ed_old_paths=() _ed_old_targets=() _ed_old_rows=() _ed_lost_paths=() _ed_lost_rows=()
  local _ed_metadata=("$MANIFEST" "$state/external-installed.tsv" "$state/external-relinquished.tsv")
  local _ed_staged=(manifest installed relinquished) _ed_all=("${_ed_paths[@]}") _ed_keys=()
  local _ed_dirs=() _ed_backups=() _ed_touched=() _ed_txn
  for path in "$state" "$MANIFEST" "$BACKUP"; do
    _external_deploy_absolute "$path" || { warn 'invalid external deployment state or backup path'; return 1; }
  done
  for path in "$state"/.external-deploy.*; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || { warn "external recovery evidence requires inspection: $path"; return 2; }
  done
  for path in "${_ed_metadata[@]}"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] && continue
    [ -f "$path" ] && [ ! -L "$path" ] || { warn "invalid external metadata: $path"; return 1; }
  done
  if [ -f "${_ed_metadata[1]}" ]; then
    _external_deploy_read "${_ed_metadata[1]}" || return 1
    _ed_old_paths=("${_ed_paths[@]}") _ed_old_targets=("${_ed_targets[@]}")
    for ((i=0; i<${#_ed_paths[@]}; i++)); do
      printf -v line '%s\t%s\t%s\t%s' "${_ed_agents[i]}" "${_ed_names[i]}" "${_ed_paths[i]}" "${_ed_targets[i]}"
      _ed_old_rows+=("$line")
    done
  fi
  if [ -f "${_ed_metadata[2]}" ]; then
    _external_deploy_read "${_ed_metadata[2]}" || return 1
    for ((i=0; i<${#_ed_paths[@]}; i++)); do
      path="${_ed_paths[i]}"
      [ -e "$path" ] || [ -L "$path" ] || continue
      printf -v line '%s\t%s\t%s\t%s' "${_ed_agents[i]}" "${_ed_names[i]}" "$path" "${_ed_targets[i]}"
      _ed_lost_paths+=("$path") _ed_lost_rows+=("$line")
    done
  fi
  for ((i=0; i<${#_ed_old_paths[@]}; i++)); do
    path="${_ed_old_paths[i]}"
    if { [ -e "$path" ] || [ -L "$path" ]; } && ! _external_deploy_owned "$path" "${_ed_old_targets[i]}"; then
      _ed_lost_paths+=("$path") _ed_lost_rows+=("${_ed_old_rows[i]}")
    fi
  done
  for path in "${_ed_want_paths[@]}"; do
    for other in "${_ed_lost_paths[@]}"; do
      [ "$path" != "$other" ] || { warn "external destination ownership relinquished: $path"; return 1; }
    done
  done
  for path in "${_ed_old_paths[@]}" "${_ed_lost_paths[@]}"; do
    key=true
    for other in "${_ed_all[@]}"; do [ "$path" != "$other" ] || key=false; done
    $key && _ed_all+=("$path")
  done
  local layout_keys=()
  for path in "${_ed_metadata[@]}" "$BACKUP"; do
    if [ -d "$path" ]; then key="$(cd -P "$path" && pwd)" || return 1
    else key="$(_external_deploy_location "$path")" || { warn 'invalid external metadata layout'; return 1; }; fi
    for other in "${layout_keys[@]}"; do
      case "$key/" in "$other/"*) warn 'overlapping external metadata'; return 1 ;; esac
      case "$other/" in "$key/"*) warn 'overlapping external metadata'; return 1 ;; esac
    done
    layout_keys+=("$key")
    for other in "${_ed_want_targets[@]}" "${_ed_old_targets[@]}"; do
      if [ -d "$other" ]; then other="$(cd -P "$other" && pwd)" || return 1
      else other="$(_external_deploy_location "$other")" || { warn 'invalid prior source layout'; return 1; }; fi
      case "$key/" in "$other/"*) warn 'external metadata overlaps prepared source'; return 1 ;; esac
      case "$other/" in "$key/"*) warn 'external metadata overlaps prepared source'; return 1 ;; esac
    done
  done
  for path in "${_ed_all[@]}"; do
    key="$(_external_deploy_location "$path")" || { warn "invalid deployment path: $path"; return 1; }
    for other in "${_ed_keys[@]}"; do
      case "$key/" in "$other/"*) warn 'overlapping deployment history'; return 1 ;; esac
      case "$other/" in "$key/"*) warn 'overlapping deployment history'; return 1 ;; esac
    done
    _ed_keys+=("$key")
    for other in "${_ed_metadata[@]}" "$BACKUP" "${_ed_want_targets[@]}" "${_ed_old_targets[@]}"; do
      if [ -d "$other" ]; then other="$(cd -P "$other" && pwd)" || return 1
      else other="$(_external_deploy_location "$other")" || { warn 'invalid deployment layout'; return 1; }; fi
      case "$other/" in "$key/"*) warn 'deployment overlaps source or state'; return 1 ;; esac
      case "$key/" in "$other/"*) warn 'deployment overlaps source or state'; return 1 ;; esac
    done
  done
  [ -d "$state" ] || { warn 'caller must create state and hold the install lock'; return 1; }
  _ed_txn="$(mktemp -d "$state/.external-deploy.XXXXXX")" || return 1
  if ! mkdir "$_ed_txn/paths"; then warn "cannot stage deployment: $_ed_txn"; return 2; fi
  _ed_all+=("${_ed_metadata[@]}")
  for ((i=0; i<${#_ed_all[@]}; i++)); do
    path="${_ed_all[i]}"
    if [ -e "$path" ] || [ -L "$path" ]; then key=present; else key=absent; fi
    printf '%s\t%s\t%s\n' "$i" "$key" "$path" >> "$_ed_txn/paths.tsv" || { rc=1; break; }
    if [ "$key" = present ]; then cp -a "$path" "$_ed_txn/paths/$i" || { rc=1; break; }; fi
  done
  if [ "$rc" -eq 0 ]; then
    cp "$plan" "$_ed_txn/installed" && printf '%s' '' > "$_ed_txn/relinquished" || rc=1
    for line in "${_ed_lost_rows[@]}"; do printf '%s\n' "$line" >> "$_ed_txn/relinquished" || rc=1; done
  fi
  if [ "$rc" -eq 0 ]; then : > "$_ed_txn/snapshots-complete" || rc=1; fi
  if [ "$rc" -eq 0 ]; then _external_deploy_apply || rc=1; fi
  if [ "$rc" -ne 0 ] && ! _external_deploy_rollback; then
    warn "external deployment rollback failed; recovery evidence: $_ed_txn"; return 2
  fi
  if [ "$rc" -ne 0 ]; then
    for path in "${_ed_dirs[@]}"; do
      if [ -d "$path" ]; then rmdir "$path" || { warn "external directory rollback failed: $path; recovery evidence: $_ed_txn"; return 2; }; fi
    done
    warn 'external deployment failed; prior artifacts and metadata restored'
  fi
  rm -rf "$_ed_txn" || { warn "external recovery cleanup failed: $_ed_txn"; return 2; }
  return "$rc"
}
