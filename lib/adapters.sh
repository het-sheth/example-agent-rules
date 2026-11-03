# lib/adapters.sh — one function per agent, each using only that agent's verified surface.
# Source after common.sh, profile.sh, and manifest.sh.
#
# The rule for adding an adapter: shared intent stays in AGENTS.md and skills/. An adapter may
# only write to a configuration surface that agent actually documents. If an agent has no
# equivalent for a feature, report that and install nothing — never guess at a file format.

# adapter_detected <name> — is this agent installed?
# A CLI on PATH or a config directory in $HOME both count; agents vary in which they create.
adapter_detected() {
  case "$1" in
    claude) command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ] ;;
    codex)  command -v codex  >/dev/null 2>&1 || [ -d "$HOME/.codex" ]  ;;
    gemini) command -v gemini >/dev/null 2>&1 || [ -d "$HOME/.gemini" ] ;;
    *) return 1 ;;
  esac
}

# --- Claude ----------------------------------------------------------------
# Claude's instruction surface is ~/.claude/CLAUDE.md, which supports `@path` imports. So the
# shim is two import lines rather than a symlink: it loads the shared rulebook and then the
# Claude-only extras on top. Other agents never see the extras file.
claude_shim_content() {
  printf '@%s\n@%s\n' "$1/AGENTS.md" "$1/claude-extras.md"
}

install_claude_adapter() {
  local repo="$1" dest="$HOME/.claude/CLAUDE.md"
  adapter_detected claude || { log "Claude: absent; no files installed"; return 0; }
  if ${DRY:-false}; then
    log "Claude: would back up $dest (if present) and write the two-line import shim"
    return 0
  fi
  # This is the only artifact that cannot be a symlink: its content is generated from this
  # machine's repo path, so there is no repo file to point at. Deploying it through
  # managed_copy records a digest, which is what turns a hand-edit of the deployed shim from
  # an invisible divergence into a check failure. See docs/provenance.md.
  claude_shim_content "$repo" | managed_copy "$dest"
  log "Claude: import shim deployed at $dest (tracked copy)"
}

check_claude_adapter() {
  local repo="$1" dest="$HOME/.claude/CLAUDE.md"
  adapter_detected claude || return 0
  if [ -f "$dest" ] && [ "$(cat "$dest")" = "$(claude_shim_content "$repo")" ]; then
    echo "PASS: Claude shim imports AGENTS.md and claude-extras.md"
    return 0
  fi
  echo "FAIL: Claude shim missing or has wrong import lines ($dest)"
  return 1
}

# --- Codex -----------------------------------------------------------------
# Codex reads ~/.codex/AGENTS.md directly, so a symlink is enough — no shim format needed.
# It has no documented equivalent of Claude's `@` import, so the extras file is not wired here.
install_codex_adapter() {
  local repo="$1" dest="$HOME/.codex/AGENTS.md"
  adapter_detected codex || { log "Codex: absent; no files installed"; return 0; }
  if ${DRY:-false}; then
    log "Codex: would link $dest -> $repo/AGENTS.md"
    return 0
  fi
  if managed_link "$repo/AGENTS.md" "$dest"; then
    log "Codex: shared rules linked at $dest"
  else
    warn "Codex: shared rules not installed because $dest is not managed by this repo"
  fi
}

check_codex_adapter() {
  local repo="$1" dest="$HOME/.codex/AGENTS.md"
  adapter_detected codex || return 0
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$repo/AGENTS.md" ]; then
    echo "PASS: Codex rules link -> $repo/AGENTS.md"
    return 0
  fi
  echo "FAIL: Codex shared rules missing or unmanaged ($dest)"
  return 1
}

