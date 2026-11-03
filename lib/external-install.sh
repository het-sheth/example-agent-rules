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
        target="$target/$path"
      fi
      result+="$(printf '%s\t%s\t%s/%s\t%s' "$agent" "$name" "$dest" "$name" "$target")"$'\n'
    done <<< "$rows"
  fi
  printf '%s' "$result"
}

install_external_skills_all() {
  local repo="$1" cache="$2" rows plan rc=0 agent name dest target
  if ${DRY:-false}; then
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
