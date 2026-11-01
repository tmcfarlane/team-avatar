#!/usr/bin/env bash
{ # ensure entire script is downloaded before execution

set -euo pipefail

VERSION="0.5.0"
CURSOR_MODE_LABEL="Team Avatar (Cursor 3.27+)"

AGENT_FILES=(aang.md sokka.md katara.md zuko.md toph.md appa.md momo.md iroh.md)
PROTOCOL_FILES=(protocols/team-avatar.md)
COMMAND_FILES=(plan.md build.md search.md fix.md tasks.md scout.md cactus-juice.md doc.md image.md)
HOOK_FILES=(post-edit-lint.sh pre-commit-check.sh guard-shell.sh)
CONFIG_FILES=(hooks.json permissions.json)
RULE_FILE="orchestrator.mdc"
PLUGIN_NAME="team-avatar"
PLUGIN_MANIFEST=".cursor-plugin/plugin.json"
PLUGIN_HOOKS_CONFIG="hooks.json"
SKILL_DIRS=(
  architect
  codebase-search
  crafting-effective-readmes
  create-an-asset
  cursor-image-generation
  debugging
  design-patterns-implementation
  docs-write
  documentation-engineer
  documentation-writing
  exploring-codebases
  frontend-builder
  implementing-figma-designs
  mgrep-code-search
  planning
  refactoring
  refactoring-patterns
  technical-roadmap-planning
  vercel-composition-patterns
  vercel-react-best-practices
  web-design-guidelines
)

LEGACY_AGENT_FILES=(atlas.md explore.md generalPurpose.md hephaestus.md librarian.md metis.md momus.md multimodal-looker.md oracle.md prometheus.md sisyphus.md)
LEGACY_PROTOCOL_FILES=(protocols/swarm-coordinator.md)

FORCE=false
DRY_RUN=false
VERBOSE=false
SCOPE="user"
UNINSTALL=false
DISABLE=false
ENABLE=false
ALSO_CLAUDE=false
ALSO_CODEX=false
WITH_SKILLS=true

WORK_DIR=""
PLUGIN_DIR=""
BACKUP_DIR=""
OLD_LAYOUT_MOVED=0

BOLD="" DIM="" GREEN="" RED="" YELLOW="" RESET=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    RESET=$'\033[0m'
  fi
}

log() {
  printf '%s\n' "$*"
}

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    printf '%s%s%s\n' "$DIM" "$*" "$RESET"
  fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${BOLD}oh-my-cursor installer${RESET} v${VERSION}
${DIM}${CURSOR_MODE_LABEL}${RESET}

Install Team Avatar agent configurations for Cursor.

User scope installs a local Cursor plugin at ~/.cursor/plugins/local/team-avatar/.
Restart Cursor afterwards. On Cursor Enterprise, an admin must turn on
"Allow Local Plugin Imports". Project scope installs files into ./.cursor/.

${BOLD}USAGE${RESET}
  curl -fsSL https://raw.githubusercontent.com/tmcfarlane/team-avatar/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/tmcfarlane/team-avatar/main/install.sh | bash -s -- [OPTIONS]
  bash install.sh [OPTIONS]

${BOLD}OPTIONS${RESET}
  --user          Install the local plugin to ~/.cursor/plugins/local/team-avatar/ [default]
  --project       Install to project scope (./.cursor/)
  --claude        Also install to .claude/agents/ for Claude Code compatibility
  --codex         Also install to .codex/agents/ for Codex compatibility
  --no-skills     Skip installing bundled agent skills (skills are installed by default)
  -f, --force     Overwrite existing files
  -n, --dry-run   Show what would be done without making changes
  -v, --verbose   Enable verbose output
  --uninstall     Remove the installed plugin (user) or agent and rule files (project)
  --disable       Disable orchestration (rename rule so Cursor stops applying it)
  --enable        Re-enable orchestration (rename rule back)
  -h, --help      Show this help message
  --version       Print version

${BOLD}EXAMPLES${RESET}
  bash install.sh
  bash install.sh --project
  bash install.sh --force
  bash install.sh --dry-run
  bash install.sh --uninstall
  bash install.sh --disable
  bash install.sh --enable
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing & directory resolution
# ---------------------------------------------------------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force)    FORCE=true ;;
      -n|--dry-run)  DRY_RUN=true ;;
      -v|--verbose)  VERBOSE=true ;;
      --user)        SCOPE="user" ;;
      --project)     SCOPE="project" ;;
      --claude)       ALSO_CLAUDE=true ;;
      --codex)        ALSO_CODEX=true ;;
      --with-skills)  WITH_SKILLS=true ;;  # no-op for backwards compatibility
      --no-skills)    WITH_SKILLS=false ;;
      --uninstall)    UNINSTALL=true ;;
      --disable)     DISABLE=true ;;
      --enable)      ENABLE=true ;;
      -h|--help)     usage; exit 0 ;;
      --version)     printf '%s\n' "$VERSION"; exit 0 ;;
      *)
        log "${RED}Unknown option: $1${RESET}" >&2
        log "" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