# --- Gemini ----------------------------------------------------------------
# Gemini reads ~/.gemini/GEMINI.md. Same symlink treatment as Codex, different filename.
install_gemini_adapter() {
  local repo="$1" dest="$HOME/.gemini/GEMINI.md"
  adapter_detected gemini || { log "Gemini: absent; no files installed"; return 0; }
  if ${DRY:-false}; then
    log "Gemini: would link $dest -> $repo/AGENTS.md"
    return 0
  fi
  if managed_link "$repo/AGENTS.md" "$dest"; then
    log "Gemini: shared rules linked at $dest"
  else
    warn "Gemini: shared rules not installed because $dest is not managed by this repo"
  fi
}

check_gemini_adapter() {
  local repo="$1" dest="$HOME/.gemini/GEMINI.md"
  adapter_detected gemini || return 0
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$repo/AGENTS.md" ]; then
    echo "PASS: Gemini rules link -> $repo/AGENTS.md"
    return 0
  fi
  echo "FAIL: Gemini shared rules missing or unmanaged ($dest)"
  return 1
}

# --- Skills ----------------------------------------------------------------
# Both Claude and Codex load skills from a per-agent skills directory, one directory per skill.
# Symlink each directory in skills/ into every detected agent so a skill is authored once.
skills_dest_for() {
  case "$1" in
    claude) echo "$HOME/.claude/skills" ;;
    codex)  echo "$HOME/.agents/skills"  ;;
    *) return 1 ;;
  esac
}

# Read ownership without accepting a similarly prefixed path or another record kind.
_codex_skill_record() {
  [ -f "$MANIFEST" ] || return 0
  awk -F '\t' -v p="$1" '$1 == p || $2 == p { print }' "$MANIFEST"
}

