# Source after external-skills.sh and external-deploy.sh. The caller holds the install lock.

external_skill_cache() {
  local cache="${AGENT_RULES_SKILL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/skills}"
  _external_deploy_absolute "$cache" || { warn 'external cache must be an absolute path without whitespace'; return 1; }
  if [ -d "$cache" ]; then (cd -P "$cache" && pwd)
  else _external_deploy_location "$cache"; fi
}

# TSV: agent, name, destination, target. Selection is evaluated once for the complete union.
_external_skills_plan() {
  local repo="$1" cache="$2" mode="$3" rows='' agent name url path revision target dest result=''
  sync_enabled skills || return 0
  if [ "$mode" = install ]; then
    rows="$(external_skills_prepare "$repo" "$cache")" || return 1
    while IFS=$'\t' read -r agent name target; do
      [ -n "$agent" ] || continue
      dest="$(skills_dest_for "$agent")" || return 1
      result+="$(printf '%s\t%s\t%s/%s\t%s' "$agent" "$name" "$dest" "$name" "$target")"$'\n'
    done <<< "$rows"
  else
    rows="$(_external_selected_rows "$repo")" || return 1
    while IFS=$'\t' read -r agent name url path revision; do
      [ -n "$agent" ] || continue
      target="$(_external_cache_entry "$cache" "$url" "$revision")" || return 1
      dest="$(skills_dest_for "$agent")" || return 1
      if [ "$mode" = check ]; then
        _external_verify_entry "$target" "$url" "$revision" "$path" || return 1
        target="$(_external_content_path "$target" "$path")" || return 1
      else
        log "External: would prepare/reuse $url at $revision ($path) for $agent/$name" >&2
        [ "$path" = . ] || target="$target/$path"
      fi
      result+="$(printf '%s\t%s\t%s/%s\t%s' "$agent" "$name" "$dest" "$name" "$target")"$'\n'
    done <<< "$rows"
  fi
  while IFS=$'\t' read -r agent name dest target; do
    [ -n "$agent" ] || continue
    _external_deploy_absolute "$dest" && _external_deploy_absolute "$target" || {
      warn 'invalid external destination resolver or prepared target'; return 1;
    }
  done <<< "$result"
  printf '%s' "$result"
}

# Offline desired deployment rows, independent of installed state and without writes.
external_skills_plan() {
  _external_skills_plan "$1" "$2" check
}

_external_skills_recovery() {
  local path bad=0
  for path in "$1"/.external-deploy.*; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      warn "external recovery evidence requires inspection: $path"
      bad=2
    fi
  done
  return "$bad"
}

install_external_skills_all() {
  local repo="$1" cache="$2" rows plan rc=0 agent name dest target
  if ${DRY:-false}; then
    _external_skills_recovery "${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules" || return 2
    rows="$(_external_skills_plan "$repo" "$cache" dry-run)" || return 1
    while IFS=$'\t' read -r agent name dest target; do
      [ -n "$agent" ] || continue
      log "External: would link $dest -> $target"
    done <<< "$rows"
    log 'External: would reconcile removed selections and preserve user-retargeted artifacts'
    return 0
  fi
  rows="$(_external_skills_plan "$repo" "$cache" install)" || return 1
  plan="$(mktemp "${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/.external-plan.XXXXXX")" || return 1
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows" > "$plan" || { rm -f "$plan"; return 1; }
  fi
  external_deploy_all "$repo" "$plan" || rc=$?
  rm -f "$plan" || return 2
  return "$rc"
}

# Verify selection, sources and ownership offline. No preparation, deployment or temporary files.
check_external_skills_all() {
  local repo="$1" cache="$2" state="${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules"
  local desired installed='' file path target line i bad=0
  local _ed_agents=() _ed_names=() _ed_paths=() _ed_targets=()
  _external_skills_recovery "$state" || bad=1
  desired="$(external_skills_plan "$repo" "$cache")" || {
    echo 'FAIL: external selection or required locked cache unavailable'; return 1;
  }
  for file in "$MANIFEST" "$state/external-installed.tsv" "$state/external-relinquished.tsv"; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    if [ ! -f "$file" ] || [ -L "$file" ]; then
      echo "FAIL: invalid external metadata: $file"; return 1
    fi
  done
  file="$state/external-installed.tsv"
  if [ -f "$file" ]; then
    _external_deploy_read "$file" || { echo 'FAIL: invalid external installed state'; return 1; }
    installed="$(cat "$file")" || return 1
    for ((i=0; i<${#_ed_paths[@]}; i++)); do
      if ! _external_deploy_owned "${_ed_paths[i]}" "${_ed_targets[i]}"; then
        echo "FAIL: external link or manifest ownership mismatch: ${_ed_paths[i]}"
        bad=1
      fi
    done
  fi
  if ! cmp -s <(printf '%s' "$desired" | LC_ALL=C sort) <(printf '%s' "$installed" | LC_ALL=C sort); then
    echo 'FAIL: external installed selection differs from current selection; run install.sh'
    bad=1
  fi
  file="$state/external-relinquished.tsv"
  if [ -f "$file" ]; then
    _external_deploy_read "$file" || { echo 'FAIL: invalid external relinquished state'; return 1; }
    for path in "${_ed_paths[@]}"; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        echo "FAIL: external relinquished destination conflict: $path"
      else
        echo "FAIL: stale external relinquished evidence; run install.sh: $path"
      fi
      bad=1
    done
  fi
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      _manifest_parse "$line"
      [ "$_mf_kind" = link ] || continue
      case "$_mf_digest" in "$cache"/*) ;; *) continue ;; esac
      path="$_mf_path"; target="$_mf_digest"
      if ! awk -F '\t' -v p="$path" -v t="$target" \
        '$3 == p && $4 == t { found=1 } END { exit !found }' <<< "$installed"; then
        echo "FAIL: external manifest link lacks installed selection: $path"
        bad=1
      fi
    done < "$MANIFEST"
  fi
  [ "$bad" -ne 0 ] || echo 'PASS: external locked sources, selection and ownership agree'
  return "$bad"
}