resolve_dirs() {
  local target_dir
  if [ "$SCOPE" = "user" ]; then
    CURSOR_DIR="${HOME}/.cursor"
    PLUGIN_DIR="${CURSOR_DIR}/plugins/local/${PLUGIN_NAME}"
    target_dir="$PLUGIN_DIR"
  else
    CURSOR_DIR="./.cursor"
    target_dir="$CURSOR_DIR"
  fi
  AGENTS_DIR="${target_dir}/agents"
  RULES_DIR="${target_dir}/rules"
  COMMANDS_DIR="${target_dir}/commands"
  HOOKS_DIR="${target_dir}/hooks"
  SKILLS_DIR="${target_dir}/skills"
}

RULE_FILE_DISABLED="${RULE_FILE}.disabled"

# Toggle orchestration rule so Cursor loads it (--enable) or ignores it (--disable).
toggle_orchestrator_rule() {
  local rule_path="${RULES_DIR}/${RULE_FILE}"
  local disabled_path="${RULES_DIR}/${RULE_FILE_DISABLED}"

  log "${BOLD}oh-my-cursor${RESET} v${VERSION}"
  log "${DIM}${CURSOR_MODE_LABEL}${RESET}"
  log ""

  if [ "$DISABLE" = true ]; then
    if [ -f "$rule_path" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${YELLOW}[would disable]${RESET} ${RULE_FILE} in ${RULES_DIR}"
      else
        mv "$rule_path" "$disabled_path"
        log "  ${GREEN}[disabled]${RESET} ${RULE_FILE} — orchestration off. Agents and commands still available."
      fi
    else
      if [ -f "$disabled_path" ]; then
        log "  ${DIM}Already disabled${RESET} (${RULE_FILE_DISABLED} present)"
      else
        log "  ${YELLOW}No rule file found${RESET} at ${rule_path}"
      fi
    fi
  else
    if [ -f "$disabled_path" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${YELLOW}[would enable]${RESET} ${RULE_FILE} in ${RULES_DIR}"
      else
        mv "$disabled_path" "$rule_path"
        log "  ${GREEN}[enabled]${RESET} ${RULE_FILE} — Team Avatar orchestration on."
      fi
    else
      if [ -f "$rule_path" ]; then
        log "  ${DIM}Already enabled${RESET} (${RULE_FILE} present)"
      else
        log "  ${YELLOW}No disabled rule found${RESET} at ${disabled_path}"
      fi
    fi
  fi
  log ""
}

# ---------------------------------------------------------------------------
# Embedded source files (all 12 agent/rule files)
# ---------------------------------------------------------------------------

SOURCE_BASE_URL_DEFAULT="https://raw.githubusercontent.com/tmcfarlane/team-avatar/main"
# Override for forks/dev:
#   OH_MY_CURSOR_SOURCE_BASE_URL="https://raw.githubusercontent.com/<you>/<repo>/<ref>" bash install.sh
OH_MY_CURSOR_SOURCE_BASE_URL="${OH_MY_CURSOR_SOURCE_BASE_URL:-$SOURCE_BASE_URL_DEFAULT}"

get_script_dir() {
  local src="${BASH_SOURCE[0]:-}"
  if [ -n "$src" ] && [ -f "$src" ]; then
    (cd "$(dirname "$src")" && pwd)
    return 0
  fi
  return 1
}

copy_sources_from_local_repo() {
  local out_dir="$1"
  local script_dir

  script_dir="$(get_script_dir)" || return 1
  [ -d "${script_dir}/agents" ] || return 1
  [ -d "${script_dir}/rules" ] || return 1

  local file
  for file in "${AGENT_FILES[@]}"; do
    cp "${script_dir}/agents/${file}" "${out_dir}/${file}" || return 1
  done

  for file in "${PROTOCOL_FILES[@]}"; do
    mkdir -p "${out_dir}/$(dirname "$file")"
    cp "${script_dir}/agents/${file}" "${out_dir}/${file}" || return 1
  done

  cp "${script_dir}/rules/${RULE_FILE}" "${out_dir}/${RULE_FILE}" || return 1

  if [ -d "${script_dir}/commands" ]; then
    mkdir -p "${out_dir}/commands"
    for file in "${COMMAND_FILES[@]}"; do
      cp "${script_dir}/commands/${file}" "${out_dir}/commands/${file}" || return 1
    done
  fi

  if [ -d "${script_dir}/hooks" ]; then
    mkdir -p "${out_dir}/hooks"
    for file in "${HOOK_FILES[@]}"; do
      cp "${script_dir}/hooks/${file}" "${out_dir}/hooks/${file}" || return 1
    done
    cp "${script_dir}/hooks/${PLUGIN_HOOKS_CONFIG}" "${out_dir}/hooks/${PLUGIN_HOOKS_CONFIG}" || return 1
  fi

  mkdir -p "${out_dir}/$(dirname "$PLUGIN_MANIFEST")"
  cp "${script_dir}/${PLUGIN_MANIFEST}" "${out_dir}/${PLUGIN_MANIFEST}" || return 1

  if [ -d "${script_dir}/skills" ]; then
    cp -r "${script_dir}/skills" "${out_dir}/skills" || return 1
  fi

  for file in "${CONFIG_FILES[@]}"; do
    if [ -f "${script_dir}/${file}" ]; then
      cp "${script_dir}/${file}" "${out_dir}/${file}" || return 1
    fi
  done

  return 0
}

download_sources_from_github() {
  local out_dir="$1"

  if ! command -v curl >/dev/null 2>&1; then
    log_verbose "curl not found; cannot download sources"
    return 1
  fi

  local base="$OH_MY_CURSOR_SOURCE_BASE_URL"
  local file url

  for file in "${AGENT_FILES[@]}"; do
    url="${base}/agents/${file}"
    curl -fsSL "$url" -o "${out_dir}/${file}" || return 1
  done

  for file in "${PROTOCOL_FILES[@]}"; do
    mkdir -p "${out_dir}/$(dirname "$file")"
    url="${base}/agents/${file}"
    curl -fsSL "$url" -o "${out_dir}/${file}" || return 1
  done

  url="${base}/rules/${RULE_FILE}"
  curl -fsSL "$url" -o "${out_dir}/${RULE_FILE}" || return 1

  mkdir -p "${out_dir}/commands"
  for file in "${COMMAND_FILES[@]}"; do
    url="${base}/commands/${file}"
    curl -fsSL "$url" -o "${out_dir}/commands/${file}" || return 1
  done

  mkdir -p "${out_dir}/hooks"
  for file in "${HOOK_FILES[@]}"; do
    url="${base}/hooks/${file}"
    curl -fsSL "$url" -o "${out_dir}/hooks/${file}" || return 1
  done
  curl -fsSL "${base}/hooks/${PLUGIN_HOOKS_CONFIG}" -o "${out_dir}/hooks/${PLUGIN_HOOKS_CONFIG}" || return 1

  mkdir -p "${out_dir}/$(dirname "$PLUGIN_MANIFEST")"
  curl -fsSL "${base}/${PLUGIN_MANIFEST}" -o "${out_dir}/${PLUGIN_MANIFEST}" || return 1

  for file in "${CONFIG_FILES[@]}"; do
    curl -fsSL "${base}/${file}" -o "${out_dir}/${file}" || return 1
  done

  local manifest_url="${base}/skills/MANIFEST"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  if curl -fsSL "$manifest_url" -o "$manifest_tmp" 2>/dev/null; then
    mkdir -p "${out_dir}/skills"
    while IFS= read -r skill_file || [ -n "$skill_file" ]; do
      [ -z "$skill_file" ] && continue
      mkdir -p "${out_dir}/skills/$(dirname "$skill_file")"
      curl -fsSL "${base}/skills/${skill_file}" -o "${out_dir}/skills/${skill_file}" || true
    done < "$manifest_tmp"
    cp "$manifest_tmp" "${out_dir}/skills/MANIFEST"
  fi
  rm -f "$manifest_tmp"

  return 0
}

create_source_files() {
  local dir="$1"
  mkdir -p "$dir"

  if copy_sources_from_local_repo "$dir"; then
    log_verbose "Using local repo sources"
    return 0
  fi

  if download_sources_from_github "$dir"; then
    log_verbose "Downloaded sources from ${OH_MY_CURSOR_SOURCE_BASE_URL}"
    return 0
  fi

  log "${RED}Failed to acquire source files.${RESET}" >&2
  log "${DIM}Tried local repo checkout and GitHub raw download.${RESET}" >&2
  log "${DIM}Override the download base with OH_MY_CURSOR_SOURCE_BASE_URL=...${RESET}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Install a set of files from src_dir to dest_dir
# ---------------------------------------------------------------------------

install_file_set() {
  local src_dir="$1"
  local dest_dir="$2"
  local label="$3"
  shift 3
  local files=("$@")
  local installed=0
  local skipped=0
  local updated=0
  local failed=0

  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi

  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$dest_dir"
  fi

  log "Installing ${label} to ${BOLD}${dest_dir}${RESET}"
  log ""

  local file src dest
  for file in "${files[@]}"; do
    src="${src_dir}/${file}"
    dest="${dest_dir}/${file}"

    if [ ! -f "$src" ]; then
      log_verbose "  ${DIM}[skip]${RESET} ${file} (source not found)"
      continue
    fi

    local dest_subdir
    dest_subdir="$(dirname "$dest")"
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$dest_subdir"
    fi

    if [ ! -f "$dest" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${GREEN}[new]${RESET} ${file}"
      else
        if cp "$src" "$dest" 2>/dev/null; then
          log "  ${GREEN}[installed]${RESET} ${file}"
        else
          log "  ${RED}[failed]${RESET} ${file}"
          failed=$((failed + 1))
          continue
        fi
      fi
      installed=$((installed + 1))
    elif cmp -s "$src" "$dest"; then
      log "  ${DIM}[unchanged]${RESET} ${file}"
      skipped=$((skipped + 1))
    elif [ "$FORCE" = true ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${YELLOW}[update]${RESET} ${file}"
      else
        if cp "$src" "$dest" 2>/dev/null; then
          log "  ${YELLOW}[updated]${RESET} ${file}"
        else
          log "  ${RED}[failed]${RESET} ${file}"
          failed=$((failed + 1))
          continue
        fi
      fi
      updated=$((updated + 1))
    else
      log "  ${YELLOW}[skipped]${RESET} ${file} ${DIM}(use --force to overwrite)${RESET}"
      skipped=$((skipped + 1))
    fi
  done

  log ""
  return $failed
}

# ---------------------------------------------------------------------------
# Migrate legacy agent files (Greek mythology -> ATLA)
# ---------------------------------------------------------------------------

migrate_legacy_agents() {
  local agents_dir="$1"
  local migrated=0

  for file in "${LEGACY_AGENT_FILES[@]}"; do
    local target="${agents_dir}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${YELLOW}[migrate]${RESET} removing legacy ${file}"
      else
        rm -f "$target"
        log "  ${YELLOW}[migrated]${RESET} removed legacy ${file}"
      fi
      migrated=$((migrated + 1))
    fi
  done

  for file in "${LEGACY_PROTOCOL_FILES[@]}"; do
    local target="${agents_dir}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${YELLOW}[migrate]${RESET} removing legacy ${file}"
      else
        rm -f "$target"
        log "  ${YELLOW}[migrated]${RESET} removed legacy ${file}"
      fi
      migrated=$((migrated + 1))
    fi
  done

  if [ "$migrated" -gt 0 ]; then
    log ""
    log "  ${YELLOW}Migrated from v0.1 (Greek mythology) to v0.2 (Team Avatar)${RESET}"
    log ""
  fi
}

# ---------------------------------------------------------------------------
# Install a git-native pre-commit hook (defense-in-depth backstop)
# ---------------------------------------------------------------------------
# The beforeShellExecution guard only sees shell `git commit`; Cursor's agent can also commit
# through its native git path, which bypasses that hook (observed on Cursor 3.9). A real git
# pre-commit hook catches anti-pattern commits regardless of how the commit is made.
install_git_precommit_hook() {
  local git_dir hook
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { log "  [skip] git pre-commit hook (not a git repo)"; return 0; }
  hook="${git_dir}/hooks/pre-commit"
  if [ -f "$hook" ] && ! grep -q "oh-my-cursor" "$hook" 2>/dev/null; then
    log "  [skip] git pre-commit hook (existing non-OMC hook at ${hook})"; return 0
  fi
  if [ "$DRY_RUN" = true ]; then log "  ${GREEN}[new]${RESET} git pre-commit hook (${hook})"; return 0; fi
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# oh-my-cursor defense-in-depth: catch anti-pattern commits regardless of HOW the commit is made
# (shell, git CLI, or Cursor's native git path). The beforeShellExecution guard only sees shell
# `git commit`; this git-native hook covers commits that bypass the shell.
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exec "$root/.cursor/hooks/pre-commit-check.sh"
HOOK
  chmod +x "$hook"
  log "  ${GREEN}[installed]${RESET} git pre-commit hook (${hook})"
}

# ---------------------------------------------------------------------------
# Install to a specific tool directory (cursor, claude, or codex)
# ---------------------------------------------------------------------------

install_to_dir() {
  local cursor_dir="$1"
  local agents_dir="${cursor_dir}/agents"
  local rules_dir="${cursor_dir}/rules"
  local commands_dir="${cursor_dir}/commands"
  local hooks_dir="${cursor_dir}/hooks"

  migrate_legacy_agents "$agents_dir"

  install_file_set "$WORK_DIR" "$agents_dir" "agents" "${AGENT_FILES[@]}"
  install_file_set "$WORK_DIR" "$agents_dir" "protocols" "${PROTOCOL_FILES[@]}"
  install_file_set "${WORK_DIR}/commands" "$commands_dir" "commands" "${COMMAND_FILES[@]}"
  install_file_set "${WORK_DIR}/hooks" "$hooks_dir" "hooks" "${HOOK_FILES[@]}"
  # Hook config (hooks.json / permissions.json) is PROJECT-scoped only: its hook command
  # paths are relative to the workspace root, so user-scope (~/.cursor) hooks would not
  # resolve across other projects. Install it only for a project-scope cursor install.
  if [ "$SCOPE" = "project" ] && [ "$cursor_dir" = "$CURSOR_DIR" ]; then
    install_file_set "$WORK_DIR" "$cursor_dir" "config" "${CONFIG_FILES[@]}"
    install_git_precommit_hook
  fi

  # Install rule file
  log "Installing rules to ${BOLD}${rules_dir}${RESET}"
  log ""

  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$rules_dir"
  fi

  local src="${WORK_DIR}/${RULE_FILE}"
  local dest="${rules_dir}/${RULE_FILE}"

  if [ ! -f "$dest" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "  ${GREEN}[new]${RESET} ${RULE_FILE}"
    else
      cp "$src" "$dest" 2>/dev/null && log "  ${GREEN}[installed]${RESET} ${RULE_FILE}" || log "  ${RED}[failed]${RESET} ${RULE_FILE}"
    fi
  elif cmp -s "$src" "$dest"; then
    log "  ${DIM}[unchanged]${RESET} ${RULE_FILE}"
  elif [ "$FORCE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
      log "  ${YELLOW}[update]${RESET} ${RULE_FILE}"
    else
      cp "$src" "$dest" 2>/dev/null && log "  ${YELLOW}[updated]${RESET} ${RULE_FILE}" || log "  ${RED}[failed]${RESET} ${RULE_FILE}"
    fi
  else
    log "  ${YELLOW}[skipped]${RESET} ${RULE_FILE} ${DIM}(use --force to overwrite)${RESET}"
  fi
  log ""
}

# ---------------------------------------------------------------------------
# User-scope plugin: move the old ~/.cursor/ layout aside, install permissions.json
# ---------------------------------------------------------------------------

backup_old_file() {
  local rel="$1"
  local src="${CURSOR_DIR}/${rel}"
  local dest="${BACKUP_DIR}/${rel}"

  if [ "$DRY_RUN" = true ]; then
    log "  ${YELLOW}[would move]${RESET} ${src}"
  else
    mkdir -p "$(dirname "$dest")"
    mv "$src" "$dest"
    log "  ${YELLOW}[moved]${RESET} ${src} -> ${dest}"
  fi
  OLD_LAYOUT_MOVED=$((OLD_LAYOUT_MOVED + 1))
}

# A SKILL.md's description line plus the indented lines that continue it.
skill_description() { awk '/^description:/ {on=1; print; next} on && /^[ \t]/ {print; next} on {exit}' "$1" 2>/dev/null || true; }

# Earlier installers wrote straight into ~/.cursor/. Cursor 3.27 reads Team Avatar from the plugin,
# so those copies are moved (never deleted) into a backup folder. A file moves only when it is clearly ours.
backup_old_user_layout() {
  BACKUP_DIR="${CURSOR_DIR}/team-avatar-backup-$(date +%Y%m%d-%H%M%S)"
  OLD_LAYOUT_MOVED=0

  local file name rel skill line
  # Every shipped command names its character as a whole word. cactus-juice.md names none, so
  # its own phrase marks it as ours.
  local characters='aang|sokka|katara|zuko|toph|appa|momo|iroh|cactus juice'

  for file in "${AGENT_FILES[@]}"; do
    name="${file%.md}"
    rel="agents/${file}"
    if [ -f "${CURSOR_DIR}/${rel}" ]; then
      line="$(sed -n 2p "${CURSOR_DIR}/${rel}")"
      # Ours: a name an earlier release shipped, such as "name: toph", "name: toph is exploring
      # files and docs by vibration", or "name: aang - Executes & Debugs Code".
      if [ "$line" = "name: ${name}" ] || [[ "$line" == "name: ${name} is "* ]] || [[ "$line" == "name: ${name} - "* ]]; then
        backup_old_file "$rel"
      fi
    fi
  done

  for file in "${PROTOCOL_FILES[@]}" "${LEGACY_PROTOCOL_FILES[@]}"; do
    rel="agents/${file}"
    if [ -f "${CURSOR_DIR}/${rel}" ] && [[ "$(head -n 1 "${CURSOR_DIR}/${rel}")" == "# "*"Coordinator Protocol"* ]]; then
      backup_old_file "$rel"
    fi
  done

  for file in "$RULE_FILE" "$RULE_FILE_DISABLED"; do
    rel="rules/${file}"
    if [ -f "${CURSOR_DIR}/${rel}" ] && grep -q "Team Avatar orchestration" "${CURSOR_DIR}/${rel}"; then
      backup_old_file "$rel"
    fi
  done

  for file in "${COMMAND_FILES[@]}"; do
    rel="commands/${file}"
    if [ -f "${CURSOR_DIR}/${rel}" ] && grep -qiwE "$characters" "${CURSOR_DIR}/${rel}"; then
      backup_old_file "$rel"
    fi
  done

  # A user's own ~/.cursor/hooks.json may run scripts with these names, so leave them when it exists.
  if [ ! -e "${CURSOR_DIR}/hooks.json" ]; then
    for file in "${HOOK_FILES[@]}"; do
      rel="hooks/${file}"
      [ -f "${CURSOR_DIR}/${rel}" ] || continue
      # Ours: the second line an earlier release shipped for that script.
      case "${file}:$(sed -n 2p "${CURSOR_DIR}/${rel}")" in
        "guard-shell.sh:# beforeShellExecution hook"* | "post-edit-lint.sh:# afterFileEdit hook"* | "post-edit-lint.sh:# Post-edit hook:"* | "pre-commit-check.sh:# Pre-commit hook:"*)
          backup_old_file "$rel" ;;
      esac
    done
  fi

  local skills_dir="${CURSOR_DIR}/skills"
  local old_skills=("${SKILL_DIRS[@]}")
  if [ -f "${skills_dir}/MANIFEST" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      old_skills+=("${line%%/*}")
    done < "${skills_dir}/MANIFEST"
  fi
  # A skill folder is ours only when its description matches the bundled copy, so a user's own
  # skill that shares a bundled name stays where it is. With --no-skills the plugin gets no
  # skills, so the old folders stay in use.
  local ours theirs seen=" "
  for skill in "${old_skills[@]}"; do
    case "$seen" in *" ${skill} "*) continue ;; esac
    seen="${seen}${skill} "
    rel="skills/${skill}"
    [ -d "${CURSOR_DIR}/${rel}" ] || continue
    if [ "$WITH_SKILLS" != true ]; then
      log "  ${DIM}[left]${RESET} ~/.cursor/${rel}"
      continue
    fi
    ours="$(skill_description "${WORK_DIR}/skills/${skill}/SKILL.md")"
    theirs="$(skill_description "${CURSOR_DIR}/${rel}/SKILL.md")"
    if [ -n "$ours" ] && [ "$ours" = "$theirs" ]; then
      backup_old_file "$rel"
    else
      log "  ${DIM}[left]${RESET} ~/.cursor/${rel} (not the bundled copy)"
    fi
  done
  if [ -f "${skills_dir}/MANIFEST" ]; then
    backup_old_file "skills/MANIFEST"
  fi

  if [ "$OLD_LAYOUT_MOVED" -gt 0 ]; then
    log ""
    if [ "$DRY_RUN" = true ]; then
      log "  ${YELLOW}Old Team Avatar files in ${CURSOR_DIR} would move to ${BACKUP_DIR}${RESET}"
    else
      log "  ${YELLOW}Old Team Avatar files in ${CURSOR_DIR} are now in ${BACKUP_DIR}${RESET}"
    fi
    log ""
  fi
}

# permissions.json is a user-level file. Create it when missing and leave an existing different one alone.
install_user_permissions() {
  local src="${WORK_DIR}/permissions.json"
  local dest="${CURSOR_DIR}/permissions.json"

  [ -f "$src" ] || return 0
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    log "${YELLOW}Left ${dest} unchanged: it differs from the Team Avatar permissions.json.${RESET}"
    log ""
    return 0
  fi
  install_file_set "$WORK_DIR" "$CURSOR_DIR" "permissions" permissions.json
}

install_plugin_files() {
  install_file_set "$WORK_DIR" "$PLUGIN_DIR" "plugin manifest" "$PLUGIN_MANIFEST"
  install_file_set "${WORK_DIR}/hooks" "${PLUGIN_DIR}/hooks" "plugin hook config" "$PLUGIN_HOOKS_CONFIG"
  if [ "$DRY_RUN" = false ]; then
    local file
    for file in "${HOOK_FILES[@]}"; do
      if [ -f "${PLUGIN_DIR}/hooks/${file}" ]; then
        chmod +x "${PLUGIN_DIR}/hooks/${file}"
      fi
    done
  fi
  install_user_permissions
}

# ---------------------------------------------------------------------------
# Main install logic
# ---------------------------------------------------------------------------

install_agents() {
  local src_dir="$1"

  if [ "$SCOPE" = "user" ]; then
    backup_old_user_layout
    log "Installing local plugin to ${BOLD}${PLUGIN_DIR}${RESET}"
    log ""
    install_to_dir "$PLUGIN_DIR"
    install_plugin_files
  else
    log "Installing to ${BOLD}${CURSOR_DIR}${RESET}"
    log ""
    install_to_dir "$CURSOR_DIR"
  fi

  if [ "$ALSO_CLAUDE" = true ]; then
    local claude_dir
    if [ "$SCOPE" = "user" ]; then
      claude_dir="${HOME}/.claude"
    else
      claude_dir="./.claude"
    fi
    log "${DIM}Also installing to ${claude_dir} (Claude Code compatibility)${RESET}"
    log ""
    install_to_dir "$claude_dir"
  fi

  if [ "$ALSO_CODEX" = true ]; then
    local codex_dir
    if [ "$SCOPE" = "user" ]; then
      codex_dir="${HOME}/.codex"
    else
      codex_dir="./.codex"
    fi
    log "${DIM}Also installing to ${codex_dir} (Codex compatibility)${RESET}"
    log ""
    install_to_dir "$codex_dir"
  fi

  log "${BOLD}Summary${RESET}"
  log "  ${DIM}Mode: ${CURSOR_MODE_LABEL}${RESET}"
  if [ "$WITH_SKILLS" = true ]; then
    log "  ${GREEN}Agents: ${#AGENT_FILES[@]} | Commands: ${#COMMAND_FILES[@]} | Hooks: ${#HOOK_FILES[@]} | Skills: ${#SKILL_DIRS[@]}${RESET}"
  else
    log "  ${GREEN}Agents: ${#AGENT_FILES[@]} | Commands: ${#COMMAND_FILES[@]} | Hooks: ${#HOOK_FILES[@]} | Skills: skipped${RESET}"
  fi
  log ""

  if [ "$SCOPE" = "user" ] && [ "$DRY_RUN" = false ]; then
    log "  ${YELLOW}Restart Cursor or run Developer: Reload Window. Then open Customize and check that the${RESET}"
    log "  ${YELLOW}${PLUGIN_NAME} plugin shows its rules, agents, commands, skills, and hooks.${RESET}"
    log ""
    # Cursor also loads Claude Code plugins, and the Claude Code edition's agents take over these names.
    if grep -qs '"team-avatar@' "${HOME}/.claude/plugins/installed_plugins.json"; then
      log "  ${YELLOW}The Claude Code edition of Team Avatar is installed too. Cursor loads Claude Code${RESET}"
      log "  ${YELLOW}plugins, and that edition's agents take over the same names, so these agents don't run.${RESET}"
      log "  ${YELLOW}To use this edition in Cursor, turn off Include Third-Party Plugins, Skills, and Other${RESET}"
      log "  ${YELLOW}Configs in Cursor Settings, or uninstall one edition.${RESET}"
      log ""
    fi
  fi
}

# ---------------------------------------------------------------------------
# Uninstall logic
# ---------------------------------------------------------------------------

uninstall_agents() {
  log "${BOLD}oh-my-cursor${RESET} v${VERSION}"
  log "${DIM}${CURSOR_MODE_LABEL}${RESET}"
  log ""

  if [ "$DRY_RUN" = true ]; then
    log "${YELLOW}Dry run mode -- no changes will be made${RESET}"
    log ""
  fi

  local removed=0
  local file target

  log "Removing agents from ${BOLD}${AGENTS_DIR}${RESET}"
  log ""

  for file in "${AGENT_FILES[@]}" "${LEGACY_AGENT_FILES[@]}"; do
    target="${AGENTS_DIR}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${RED}[remove]${RESET} ${file}"
      else
        rm -f "$target"
        log "  ${RED}[removed]${RESET} ${file}"
      fi
      removed=$((removed + 1))
    fi
  done

  for file in "${PROTOCOL_FILES[@]}" "${LEGACY_PROTOCOL_FILES[@]}"; do
    target="${AGENTS_DIR}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${RED}[remove]${RESET} ${file}"
      else
        rm -f "$target"
        log "  ${RED}[removed]${RESET} ${file}"
      fi
      removed=$((removed + 1))
    fi
  done

  if [ -d "${AGENTS_DIR}/protocols" ]; then
    [ "$DRY_RUN" = false ] && rmdir "${AGENTS_DIR}/protocols" 2>/dev/null || true
  fi

  log ""
  log "Removing commands from ${BOLD}${COMMANDS_DIR}${RESET}"
  log ""

  for file in "${COMMAND_FILES[@]}"; do
    target="${COMMANDS_DIR}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${RED}[remove]${RESET} ${file}"
      else
        rm -f "$target"
        log "  ${RED}[removed]${RESET} ${file}"
      fi
      removed=$((removed + 1))
    fi
  done

  log ""
  log "Removing hooks from ${BOLD}${HOOKS_DIR}${RESET}"
  log ""

  for file in "${HOOK_FILES[@]}"; do
    target="${HOOKS_DIR}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${RED}[remove]${RESET} ${file}"
      else
        rm -f "$target"
        log "  ${RED}[removed]${RESET} ${file}"
      fi
      removed=$((removed + 1))
    fi
  done

  for file in "${CONFIG_FILES[@]}"; do
    target="${CURSOR_DIR}/${file}"
    if [ -f "$target" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${RED}[remove]${RESET} ${file}"
      else
        rm -f "$target"
        log "  ${RED}[removed]${RESET} ${file}"
      fi
      removed=$((removed + 1))
    fi
  done

  # Remove our git pre-commit hook (only if it's ours)
  git_pc_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "$git_pc_dir" ] && [ -f "${git_pc_dir}/hooks/pre-commit" ] && grep -q "oh-my-cursor" "${git_pc_dir}/hooks/pre-commit" 2>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
      log "  ${RED}[remove]${RESET} git pre-commit hook"
    else
      rm -f "${git_pc_dir}/hooks/pre-commit"
      log "  ${RED}[removed]${RESET} git pre-commit hook"
    fi
    removed=$((removed + 1))
  fi

  log ""
  log "Removing rules from ${BOLD}${RULES_DIR}${RESET}"
  log ""

  target="${RULES_DIR}/${RULE_FILE}"
  if [ -f "$target" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "  ${RED}[remove]${RESET} ${RULE_FILE}"
    else
      rm -f "$target"
      log "  ${RED}[removed]${RESET} ${RULE_FILE}"
    fi
    removed=$((removed + 1))
  fi

  target="${RULES_DIR}/${RULE_FILE_DISABLED}"
  if [ -f "$target" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "  ${RED}[remove]${RESET} ${RULE_FILE_DISABLED}"
    else
      rm -f "$target"
      log "  ${RED}[removed]${RESET} ${RULE_FILE_DISABLED}"
    fi
    removed=$((removed + 1))
  fi

  log ""
  log "Removing skills from ${BOLD}${SKILLS_DIR}${RESET}"
  log ""

  local skill skill_dir
  for skill in "${SKILL_DIRS[@]}"; do
    skill_dir="${SKILLS_DIR}/${skill}"
    if [ -d "$skill_dir" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${RED}[remove]${RESET} ${skill}/"
      else
        rm -rf "$skill_dir"
        log "  ${RED}[removed]${RESET} ${skill}/"
      fi
      removed=$((removed + 1))
    fi
  done

  log ""
  log "${BOLD}Summary${RESET}"
  log "  ${DIM}Mode: ${CURSOR_MODE_LABEL}${RESET}"
  if [ "$removed" -gt 0 ]; then
    log "  ${RED}Removed: ${removed}${RESET}"
  else
    log "  ${DIM}Nothing to remove${RESET}"
  fi
}

uninstall_plugin() {
  log "${BOLD}oh-my-cursor${RESET} v${VERSION}"
  log "${DIM}${CURSOR_MODE_LABEL}${RESET}"
  log ""

  if [ "$DRY_RUN" = true ]; then
    log "${YELLOW}Dry run mode -- no changes will be made${RESET}"
    log ""
  fi

  log "Removing plugin ${BOLD}${PLUGIN_DIR}${RESET}"
  log ""

  local removed=0
  if [ -d "$PLUGIN_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "  ${RED}[remove]${RESET} ${PLUGIN_DIR}"
    else
      rm -rf "$PLUGIN_DIR"
      log "  ${RED}[removed]${RESET} ${PLUGIN_DIR}"
    fi
    removed=1
  fi
  log ""

  backup_old_user_layout

  log "${BOLD}Summary${RESET}"
  log "  ${DIM}Mode: ${CURSOR_MODE_LABEL}${RESET}"
  if [ $((removed + OLD_LAYOUT_MOVED)) -gt 0 ]; then
    log "  ${RED}Removed plugin: ${removed} | Old files backed up: ${OLD_LAYOUT_MOVED}${RESET}"
  else
    log "  ${DIM}Nothing to remove${RESET}"
  fi
}

# ---------------------------------------------------------------------------
# Skills installation
# ---------------------------------------------------------------------------

install_skills() {
  local src_skills_dir="${WORK_DIR}/skills"

  if [ ! -d "$src_skills_dir" ]; then
    log "${YELLOW}Warning: bundled skills not found in work directory. Skipping.${RESET}"
    log ""
    return 0
  fi

  log "Installing skills to ${BOLD}${SKILLS_DIR}${RESET}"
  log ""

  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$SKILLS_DIR"
  fi

  local installed=0 skipped=0 updated=0
  local skill skill_src skill_dest

  for skill in "${SKILL_DIRS[@]}"; do
    skill_src="${src_skills_dir}/${skill}"
    skill_dest="${SKILLS_DIR}/${skill}"

    if [ ! -d "$skill_src" ]; then
      log_verbose "  ${DIM}[skip]${RESET} ${skill} (source not found)"
      continue
    fi

    if [ ! -d "$skill_dest" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${GREEN}[new]${RESET} ${skill}/"
      else
        cp -r "$skill_src" "$skill_dest"
        log "  ${GREEN}[installed]${RESET} ${skill}/"
      fi
      installed=$((installed + 1))
    elif diff -rq --exclude='.DS_Store' "$skill_src" "$skill_dest" >/dev/null 2>&1; then
      log "  ${DIM}[unchanged]${RESET} ${skill}/"
      skipped=$((skipped + 1))
    elif [ "$FORCE" = true ]; then
      if [ "$DRY_RUN" = true ]; then
        log "  ${YELLOW}[update]${RESET} ${skill}/"
      else
        rm -rf "$skill_dest"
        cp -r "$skill_src" "$skill_dest"
        log "  ${YELLOW}[updated]${RESET} ${skill}/"
      fi
      updated=$((updated + 1))
    else
      log "  ${YELLOW}[skipped]${RESET} ${skill}/ ${DIM}(use --force to overwrite)${RESET}"
      skipped=$((skipped + 1))
    fi
  done

  log ""

  # Cursor also loads user skills from ~/.agents/skills/, so a skill there with a bundled name shows twice.
  if [ -d "${HOME}/.agents/skills" ]; then
    local same=""
    for skill in "${SKILL_DIRS[@]}"; do
      [ -d "${HOME}/.agents/skills/${skill}" ] && same="${same} ${skill}"
    done
    if [ -n "$same" ]; then
      log "${DIM}Note: ~/.agents/skills/ has skills with bundled names:${same}. Cursor loads both copies.${RESET}"
      log ""
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  setup_colors
  parse_args "$@"
  resolve_dirs

  if [ "$DISABLE" = true ] && [ "$ENABLE" = true ]; then
    log "${RED}Cannot use --disable and --enable together.${RESET}" >&2
    exit 1
  fi

  if [ "$DISABLE" = true ] || [ "$ENABLE" = true ]; then
    toggle_orchestrator_rule
    return 0
  fi

  if [ "$UNINSTALL" = true ]; then
    if [ "$SCOPE" = "user" ]; then
      # The source copy tells the old bundled skills apart from a user's own same-named ones.
      # Uninstall still works offline. Old skill folders then stay where they are.
      WORK_DIR=$(mktemp -d)
      if ! copy_sources_from_local_repo "$WORK_DIR" && ! download_sources_from_github "$WORK_DIR" 2>/dev/null; then
        log "${YELLOW}Could not read the bundled skills, so old skill folders stay where they are.${RESET}"
        log ""
      fi
      uninstall_plugin
    else
      uninstall_agents
    fi
    return 0
  fi

  WORK_DIR=$(mktemp -d)

  log "${BOLD}oh-my-cursor${RESET} v${VERSION}"
  log "${DIM}${CURSOR_MODE_LABEL}${RESET}"
  log ""

  if [ "$DRY_RUN" = true ]; then
    log "${YELLOW}Dry run mode -- no changes will be made${RESET}"
    log ""
  fi

  log_verbose "Scope: ${SCOPE}"
  log_verbose "Target: ${PLUGIN_DIR:-$CURSOR_DIR}"
  log_verbose "Force: ${FORCE}"

  create_source_files "$WORK_DIR"
  install_agents "$WORK_DIR"

  if [ "$WITH_SKILLS" = true ]; then
    install_skills
  fi
}

main "$@"
} # ensure entire script is downloaded before execution