_codex_skill_owned() {
  local repo="$1" name="$2" path="$3" record target resolved root parent
  [ -L "$path" ] || return 1
  record="$(_codex_skill_record "$path")"
  [ -n "$record" ] || return 1
  _manifest_parse "$record"
  [ "$_mf_kind" = link ] || return 1
  target="$(readlink "$path")"
  if [ "$_mf_digest" != '-' ]; then
    [ "$target" = "$_mf_digest" ] || return 1
    [ "$target" = "$repo/skills/$name" ] && return 0
  else
    [ "$record" = "$path" ] || return 1
  fi
  case "$target" in /*) ;; *) target="$(dirname "$path")/$target" ;; esac
  root="$(cd -P "$repo/skills" && pwd)" || return 1
  if resolved="$(cd -P "$target" 2>/dev/null && pwd)"; then
    case "$resolved" in "$root"/*) return 0 ;; *) return 1 ;; esac
  fi
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  parent="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || return 1
  case "$parent" in "$root"|"$root"/*) return 0 ;; *) return 1 ;; esac
}

# Upgrade proven ownership so generic cleanup also handles relative legacy targets.
_codex_forget_owned() {
  local repo="$1" name="$2" path="$3"
  _codex_skill_owned "$repo" "$name" "$path" || return 1
  _manifest_record link "$path" "$(readlink "$path")" || return 1
  manifest_forget "$path"
}

# Deploy first, save reversal evidence, then forget only the still-owned legacy link.
migrate_codex_skill() {
  local repo="$1" name="$2" old="$HOME/.codex/skills/$2" new="$HOME/.agents/skills/$2"
  local target="$repo/skills/$name" record state old_target backup_path=''
  local migration_root="${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/migrations/codex-skills"
  if ! _codex_skill_owned "$repo" "$name" "$old"; then
    managed_link "$target" "$new"
    return
  fi
  old_target="$(readlink "$old")"
  state=missing
  if [ -L "$new" ] && [ "$(readlink "$new")" = "$target" ]; then state=same
  elif [ -e "$new" ] || [ -L "$new" ]; then state=backup; fi
  mkdir -p "$migration_root" || return 1
  record="$(mktemp -d "$migration_root/record.XXXXXX")" || return 1
  local BACKUP="$BACKUP/codex-skills-$(basename "$record")"
  printf '%s\n' codex-skills-v1 "$repo" "$old" "$new" "$old_target" "$target" "$state" \
    | atomic_write "$record/paths" || return 1
  _codex_skill_record "$old" | atomic_write "$record/old-record" || return 1
  _codex_skill_record "$new" | atomic_write "$record/new-record" || return 1
  managed_link "$target" "$new" || return 1
  if [ "$state" = backup ]; then
    for backup_path in "$BACKUP"/*; do
      [ -e "$backup_path" ] || [ -L "$backup_path" ] || return 1
      break
    done
  fi
  printf '%s\n' "$backup_path" | atomic_write "$record/backup-path" || return 1
  printf '%s\n' deployed | atomic_write "$record/deployed" || return 1
  [ "$(readlink "$old")" = "$old_target" ] || return 1
  _codex_skill_owned "$repo" "$name" "$old" || return 1
  _codex_forget_owned "$repo" "$name" "$old" || return 1
  printf '%s\n' complete | atomic_write "$record/complete" || return 1
  log "Codex skill migrated; reversal record: $record"
}

# Reversal accepts installer data, never shell input, and preflights every live destination.
rollback_codex_skills() {
  local repo="$1" record="$2" root version saved_repo old new old_target target state extra
  local backup_path old_record new_record current tmp name file created_old=false old_current
  root="${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/migrations/codex-skills"
  [ -d "$record" ] && [ ! -L "$record" ] && [ ! -e "$record/reverted" ] \
    || { warn 'not an active Codex skill migration record'; return 1; }
  [ "$(cd -P "$(dirname "$record")" && pwd)" = "$(cd -P "$root" && pwd)" ] \
    || { warn 'migration record is outside this machine state'; return 1; }
  for file in paths old-record new-record backup-path deployed; do
    [ -f "$record/$file" ] && [ ! -L "$record/$file" ] \
      || { warn "incomplete migration evidence: $file"; return 1; }
  done
  {
    IFS= read -r version && IFS= read -r saved_repo && IFS= read -r old \
      && IFS= read -r new && IFS= read -r old_target && IFS= read -r target \
      && IFS= read -r state && ! IFS= read -r extra
  } < "$record/paths" || { warn 'invalid migration paths'; return 1; }
  [ "$(cat "$record/deployed")" = deployed ] || return 1
  if [ -e "$record/complete" ] || [ -L "$record/complete" ]; then
    [ ! -L "$record/complete" ] && [ "$(cat "$record/complete")" = complete ] || return 1
  fi
  name="${old##*/}"
  case "$name" in ''|.|..) warn 'invalid migration skill name'; return 1 ;; esac
  [ "$version" = codex-skills-v1 ] && [ "$saved_repo" = "$repo" ] \
    && [ "$old" = "$HOME/.codex/skills/$name" ] \
    && [ "$new" = "$HOME/.agents/skills/$name" ] && [ "$target" = "$repo/skills/$name" ] \
    || { warn 'migration does not match this checkout and HOME'; return 1; }
  old_record="$(cat "$record/old-record")"
  new_record="$(cat "$record/new-record")"
  case "$old_record$new_record" in *$'\n'*) warn 'invalid prior manifest records'; return 1 ;; esac
  _manifest_parse "$old_record"
  [ "$_mf_kind" = link ] && [ "$_mf_path" = "$old" ] \
    && { [ "$old_record" = "$old" ] || [ "$_mf_digest" = "$old_target" ]; } \
    || { warn 'invalid legacy ownership evidence'; return 1; }
  if [ -n "$new_record" ]; then
    _manifest_parse "$new_record"
    [ "$_mf_path" = "$new" ] && { [ "$_mf_kind" = link ] || [ "$_mf_kind" = copy ]; } \
      || { warn 'invalid destination ownership evidence'; return 1; }
  fi
  old_current="$(_codex_skill_record "$old")"
  if [ ! -e "$old" ] && [ ! -L "$old" ] && [ -z "$old_current" ]; then
    created_old=true
  elif [ ! -e "$record/complete" ] && [ -L "$old" ] \
       && [ "$(readlink "$old")" = "$old_target" ] \
       && { [ "$old_current" = "$old_record" ] \
            || [ "$old_current" = "$(printf 'link\t%s\t%s' "$old" "$old_target")" ]; }; then
    created_old=false
  else
    warn 'legacy destination changed; refusing reversal'; return 1
  fi
  [ -L "$new" ] && [ "$(readlink "$new")" = "$target" ] \
    || { warn 'destination changed; refusing reversal'; return 1; }
  current="$(printf 'link\t%s\t%s' "$new" "$target")"
  [ "$(_codex_skill_record "$new")" = "$current" ] \
    || { warn 'destination ownership changed; refusing reversal'; return 1; }
  backup_path="$(cat "$record/backup-path")"
  case "$state" in
    missing|same) [ -z "$backup_path" ] || return 1 ;;
    backup)
      case "$backup_path" in
        "$BACKUP/codex-skills-$(basename "$record")/$name.pre-install."*) ;;
        *) warn 'unexpected migration backup path'; return 1 ;;
      esac
      [ "$(dirname "$backup_path")" = "$BACKUP/codex-skills-$(basename "$record")" ] \
        && [ ! -L "$(dirname "$backup_path")" ] \
        && { [ -e "$backup_path" ] || [ -L "$backup_path" ]; } \
        || { warn 'migration backup missing or changed; refusing reversal'; return 1; }
      ;;
    *) warn 'invalid prior destination state'; return 1 ;;
  esac
  tmp="$(mktemp "$(dirname "$MANIFEST")/.links.XXXXXX")" || return 1
  if ! awk -F '\t' -v a="$old" -v b="$new" \
      '$1 != a && $2 != a && $1 != b && $2 != b' "$MANIFEST" > "$tmp" \
      || ! cat "$record/old-record" "$record/new-record" >> "$tmp"; then
    rm -f "$tmp"; warn 'cannot stage restored manifest'; return 1
  fi
  if $created_old && ! ln -s "$old_target" "$old"; then rm -f "$tmp"; return 1; fi
  if [ "$state" != same ]; then
    if ! rm "$new"; then
      $created_old && rm -f "$old"
      rm -f "$tmp"; return 1
    fi
    if [ "$state" = backup ] && ! mv "$backup_path" "$new"; then
      ln -s "$target" "$new"
      $created_old && rm -f "$old"
      rm -f "$tmp"
      warn 'backup restoration failed; migration retained'; return 1
    fi
  fi
  if ! mv -f "$tmp" "$MANIFEST"; then
    local recovered=true
    if [ "$state" = backup ]; then
      if [ ! -e "$backup_path" ] && [ ! -L "$backup_path" ]; then
        mv "$new" "$backup_path" || recovered=false
      else recovered=false; fi
    fi
    if [ "$state" != same ] && $recovered; then
      ln -s "$target" "$new" || recovered=false
    fi
    if $created_old && $recovered; then
      if [ -L "$old" ] && [ "$(readlink "$old")" = "$old_target" ]; then
        rm "$old" || recovered=false
      else recovered=false; fi
    fi
    rm -f "$tmp"
    if $recovered; then warn 'manifest restoration failed; forward deployment retained, retry reversal'
    else warn "manifest restoration and compensation failed; recovery evidence: $record"; fi
    return 1
  fi
  printf '%s\n' reverted | atomic_write "$record/reverted" || return 1
  log "Codex skill migration reversed: $record"
}

