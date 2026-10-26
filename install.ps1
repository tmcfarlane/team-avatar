#Requires -Version 5.1
<#
.SYNOPSIS
    oh-my-cursor installer for Windows.

.DESCRIPTION
    Install Team Avatar agent configurations for Cursor on Windows.
    PowerShell equivalent of install.sh.

.PARAMETER Scope
    Install scope: 'user' (default) installs a local Cursor plugin at
    ~/.cursor/plugins/local/team-avatar/ (on Enterprise, an admin must turn on
    Allow Local Plugin Imports). 'project' installs into ./.cursor/.

.PARAMETER Force
    Overwrite existing files.

.PARAMETER DryRun
    Show what would be done without making changes.

.PARAMETER Verbose
    Enable verbose output.

.PARAMETER Uninstall
    Remove the installed plugin (user scope) or the installed files (project scope).

.PARAMETER Disable
    Disable orchestration (rename the plugin's rule so Cursor stops applying it).

.PARAMETER Enable
    Re-enable orchestration (rename rule back).

.PARAMETER AlsoClaude
    Also install to .claude/agents/ for Claude Code compatibility.

.PARAMETER AlsoCodex
    Also install to .codex/agents/ for Codex compatibility.

.PARAMETER NoSkills
    Skip installing bundled agent skills (skills are installed by default).

.EXAMPLE
    .\install.ps1
    # Install to user scope (default)

.EXAMPLE
    .\install.ps1 -Scope project
    # Install to project scope

.EXAMPLE
    .\install.ps1 -Force
    # Overwrite existing files

.EXAMPLE
    .\install.ps1 -DryRun
    # Preview changes

.EXAMPLE
    .\install.ps1 -Uninstall
    # Remove all components

.EXAMPLE
    irm https://raw.githubusercontent.com/tmcfarlane/team-avatar/main/install.ps1 | iex
    # One-liner install from GitHub (default options only; clone the repo to pass flags)
#>

[CmdletBinding()]
param(
    [ValidateSet('user', 'project')]
    [string]$Scope = 'user',

    [switch]$Force,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Disable,
    [switch]$Enable,
    [switch]$AlsoClaude,
    [switch]$AlsoCodex,
    [switch]$NoSkills
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$VERSION = '0.5.0'
$CURSOR_MODE_LABEL = 'Team Avatar (Cursor 3.27+)'
$PLUGIN_NAME = 'team-avatar'

$AGENT_FILES = @('aang.md', 'sokka.md', 'katara.md', 'zuko.md', 'toph.md', 'appa.md', 'momo.md', 'iroh.md')
$PROTOCOL_FILES = @('protocols/team-avatar.md')
$COMMAND_FILES = @('plan.md', 'build.md', 'search.md', 'fix.md', 'tasks.md', 'scout.md', 'cactus-juice.md', 'doc.md', 'image.md')
$HOOK_FILES = @('post-edit-lint.sh', 'pre-commit-check.sh', 'guard-shell.sh')
$CONFIG_FILES = @('hooks.json', 'permissions.json')
$PLUGIN_FILES = @('.cursor-plugin/plugin.json', 'hooks/hooks.json')
# Every shipped command names its character as a whole word. cactus-juice.md names none, so its own phrase marks it as ours.
$CHARACTER_PATTERN = '\b(aang|sokka|katara|zuko|toph|appa|momo|iroh|cactus juice)\b'
# Cursor on Windows runs hook commands through PowerShell, so the bash hooks can't run there.
$ON_WINDOWS = [IO.Path]::DirectorySeparatorChar -eq '\'
$RULE_FILE = 'orchestrator.mdc'
$RULE_FILE_DISABLED = 'orchestrator.mdc.disabled'
$SKILL_DIRS = @(
    'architect'
    'codebase-search'
    'crafting-effective-readmes'
    'create-an-asset'
    'cursor-image-generation'
    'debugging'
    'design-patterns-implementation'
    'docs-write'
    'documentation-engineer'
    'documentation-writing'
    'exploring-codebases'
    'frontend-builder'
    'implementing-figma-designs'
    'mgrep-code-search'
    'planning'
    'refactoring'
    'refactoring-patterns'
    'technical-roadmap-planning'
    'vercel-composition-patterns'
    'vercel-react-best-practices'
    'web-design-guidelines'
)

$LEGACY_AGENT_FILES = @('atlas.md', 'explore.md', 'generalPurpose.md', 'hephaestus.md', 'librarian.md', 'metis.md', 'momus.md', 'multimodal-looker.md', 'oracle.md', 'prometheus.md', 'sisyphus.md')
$LEGACY_PROTOCOL_FILES = @('protocols/swarm-coordinator.md')

$SOURCE_BASE_URL_DEFAULT = 'https://raw.githubusercontent.com/tmcfarlane/team-avatar/main'
$SourceBaseUrl = if ($env:OH_MY_CURSOR_SOURCE_BASE_URL) { $env:OH_MY_CURSOR_SOURCE_BASE_URL } else { $SOURCE_BASE_URL_DEFAULT }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    Write-Host $Message
}

function Write-LogVerbose {
    param([string]$Message)
    if ($VerbosePreference -ne 'SilentlyContinue') {
        Write-Host $Message -ForegroundColor DarkGray
    }
}

function Get-ScriptDir {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return $null
}

# ---------------------------------------------------------------------------
# Directory resolution
# ---------------------------------------------------------------------------

function Resolve-InstallDirs {
    param([string]$InstallScope)

    if ($InstallScope -eq 'user') {
        $cursorDir = Join-Path $HOME '.cursor'
        $pluginDir = Join-Path (Join-Path (Join-Path $cursorDir 'plugins') 'local') $PLUGIN_NAME
        $rootDir = $pluginDir
    }
    else {
        $cursorDir = Join-Path '.' '.cursor'
        $pluginDir = $null
        $rootDir = $cursorDir
    }

    return @{
        CursorDir   = $cursorDir
        PluginDir   = $pluginDir
        RootDir     = $rootDir
        AgentsDir   = Join-Path $rootDir 'agents'
        RulesDir    = Join-Path $rootDir 'rules'
        CommandsDir = Join-Path $rootDir 'commands'
        HooksDir    = Join-Path $rootDir 'hooks'
        SkillsDir   = Join-Path $rootDir 'skills'
    }
}

# ---------------------------------------------------------------------------
# Toggle orchestration rule
# ---------------------------------------------------------------------------

function Set-OrchestratorRule {
    param(
        [hashtable]$Dirs,
        [bool]$DisableRule,
        [bool]$IsDryRun
    )

    $rulePath = Join-Path $Dirs.RulesDir $RULE_FILE
    $disabledPath = Join-Path $Dirs.RulesDir $RULE_FILE_DISABLED

    Write-Host "oh-my-cursor v${VERSION}" -ForegroundColor White
    Write-Host $CURSOR_MODE_LABEL -ForegroundColor DarkGray
    Write-Host ''

    if ($DisableRule) {
        if (Test-Path $rulePath) {
            if ($IsDryRun) {
                Write-Host "  [would disable] ${RULE_FILE} in $($Dirs.RulesDir)" -ForegroundColor Yellow
            }
            else {
                Move-Item -Path $rulePath -Destination $disabledPath -Force
                Write-Host "  [disabled] ${RULE_FILE} - orchestration off. Agents and commands still available." -ForegroundColor Green
            }
        }
        else {
            if (Test-Path $disabledPath) {
                Write-Host "  Already disabled (${RULE_FILE_DISABLED} present)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "  No rule file found at ${rulePath}" -ForegroundColor Yellow
            }
        }
    }
    else {
        if (Test-Path $disabledPath) {
            if ($IsDryRun) {
                Write-Host "  [would enable] ${RULE_FILE} in $($Dirs.RulesDir)" -ForegroundColor Yellow
            }
            else {
                Move-Item -Path $disabledPath -Destination $rulePath -Force
                Write-Host "  [enabled] ${RULE_FILE} - Team Avatar orchestration on." -ForegroundColor Green
            }
        }
        else {
            if (Test-Path $rulePath) {
                Write-Host "  Already enabled (${RULE_FILE} present)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "  No disabled rule found at ${disabledPath}" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Source file acquisition
# ---------------------------------------------------------------------------

function Copy-SourcesFromLocalRepo {
    param([string]$OutDir)

    $scriptDir = Get-ScriptDir
    if (-not $scriptDir) { return $false }
    if (-not (Test-Path (Join-Path $scriptDir 'agents'))) { return $false }
    if (-not (Test-Path (Join-Path $scriptDir 'rules'))) { return $false }

    try {
        foreach ($file in $AGENT_FILES) {
            Copy-Item (Join-Path (Join-Path $scriptDir 'agents') $file) (Join-Path $OutDir $file) -Force
        }

        foreach ($file in $PROTOCOL_FILES) {
            $destSubDir = Join-Path $OutDir (Split-Path $file -Parent)
            if (-not (Test-Path $destSubDir)) { New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null }
            Copy-Item (Join-Path (Join-Path $scriptDir 'agents') $file) (Join-Path $OutDir $file) -Force
        }

        Copy-Item (Join-Path (Join-Path $scriptDir 'rules') $RULE_FILE) (Join-Path $OutDir $RULE_FILE) -Force

        $cmdSrcDir = Join-Path $scriptDir 'commands'
        if (Test-Path $cmdSrcDir) {
            $cmdOutDir = Join-Path $OutDir 'commands'
            if (-not (Test-Path $cmdOutDir)) { New-Item -ItemType Directory -Path $cmdOutDir -Force | Out-Null }
            foreach ($file in $COMMAND_FILES) {
                Copy-Item (Join-Path $cmdSrcDir $file) (Join-Path $cmdOutDir $file) -Force
            }
        }

        $hooksSrcDir = Join-Path $scriptDir 'hooks'
        if (Test-Path $hooksSrcDir) {
            $hooksOutDir = Join-Path $OutDir 'hooks'
            if (-not (Test-Path $hooksOutDir)) { New-Item -ItemType Directory -Path $hooksOutDir -Force | Out-Null }
            foreach ($file in $HOOK_FILES) {
                Copy-Item (Join-Path $hooksSrcDir $file) (Join-Path $hooksOutDir $file) -Force
            }
        }

        foreach ($file in $CONFIG_FILES) {
            $configSrc = Join-Path $scriptDir $file
            if (Test-Path $configSrc) {
                Copy-Item $configSrc (Join-Path $OutDir $file) -Force
            }
        }

        foreach ($file in $PLUGIN_FILES) {
            $pluginSrc = Join-Path $scriptDir $file
            $pluginOut = Join-Path $OutDir $file
            New-Item -ItemType Directory -Path (Split-Path $pluginOut -Parent) -Force | Out-Null
            Copy-Item $pluginSrc $pluginOut -Force
        }

        $skillsSrcDir = Join-Path $scriptDir 'skills'
        if (Test-Path $skillsSrcDir) {
            Copy-Item $skillsSrcDir (Join-Path $OutDir 'skills') -Recurse -Force
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-SourcesFromGitHub {
    param([string]$OutDir)

    try {
        foreach ($file in $AGENT_FILES) {
            $url = "${SourceBaseUrl}/agents/${file}"
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $OutDir $file) -UseBasicParsing
        }

        foreach ($file in $PROTOCOL_FILES) {
            $destSubDir = Join-Path $OutDir (Split-Path $file -Parent)
            if (-not (Test-Path $destSubDir)) { New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null }
            $url = "${SourceBaseUrl}/agents/${file}"
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $OutDir $file) -UseBasicParsing
        }

        $url = "${SourceBaseUrl}/rules/${RULE_FILE}"
        Invoke-WebRequest -Uri $url -OutFile (Join-Path $OutDir $RULE_FILE) -UseBasicParsing

        $cmdOutDir = Join-Path $OutDir 'commands'
        if (-not (Test-Path $cmdOutDir)) { New-Item -ItemType Directory -Path $cmdOutDir -Force | Out-Null }
        foreach ($file in $COMMAND_FILES) {
            $url = "${SourceBaseUrl}/commands/${file}"
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $cmdOutDir $file) -UseBasicParsing
        }

        $hooksOutDir = Join-Path $OutDir 'hooks'
        if (-not (Test-Path $hooksOutDir)) { New-Item -ItemType Directory -Path $hooksOutDir -Force | Out-Null }
        foreach ($file in $HOOK_FILES) {
            $url = "${SourceBaseUrl}/hooks/${file}"
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $hooksOutDir $file) -UseBasicParsing
        }

        foreach ($file in $CONFIG_FILES) {
            Invoke-WebRequest -Uri "${SourceBaseUrl}/${file}" -OutFile (Join-Path $OutDir $file) -UseBasicParsing
        }

        foreach ($file in $PLUGIN_FILES) {
            $pluginOut = Join-Path $OutDir $file
            New-Item -ItemType Directory -Path (Split-Path $pluginOut -Parent) -Force | Out-Null
            Invoke-WebRequest -Uri "${SourceBaseUrl}/${file}" -OutFile $pluginOut -UseBasicParsing
        }

        # Download skills via MANIFEST
        $manifestUrl = "${SourceBaseUrl}/skills/MANIFEST"
        $manifestTmp = Join-Path ([System.IO.Path]::GetTempPath()) "oh-my-cursor-manifest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        try {
            Invoke-WebRequest -Uri $manifestUrl -OutFile $manifestTmp -UseBasicParsing
            $skillsOutDir = Join-Path $OutDir 'skills'
            if (-not (Test-Path $skillsOutDir)) { New-Item -ItemType Directory -Path $skillsOutDir -Force | Out-Null }
            $manifestLines = Get-Content $manifestTmp
            foreach ($skillFile in $manifestLines) {
                if ([string]::IsNullOrWhiteSpace($skillFile)) { continue }
                $skillFileDir = Join-Path $skillsOutDir (Split-Path $skillFile -Parent)
                if (-not (Test-Path $skillFileDir)) { New-Item -ItemType Directory -Path $skillFileDir -Force | Out-Null }
                try {
                    Invoke-WebRequest -Uri "${SourceBaseUrl}/skills/${skillFile}" -OutFile (Join-Path $skillsOutDir $skillFile) -UseBasicParsing
                }
                catch {
                    # Non-fatal: individual skill file download failure
                }
            }
            Copy-Item $manifestTmp (Join-Path $skillsOutDir 'MANIFEST') -Force
        }
        catch {
            # MANIFEST not available, skip skills
        }
        finally {
            if (Test-Path $manifestTmp) { Remove-Item $manifestTmp -Force -ErrorAction SilentlyContinue }
        }

        return $true
    }
    catch {
        return $false
    }
}

function New-SourceFiles {
    param([string]$Dir)

    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }

    if (Copy-SourcesFromLocalRepo -OutDir $Dir) {
        Write-LogVerbose 'Using local repo sources'
        return
    }

    if (Get-SourcesFromGitHub -OutDir $Dir) {
        Write-LogVerbose "Downloaded sources from ${SourceBaseUrl}"
        return
    }

    Write-Host 'Failed to acquire source files.' -ForegroundColor Red
    Write-Host 'Tried local repo checkout and GitHub raw download.' -ForegroundColor DarkGray
    Write-Host 'Override the download base with $env:OH_MY_CURSOR_SOURCE_BASE_URL=...' -ForegroundColor DarkGray
    throw 'Source acquisition failed'
}

# ---------------------------------------------------------------------------
# Install a set of files from src_dir to dest_dir
# ---------------------------------------------------------------------------

function Install-FileSet {
    param(
        [string]$SrcDir,
        [string]$DestDir,
        [string]$Label,
        [string[]]$Files,
        [bool]$IsForce,
        [bool]$IsDryRun
    )

    if ($Files.Count -eq 0) { return }

    if (-not $IsDryRun) {
        if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    }

    Write-Host "Installing ${Label} to ${DestDir}" -ForegroundColor White
    Write-Host ''

    foreach ($file in $Files) {
        $src = Join-Path $SrcDir $file
        $dest = Join-Path $DestDir $file

        if (-not (Test-Path $src)) {
            Write-LogVerbose "  [skip] ${file} (source not found)"
            continue
        }

        $destSubDir = Split-Path $dest -Parent
        if (-not $IsDryRun -and -not (Test-Path $destSubDir)) {
            New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null
        }

        if (-not (Test-Path $dest)) {
            if ($IsDryRun) {
                Write-Host "  [new] ${file}" -ForegroundColor Green
            }
            else {
                try {
                    Copy-Item $src $dest -Force
                    Write-Host "  [installed] ${file}" -ForegroundColor Green
                }
                catch {
                    Write-Host "  [failed] ${file}" -ForegroundColor Red
                    continue
                }
            }
        }
        elseif ((Get-FileHash $src).Hash -eq (Get-FileHash $dest).Hash) {
            Write-Host "  [unchanged] ${file}" -ForegroundColor DarkGray
        }
        elseif ($IsForce) {
            if ($IsDryRun) {
                Write-Host "  [update] ${file}" -ForegroundColor Yellow
            }
            else {
                try {
                    Copy-Item $src $dest -Force
                    Write-Host "  [updated] ${file}" -ForegroundColor Yellow
                }
                catch {
                    Write-Host "  [failed] ${file}" -ForegroundColor Red
                    continue
                }
            }
        }
        else {
            Write-Host "  [skipped] ${file} (use -Force to overwrite)" -ForegroundColor Yellow
        }
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Migrate legacy agent files (Greek mythology -> ATLA)
# ---------------------------------------------------------------------------

function Remove-LegacyAgents {
    param(
        [string]$AgentsDir,
        [bool]$IsDryRun
    )

    $migrated = 0

    foreach ($file in $LEGACY_AGENT_FILES) {
        $target = Join-Path $AgentsDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [migrate] removing legacy ${file}" -ForegroundColor Yellow
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [migrated] removed legacy ${file}" -ForegroundColor Yellow
            }
            $migrated++
        }
    }

    foreach ($file in $LEGACY_PROTOCOL_FILES) {
        $target = Join-Path $AgentsDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [migrate] removing legacy ${file}" -ForegroundColor Yellow
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [migrated] removed legacy ${file}" -ForegroundColor Yellow
            }
            $migrated++
        }
    }

    if ($migrated -gt 0) {
        Write-Host ''
        Write-Host '  Migrated from v0.1 (Greek mythology) to v0.2 (Team Avatar)' -ForegroundColor Yellow
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------
# Install to a specific tool directory (cursor, claude, or codex)
# ---------------------------------------------------------------------------

function Install-GitPreCommitHook {
    param([bool]$IsDryRun)
    # Defense-in-depth: the beforeShellExecution guard only sees shell `git commit`; Cursor's
    # agent can also commit via its native git path (observed on Cursor 3.9), bypassing it.
    # A real git pre-commit hook catches anti-pattern commits regardless of how they are made.
    $gitDir = (& git rev-parse --absolute-git-dir 2>$null)
    if (-not $gitDir) { Write-Host '  [skip] git pre-commit hook (not a git repo)'; return }
    $hook = Join-Path (Join-Path $gitDir 'hooks') 'pre-commit'
    if ((Test-Path $hook) -and -not (Select-String -Path $hook -Pattern 'oh-my-cursor' -Quiet)) {
        Write-Host '  [skip] git pre-commit hook (existing non-OMC hook)'; return
    }
    if ($IsDryRun) { Write-Host "  [new] git pre-commit hook ($hook)" -ForegroundColor Green; return }
    New-Item -ItemType Directory -Path (Split-Path $hook -Parent) -Force | Out-Null
    $body = @'
#!/usr/bin/env bash
# oh-my-cursor defense-in-depth: catch anti-pattern commits regardless of HOW the commit is made
# (shell, git CLI, or Cursor's native git path). The beforeShellExecution guard only sees shell
# `git commit`; this git-native hook covers commits that bypass the shell.
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exec "$root/.cursor/hooks/pre-commit-check.sh"
'@
    # LF line endings so the hook runs under Git-for-Windows bash / WSL
    [IO.File]::WriteAllText($hook, ($body -replace "`r`n", "`n"))
    Write-Host "  [installed] git pre-commit hook ($hook)" -ForegroundColor Green
}

function Install-ToDir {
    param(
        [string]$TargetDir,
        [string]$WorkDir,
        [bool]$IsForce,
        [bool]$IsDryRun
    )

    $agentsDir = Join-Path $TargetDir 'agents'
    $rulesDir = Join-Path $TargetDir 'rules'
    $commandsDir = Join-Path $TargetDir 'commands'
    $hooksDir = Join-Path $TargetDir 'hooks'

    Remove-LegacyAgents -AgentsDir $agentsDir -IsDryRun $IsDryRun

    Install-FileSet -SrcDir $WorkDir -DestDir $agentsDir -Label 'agents' -Files $AGENT_FILES -IsForce $IsForce -IsDryRun $IsDryRun
    Install-FileSet -SrcDir $WorkDir -DestDir $agentsDir -Label 'protocols' -Files $PROTOCOL_FILES -IsForce $IsForce -IsDryRun $IsDryRun
    Install-FileSet -SrcDir (Join-Path $WorkDir 'commands') -DestDir $commandsDir -Label 'commands' -Files $COMMAND_FILES -IsForce $IsForce -IsDryRun $IsDryRun
    Install-FileSet -SrcDir (Join-Path $WorkDir 'hooks') -DestDir $hooksDir -Label 'hooks' -Files $HOOK_FILES -IsForce $IsForce -IsDryRun $IsDryRun

    # Hook config (hooks.json / permissions.json) is PROJECT-scoped only: its hook command
    # paths are relative to the workspace root, so user-scope (~/.cursor) would not resolve
    # across other projects. Install it only for a project-scope cursor install.
    if ($Scope -eq 'project' -and (Split-Path $TargetDir -Leaf) -eq '.cursor') {
        $configFiles = $CONFIG_FILES
        if ($ON_WINDOWS) {
            $configFiles = @($CONFIG_FILES | Where-Object { $_ -ne 'hooks.json' })
            Write-Host '  [skipped] hooks.json: the hooks are bash scripts, and Cursor runs hooks through PowerShell on Windows' -ForegroundColor Yellow
            $oldHooks = Join-Path $TargetDir 'hooks.json'
            if ((Test-Path -LiteralPath $oldHooks) -and (Select-String -LiteralPath $oldHooks -Pattern 'guard-shell.sh' -SimpleMatch -Quiet)) {
                Write-Host "  [warning] ${oldHooks} from an earlier install still runs the bash hooks, which block shell commands on Windows. Delete it, or remove its hooks." -ForegroundColor Yellow
            }
        }
        Install-FileSet -SrcDir $WorkDir -DestDir $TargetDir -Label 'config' -Files $configFiles -IsForce $IsForce -IsDryRun $IsDryRun
        Install-GitPreCommitHook -IsDryRun $IsDryRun
    }

    # Install rule file
    Write-Host "Installing rules to ${rulesDir}" -ForegroundColor White
    Write-Host ''

    if (-not $IsDryRun -and -not (Test-Path $rulesDir)) {
        New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null
    }

    $src = Join-Path $WorkDir $RULE_FILE
    $dest = Join-Path $rulesDir $RULE_FILE

    if (-not (Test-Path $dest)) {
        if ($IsDryRun) {
            Write-Host "  [new] ${RULE_FILE}" -ForegroundColor Green
        }
        else {
            try {
                Copy-Item $src $dest -Force
                Write-Host "  [installed] ${RULE_FILE}" -ForegroundColor Green
            }
            catch {
                Write-Host "  [failed] ${RULE_FILE}" -ForegroundColor Red
            }
        }
    }
    elseif ((Get-FileHash $src).Hash -eq (Get-FileHash $dest).Hash) {
        Write-Host "  [unchanged] ${RULE_FILE}" -ForegroundColor DarkGray
    }
    elseif ($IsForce) {
        if ($IsDryRun) {
            Write-Host "  [update] ${RULE_FILE}" -ForegroundColor Yellow
        }
        else {
            try {
                Copy-Item $src $dest -Force
                Write-Host "  [updated] ${RULE_FILE}" -ForegroundColor Yellow
            }
            catch {
                Write-Host "  [failed] ${RULE_FILE}" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "  [skipped] ${RULE_FILE} (use -Force to overwrite)" -ForegroundColor Yellow
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Skills installation
# ---------------------------------------------------------------------------

function Install-Skills {
    param(
        [string]$WorkDir,
        [string]$SkillsDir,
        [bool]$IsForce,
        [bool]$IsDryRun
    )

    $srcSkillsDir = Join-Path $WorkDir 'skills'

    if (-not (Test-Path $srcSkillsDir)) {
        Write-Host 'Warning: bundled skills not found in work directory. Skipping.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    Write-Host "Installing skills to ${SkillsDir}" -ForegroundColor White
    Write-Host ''

    if (-not $IsDryRun -and -not (Test-Path $SkillsDir)) {
        New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null
    }

    foreach ($skill in $SKILL_DIRS) {
        $skillSrc = Join-Path $srcSkillsDir $skill
        $skillDest = Join-Path $SkillsDir $skill

        if (-not (Test-Path $skillSrc)) {
            Write-LogVerbose "  [skip] ${skill} (source not found)"
            continue
        }

        if (-not (Test-Path $skillDest)) {
            if ($IsDryRun) {
                Write-Host "  [new] ${skill}/" -ForegroundColor Green
            }
            else {
                Copy-Item $skillSrc $skillDest -Recurse -Force
                Write-Host "  [installed] ${skill}/" -ForegroundColor Green
            }
        }
        elseif (Compare-SkillDirs -SrcDir $skillSrc -DestDir $skillDest) {
            Write-Host "  [unchanged] ${skill}/" -ForegroundColor DarkGray
        }
        elseif ($IsForce) {
            if ($IsDryRun) {
                Write-Host "  [update] ${skill}/" -ForegroundColor Yellow
            }
            else {
                Remove-Item $skillDest -Recurse -Force
                Copy-Item $skillSrc $skillDest -Recurse -Force
                Write-Host "  [updated] ${skill}/" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  [skipped] ${skill}/ (use -Force to overwrite)" -ForegroundColor Yellow
        }
    }

    Write-Host ''

    # Cursor also loads user skills from ~/.agents/skills/, so a skill there with a bundled name shows twice.
    $agentsSkillsDir = Join-Path (Join-Path $HOME '.agents') 'skills'
    if (Test-Path $agentsSkillsDir) {
        $same = @($SKILL_DIRS | Where-Object { Test-Path (Join-Path $agentsSkillsDir $_) })
        if ($same.Count -gt 0) {
            Write-Host "Note: ~/.agents/skills/ has skills with bundled names: $($same -join ' '). Cursor loads both copies." -ForegroundColor DarkGray
            Write-Host ''
        }
    }
}

function Compare-SkillDirs {
    param(
        [string]$SrcDir,
        [string]$DestDir
    )

    $srcFiles = @(Get-ChildItem $SrcDir -Recurse -File | Where-Object { $_.Name -ne '.DS_Store' })
    $destFiles = @(Get-ChildItem $DestDir -Recurse -File | Where-Object { $_.Name -ne '.DS_Store' })

    if ($srcFiles.Count -ne $destFiles.Count) { return $false }

    foreach ($srcFile in $srcFiles) {
        $relativePath = $srcFile.FullName.Substring($SrcDir.Length)
        $destFile = Join-Path $DestDir $relativePath
        if (-not (Test-Path $destFile)) { return $false }
        if ((Get-FileHash $srcFile.FullName).Hash -ne (Get-FileHash $destFile).Hash) { return $false }
    }

    return $true
}

# ---------------------------------------------------------------------------
# User scope: move the old ~/.cursor layout aside, then build the local plugin
# ---------------------------------------------------------------------------

function Test-FileMatches {
    param([string]$Path, [string]$Pattern)
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and [bool](Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)
}

# A SKILL.md's description line plus the indented lines that continue it.
function Get-SkillDescription {
    param([string]$SkillDir)
    $skillFile = Join-Path $SkillDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) { return $null }
    $block = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $skillFile)) {
        if ($block.Count -eq 0) { if ($line -match '^description:') { $block.Add($line.TrimEnd()) } }
        elseif ($line -match '^[ \t]') { $block.Add($line.TrimEnd()) }
        else { break }
    }
    if ($block.Count -eq 0) { return $null }
    return ($block -join "`n")
}

function Get-LegacyUserFiles {
    param(
        [string]$CursorDir,
        [string]$SkillsSrcDir
    )

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($file in $AGENT_FILES) {
        $path = Join-Path (Join-Path $CursorDir 'agents') $file
        $head = @(Get-Content -LiteralPath $path -TotalCount 2 -ErrorAction SilentlyContinue)
        $name = [IO.Path]::GetFileNameWithoutExtension($file)
        if ($head.Count -ge 2 -and ($head[1].TrimEnd() -ceq "name: ${name}" -or $head[1].StartsWith("name: ${name} is ", [StringComparison]::Ordinal) -or $head[1].StartsWith("name: ${name} - ", [StringComparison]::Ordinal))) { $found.Add("agents/${file}") }
    }

    foreach ($file in ($PROTOCOL_FILES + $LEGACY_PROTOCOL_FILES)) {
        $path = Join-Path (Join-Path $CursorDir 'agents') $file
        $head = @(Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($head.Count -ge 1 -and $head[0] -match '^# (Team Avatar|Swarm) Coordinator Protocol') { $found.Add("agents/${file}") }
    }

    foreach ($file in @($RULE_FILE, $RULE_FILE_DISABLED)) {
        if (Test-FileMatches (Join-Path (Join-Path $CursorDir 'rules') $file) 'Team Avatar orchestration') { $found.Add("rules/${file}") }
    }

    foreach ($file in $COMMAND_FILES) {
        if (Test-FileMatches (Join-Path (Join-Path $CursorDir 'commands') $file) $CHARACTER_PATTERN) { $found.Add("commands/${file}") }
    }

    # A user's own ~/.cursor/hooks.json may run scripts with these names, so leave them when it exists.
    if (-not (Test-Path -LiteralPath (Join-Path $CursorDir 'hooks.json'))) {
        # Ours: the second line an earlier release shipped for that script.
        $hookHeads = @{
            'guard-shell.sh'      = @('# beforeShellExecution hook')
            'post-edit-lint.sh'   = @('# afterFileEdit hook', '# Post-edit hook:')
            'pre-commit-check.sh' = @('# Pre-commit hook:')
        }
        foreach ($file in $HOOK_FILES) {
            $head = @(Get-Content -LiteralPath (Join-Path (Join-Path $CursorDir 'hooks') $file) -TotalCount 2 -ErrorAction SilentlyContinue)
            if ($head.Count -ge 2 -and @($hookHeads[$file] | Where-Object { $head[1].StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0) { $found.Add("hooks/${file}") }
        }
    }

    $skillsDir = Join-Path $CursorDir 'skills'
    $manifest = Join-Path $skillsDir 'MANIFEST'
    $skills = New-Object System.Collections.Generic.List[string]
    $skills.AddRange([string[]]$SKILL_DIRS)
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $manifest)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $skills.Add(($line.Trim() -split '/')[0]) }
        }
    }
    foreach ($skill in ($skills | Select-Object -Unique)) {
        $installed = Join-Path $skillsDir $skill
        if (-not (Test-Path -LiteralPath $installed -PathType Container)) { continue }
        if (-not $SkillsSrcDir) {
            Write-Host "  [left] skills/${skill}" -ForegroundColor DarkGray
            continue
        }
        $desc = Get-SkillDescription -SkillDir $installed
        $srcDesc = Get-SkillDescription -SkillDir (Join-Path $SkillsSrcDir $skill)
        if ($desc -and $srcDesc -and $desc -ceq $srcDesc) { $found.Add("skills/${skill}") }
        else { Write-Host "  [left] skills/${skill} (not the bundled copy)" -ForegroundColor DarkGray }
    }
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { $found.Add('skills/MANIFEST') }

    return $found
}

function Move-LegacyUserFiles {
    param(
        [string]$CursorDir,
        [string]$SkillsSrcDir,
        [bool]$IsDryRun
    )

    $legacy = @(Get-LegacyUserFiles -CursorDir $CursorDir -SkillsSrcDir $SkillsSrcDir)
    if ($legacy.Count -eq 0) { return }

    $backupDir = Join-Path $CursorDir "team-avatar-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "Moving files from the old layout in ${CursorDir} to ${backupDir}" -ForegroundColor White
    Write-Host ''

    foreach ($rel in $legacy) {
        $src = Join-Path $CursorDir $rel
        $dest = Join-Path $backupDir $rel
        if ($IsDryRun) {
            Write-Host "  [would move] ${rel} -> ${dest}" -ForegroundColor Yellow
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Move-Item -LiteralPath $src -Destination $dest -Force
        Write-Host "  [moved] ${rel} -> ${dest}" -ForegroundColor Yellow
    }

    Write-Host ''
}

function Install-UserPlugin {
    param(
        [hashtable]$Dirs,
        [string]$WorkDir,
        [bool]$IsForce,
        [bool]$IsDryRun
    )

    $skillsSrc = if ($NoSkills) { $null } else { Join-Path $WorkDir 'skills' }
    Move-LegacyUserFiles -CursorDir $Dirs.CursorDir -SkillsSrcDir $skillsSrc -IsDryRun $IsDryRun

    Write-Host "Installing local Cursor plugin to $($Dirs.PluginDir)" -ForegroundColor White
    Write-Host ''
    Install-ToDir -TargetDir $Dirs.PluginDir -WorkDir $WorkDir -IsForce $IsForce -IsDryRun $IsDryRun
    if ($ON_WINDOWS) {
        # The hook scripts stay in the plugin, but its hook config runs none of them.
        [IO.File]::WriteAllText((Join-Path (Join-Path $WorkDir 'hooks') 'hooks.json'), "{ ""version"": 1, ""hooks"": {} }`n")
        Write-Host '  Hooks are off on Windows: they are bash scripts, and Cursor runs hooks through PowerShell there.' -ForegroundColor Yellow
        Write-Host ''
    }
    Install-FileSet -SrcDir $WorkDir -DestDir $Dirs.PluginDir -Label 'plugin manifest and hook config' -Files $PLUGIN_FILES -IsForce $IsForce -IsDryRun $IsDryRun

    if (-not $IsDryRun -and [IO.Path]::DirectorySeparatorChar -eq '/') {
        foreach ($file in $HOOK_FILES) {
            $hook = Join-Path $Dirs.HooksDir $file
            if (Test-Path $hook) { & chmod +x $hook }
        }
    }

    $srcPerms = Join-Path $WorkDir 'permissions.json'
    $destPerms = Join-Path $Dirs.CursorDir 'permissions.json'
    if (Test-Path $srcPerms) {
        if (-not (Test-Path $destPerms)) {
            if ($IsDryRun) {
                Write-Host '  [new] permissions.json' -ForegroundColor Green
            }
            else {
                New-Item -ItemType Directory -Path $Dirs.CursorDir -Force | Out-Null
                Copy-Item $srcPerms $destPerms -Force
                Write-Host "  [installed] permissions.json to $($Dirs.CursorDir)" -ForegroundColor Green
            }
        }
        elseif ((Get-FileHash $srcPerms).Hash -ne (Get-FileHash $destPerms).Hash) {
            Write-Host "  [skipped] ${destPerms} exists and differs; left as is" -ForegroundColor Yellow
        }
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------
# Uninstall logic
# ---------------------------------------------------------------------------

function Uninstall-Agents {
    param(
        [hashtable]$Dirs,
        [bool]$IsDryRun
    )

    Write-Host "oh-my-cursor v${VERSION}" -ForegroundColor White
    Write-Host $CURSOR_MODE_LABEL -ForegroundColor DarkGray
    Write-Host ''

    if ($IsDryRun) {
        Write-Host 'Dry run mode -- no changes will be made' -ForegroundColor Yellow
        Write-Host ''
    }

    $removed = 0

    Write-Host "Removing agents from $($Dirs.AgentsDir)" -ForegroundColor White
    Write-Host ''

    foreach ($file in ($AGENT_FILES + $LEGACY_AGENT_FILES)) {
        $target = Join-Path $Dirs.AgentsDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [remove] ${file}" -ForegroundColor Red
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [removed] ${file}" -ForegroundColor Red
            }
            $removed++
        }
    }

    foreach ($file in ($PROTOCOL_FILES + $LEGACY_PROTOCOL_FILES)) {
        $target = Join-Path $Dirs.AgentsDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [remove] ${file}" -ForegroundColor Red
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [removed] ${file}" -ForegroundColor Red
            }
            $removed++
        }
    }

    $protocolsDir = Join-Path $Dirs.AgentsDir 'protocols'
    if (-not $IsDryRun -and (Test-Path $protocolsDir)) {
        $remaining = Get-ChildItem $protocolsDir -ErrorAction SilentlyContinue
        if (-not $remaining -or $remaining.Count -eq 0) {
            Remove-Item $protocolsDir -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host "Removing commands from $($Dirs.CommandsDir)" -ForegroundColor White
    Write-Host ''

    foreach ($file in $COMMAND_FILES) {
        $target = Join-Path $Dirs.CommandsDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [remove] ${file}" -ForegroundColor Red
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [removed] ${file}" -ForegroundColor Red
            }
            $removed++
        }
    }

    Write-Host ''
    Write-Host "Removing hooks from $($Dirs.HooksDir)" -ForegroundColor White
    Write-Host ''

    foreach ($file in $HOOK_FILES) {
        $target = Join-Path $Dirs.HooksDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [remove] ${file}" -ForegroundColor Red
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [removed] ${file}" -ForegroundColor Red
            }
            $removed++
        }
    }

    foreach ($file in $CONFIG_FILES) {
        $target = Join-Path $Dirs.CursorDir $file
        if (Test-Path $target) {
            if ($IsDryRun) {
                Write-Host "  [remove] ${file}" -ForegroundColor Red
            }
            else {
                Remove-Item $target -Force
                Write-Host "  [removed] ${file}" -ForegroundColor Red
            }
            $removed++
        }
    }

    # Remove our git pre-commit hook (only if it's ours)
    $gitDir = (& git rev-parse --absolute-git-dir 2>$null)
    if ($gitDir) {
        $gitPc = Join-Path (Join-Path $gitDir 'hooks') 'pre-commit'
        if ((Test-Path $gitPc) -and (Select-String -Path $gitPc -Pattern 'oh-my-cursor' -Quiet)) {
            if ($IsDryRun) {
                Write-Host '  [remove] git pre-commit hook' -ForegroundColor Red
            }
            else {
                Remove-Item $gitPc -Force
                Write-Host '  [removed] git pre-commit hook' -ForegroundColor Red
            }
            $removed++
        }
    }

    Write-Host ''
    Write-Host "Removing rules from $($Dirs.RulesDir)" -ForegroundColor White
    Write-Host ''

    $target = Join-Path $Dirs.RulesDir $RULE_FILE
    if (Test-Path $target) {
        if ($IsDryRun) {
            Write-Host "  [remove] ${RULE_FILE}" -ForegroundColor Red
        }
        else {
            Remove-Item $target -Force
            Write-Host "  [removed] ${RULE_FILE}" -ForegroundColor Red
        }
        $removed++
    }

    $target = Join-Path $Dirs.RulesDir $RULE_FILE_DISABLED
    if (Test-Path $target) {
        if ($IsDryRun) {
            Write-Host "  [remove] ${RULE_FILE_DISABLED}" -ForegroundColor Red
        }
        else {
            Remove-Item $target -Force
            Write-Host "  [removed] ${RULE_FILE_DISABLED}" -ForegroundColor Red
        }
        $removed++
    }

    Write-Host ''
    Write-Host "Removing skills from $($Dirs.SkillsDir)" -ForegroundColor White
    Write-Host ''

    foreach ($skill in $SKILL_DIRS) {
        $skillDir = Join-Path $Dirs.SkillsDir $skill
        if (Test-Path $skillDir) {
            if ($IsDryRun) {
                Write-Host "  [remove] ${skill}/" -ForegroundColor Red
            }
            else {
                Remove-Item $skillDir -Recurse -Force
                Write-Host "  [removed] ${skill}/" -ForegroundColor Red
            }
            $removed++
        }
    }

    Write-Host ''
    Write-Host 'Summary' -ForegroundColor White
    Write-Host "  Mode: ${CURSOR_MODE_LABEL}" -ForegroundColor DarkGray
    if ($removed -gt 0) {
        Write-Host "  Removed: ${removed}" -ForegroundColor Red
    }
    else {
        Write-Host '  Nothing to remove' -ForegroundColor DarkGray
    }
}

function Uninstall-Plugin {
    param(
        [hashtable]$Dirs,
        [bool]$IsDryRun
    )

    Write-Host "oh-my-cursor v${VERSION}" -ForegroundColor White
    Write-Host $CURSOR_MODE_LABEL -ForegroundColor DarkGray
    Write-Host ''

    if ($IsDryRun) {
        Write-Host 'Dry run mode -- no changes will be made' -ForegroundColor Yellow
        Write-Host ''
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "oh-my-cursor-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $skillsSrc = $null
    try {
        # The source copy tells the old bundled skills apart from a user's own same-named ones.
        # Uninstall still works offline. Old skill folders then stay where they are.
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        if ((Copy-SourcesFromLocalRepo -OutDir $workDir) -or (Get-SourcesFromGitHub -OutDir $workDir)) {
            $skillsSrc = Join-Path $workDir 'skills'
        }
        else {
            Write-Host 'Could not read the bundled skills, so old skill folders stay where they are.' -ForegroundColor Yellow
            Write-Host ''
        }
        Move-LegacyUserFiles -CursorDir $Dirs.CursorDir -SkillsSrcDir $skillsSrc -IsDryRun $IsDryRun
    }
    finally {
        if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $Dirs.PluginDir) {
        if ($IsDryRun) {
            Write-Host "  [remove] $($Dirs.PluginDir)" -ForegroundColor Red
        }
        else {
            Remove-Item $Dirs.PluginDir -Recurse -Force
            Write-Host "  [removed] $($Dirs.PluginDir)" -ForegroundColor Red
        }
    }
    else {
        Write-Host '  Nothing to remove' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main {
    if ($Disable -and $Enable) {
        Write-Host 'Cannot use -Disable and -Enable together.' -ForegroundColor Red
        exit 1
    }

    $dirs = Resolve-InstallDirs -InstallScope $Scope

    if ($Disable -or $Enable) {
        Set-OrchestratorRule -Dirs $dirs -DisableRule $Disable.IsPresent -IsDryRun $DryRun.IsPresent
        return
    }

    if ($Uninstall) {
        if ($Scope -eq 'user') {
            Uninstall-Plugin -Dirs $dirs -IsDryRun $DryRun.IsPresent
        }
        else {
            Uninstall-Agents -Dirs $dirs -IsDryRun $DryRun.IsPresent
        }
        return
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "oh-my-cursor-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

    try {
        Write-Host "oh-my-cursor v${VERSION}" -ForegroundColor White
        Write-Host $CURSOR_MODE_LABEL -ForegroundColor DarkGray
        Write-Host ''

        if ($DryRun) {
            Write-Host 'Dry run mode -- no changes will be made' -ForegroundColor Yellow
            Write-Host ''
        }

        Write-LogVerbose "Scope: ${Scope}"
        Write-LogVerbose "Target: $($dirs.CursorDir)"
        Write-LogVerbose "Force: ${Force}"

        New-SourceFiles -Dir $workDir

        if ($Scope -eq 'user') {
            Install-UserPlugin -Dirs $dirs -WorkDir $workDir -IsForce $Force.IsPresent -IsDryRun $DryRun.IsPresent
        }
        else {
            Write-Host "Installing to $($dirs.CursorDir)" -ForegroundColor White
            Write-Host ''
            Install-ToDir -TargetDir $dirs.CursorDir -WorkDir $workDir -IsForce $Force.IsPresent -IsDryRun $DryRun.IsPresent
        }

        if ($AlsoClaude) {
            $claudeDir = if ($Scope -eq 'user') { Join-Path $HOME '.claude' } else { Join-Path '.' '.claude' }
            Write-Host "Also installing to ${claudeDir} (Claude Code compatibility)" -ForegroundColor DarkGray
            Write-Host ''
            Install-ToDir -TargetDir $claudeDir -WorkDir $workDir -IsForce $Force.IsPresent -IsDryRun $DryRun.IsPresent
        }

        if ($AlsoCodex) {
            $codexDir = if ($Scope -eq 'user') { Join-Path $HOME '.codex' } else { Join-Path '.' '.codex' }
            Write-Host "Also installing to ${codexDir} (Codex compatibility)" -ForegroundColor DarkGray
            Write-Host ''
            Install-ToDir -TargetDir $codexDir -WorkDir $workDir -IsForce $Force.IsPresent -IsDryRun $DryRun.IsPresent
        }

        if (-not $NoSkills) {
            Install-Skills -WorkDir $workDir -SkillsDir $dirs.SkillsDir -IsForce $Force.IsPresent -IsDryRun $DryRun.IsPresent
        }

        Write-Host 'Summary' -ForegroundColor White
        Write-Host "  Mode: ${CURSOR_MODE_LABEL}" -ForegroundColor DarkGray
        if (-not $NoSkills) {
            Write-Host "  Agents: $($AGENT_FILES.Count) | Commands: $($COMMAND_FILES.Count) | Hooks: $($HOOK_FILES.Count) | Skills: $($SKILL_DIRS.Count)" -ForegroundColor Green
        }
        else {
            Write-Host "  Agents: $($AGENT_FILES.Count) | Commands: $($COMMAND_FILES.Count) | Hooks: $($HOOK_FILES.Count) | Skills: skipped" -ForegroundColor Green
        }
        Write-Host ''

        if ($Scope -eq 'user') {
            Write-Host 'Restart Cursor or run Developer: Reload Window, then open Customize and check that the' -ForegroundColor Yellow
            Write-Host '  team-avatar plugin shows its rules, agents, commands, skills, and hooks.' -ForegroundColor Yellow
            Write-Host '  On Enterprise, an admin must turn on Allow Local Plugin Imports.' -ForegroundColor Yellow
            Write-Host ''
            # Cursor also loads Claude Code plugins, and the Claude Code edition's agents take over these names.
            $claudePlugins = Join-Path (Join-Path (Join-Path $HOME '.claude') 'plugins') 'installed_plugins.json'
            if ((Test-Path -LiteralPath $claudePlugins) -and (Select-String -LiteralPath $claudePlugins -Pattern '"team-avatar@' -SimpleMatch -Quiet)) {
                Write-Host 'The Claude Code edition of Team Avatar is installed too. Cursor loads Claude Code' -ForegroundColor Yellow
                Write-Host "  plugins, and that edition's agents take over the same names, so these agents don't run." -ForegroundColor Yellow
                Write-Host '  To use this edition in Cursor, turn off Include Third-Party Plugins, Skills, and Other' -ForegroundColor Yellow
                Write-Host '  Configs in Cursor Settings, or uninstall one edition.' -ForegroundColor Yellow
                Write-Host ''
            }
        }
    }
    finally {
        if (Test-Path $workDir) {
            Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Main
