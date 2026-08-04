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
    codex)  echo "$HOME/.codex/skills"  ;;
    *) return 1 ;;
  esac
}

install_skills() {
  local repo="$1" agent dest d found=false
  if ! sync_enabled skills; then
    # A profile switch (personal -> work) must not leave previously-synced links behind, or
    # `check` keeps reporting skills as installed while the matrix says this profile has none.
    if [ -d "$repo/skills" ]; then
      for agent in claude codex; do
        dest="$(skills_dest_for "$agent")"
        for d in "$repo"/skills/*/; do
          [ -d "$d" ] || continue
          manifest_forget "$dest/$(basename "$d")"
        done
      done
    fi
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
      managed_link "${d%/}" "$dest/$(basename "$d")" || true   # fail-closed warns; keep going
    done
  done
  if ! $found && ! ${DRY:-false}; then
    log "Skills: none to install (skills/ is empty)"
  fi
  ${DRY:-false} || manifest_prune_dangling
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