_codex_remove_disabled_skills() {
  local repo="$1" line path name
  [ -f "$MANIFEST" ] || return 0
  while IFS= read -r line; do
    _manifest_parse "$line"
    path="$_mf_path"
    case "$path" in
      "$HOME/.codex/skills/"*|"$HOME/.agents/skills/"*) ;;
      *) continue ;;
    esac
    name="${path##*/}"
    [ "$path" = "$HOME/.codex/skills/$name" ] \
      || [ "$path" = "$HOME/.agents/skills/$name" ] || continue
    if _codex_skill_owned "$repo" "$name" "$path"; then
      _codex_forget_owned "$repo" "$name" "$path" || return 1
    fi
  done < "$MANIFEST"
}

install_skills() {
  local repo="$1" agent dest d found=false bad=0
  if ! sync_enabled skills; then
    # A profile switch (personal -> work) must not leave previously-synced links behind, or
    # `check` keeps reporting skills as installed while the matrix says this profile has none.
    if [ -d "$repo/skills" ]; then
      for agent in claude; do
        dest="$(skills_dest_for "$agent")"
        for d in "$repo"/skills/*/; do
          [ -d "$d" ] || continue
          ${DRY:-false} && continue
          manifest_forget "$dest/$(basename "$d")"
        done
      done
    fi
    ${DRY:-false} || _codex_remove_disabled_skills "$repo" || return 1
    log "Skills: skipped (profile=${PROFILE:-work})"
    return 0
  fi
  if [ ! -d "$repo/skills" ]; then
    log "Skills: none to install (no skills/ directory)"
    return 0
  fi
  for agent in claude codex; do
    adapter_detected "$agent" || continue
    dest="$(skills_dest_for "$agent")"
    if ${DRY:-false}; then
      log "Skills: would link each directory in skills/ into $dest"
      continue
    fi
    for d in "$repo"/skills/*/; do
      [ -d "$d" ] || continue
      found=true
      if [ "$agent" = codex ]; then
        migrate_codex_skill "$repo" "$(basename "$d")" || bad=1
      else
        managed_link "${d%/}" "$dest/$(basename "$d")" || bad=1
      fi
    done
  done
  if ! $found && ! ${DRY:-false}; then
    log "Skills: none to install (skills/ is empty)"
  fi
  ${DRY:-false} || manifest_prune_dangling
  return "$bad"
}

check_skills() {
  local repo="$1" agent dest d bad=0
  sync_enabled skills || return 0
  [ -d "$repo/skills" ] || return 0
  for agent in claude codex; do
    adapter_detected "$agent" || continue
    dest="$(skills_dest_for "$agent")"
    for d in "$repo"/skills/*/; do
      [ -d "$d" ] || continue
      if [ -L "$dest/$(basename "$d")" ] \
         && [ "$(readlink "$dest/$(basename "$d")")" = "${d%/}" ]; then
        echo "PASS: $agent skill $(basename "$d")"
      else
        echo "FAIL: $agent skill missing or wrong target ($dest/$(basename "$d"))"
        bad=1
      fi
    done
  done
  return $bad
}

# --- Reporting -------------------------------------------------------------
# The matrix is declarative data, not derived from the code, so a row that stops being true is
# a visible discrepancy against the PASS/FAIL lines printed above it.
adapter_report_matrix() {
  local matrix="$1/capabilities/matrix.tsv" capability claude codex gemini
  [ -f "$matrix" ] || { warn "capability matrix missing ($matrix)"; return 1; }
  echo "CAPABILITY MATRIX:"
  while IFS='|' read -r capability claude codex gemini; do
    [ -n "$capability" ] || continue
    case "$capability" in \#*) continue ;; esac
    printf '  %-12s claude: %-38s codex: %-38s gemini: %s\n' \
      "$capability" "$claude" "$codex" "$gemini"
  done < "$matrix"
}

report_adapter_state() {
  local repo="$1" agent
  echo "ADAPTERS:"
  for agent in claude codex gemini; do
    if adapter_detected "$agent"; then
      echo "  $agent: detected"
    else
      echo "  $agent: absent; no adapter assets expected"
    fi
  done
  adapter_report_matrix "$repo"
}
