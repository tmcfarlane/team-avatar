#Requires -Version 5.1
<#
.SYNOPSIS
    Behavior tests for install.ps1. Runs the installer in a child PowerShell with HOME pointed at a throwaway folder.

.PARAMETER LegacyRepo
    A checkout of the v0.4.2 tag, the last release that wrote the old ~/.cursor layout. Needed for the migration test.
    Make it with: git archive v0.4.2 | tar -x -C <dir>

.EXAMPLE
    docker run --rm -v "$PWD:/repo:ro" -v /path/to/v0.4.2-checkout:/legacy:ro -e TA_LEGACY_REPO=/legacy `
        -w /repo mcr.microsoft.com/powershell:latest pwsh -NoProfile -File scripts/test-install-ps1.ps1
    On Apple Silicon, use mcr.microsoft.com/powershell:7.5-azurelinux-3.0-arm64. The latest tag has no arm64 build.
#>
[CmdletBinding()]
param(
    [string]$LegacyRepo = $env:TA_LEGACY_REPO
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$Installer = Join-Path $RepoRoot 'install.ps1'
$PwshExe = (Get-Process -Id $PID).Path
$IsUnix = [IO.Path]::DirectorySeparatorChar -eq '/'
$Sandbox = Join-Path ([IO.Path]::GetTempPath()) "ta-install-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $Sandbox | Out-Null

$script:Passed = 0
$script:Failed = 0

$env:OH_MY_CURSOR_SOURCE_BASE_URL = 'http://127.0.0.1:9'

if ($IsUnix -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    $stubBin = Join-Path $Sandbox 'stubbin'
    New-Item -ItemType Directory -Path $stubBin | Out-Null
    [IO.File]::WriteAllText((Join-Path $stubBin 'git'), "#!/bin/sh`nexit 1`n")
    & chmod +x (Join-Path $stubBin 'git')
    $env:PATH = "${stubBin}:$($env:PATH)"
}

$AGENTS = @('aang', 'sokka', 'katara', 'zuko', 'toph', 'appa', 'momo', 'iroh')
$COMMANDS = @('plan', 'build', 'search', 'fix', 'tasks', 'scout', 'cactus-juice', 'doc', 'image')
$HOOKS = @('guard-shell.sh', 'post-edit-lint.sh', 'pre-commit-check.sh')

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  ${Name}"
    }
    else {
        $script:Failed++
        Write-Host "  FAIL  ${Name}  ${Detail}" -ForegroundColor Red
    }
}

function New-TempDir {
    param([string]$Label)
    $dir = Join-Path $Sandbox "${Label}-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}

function Invoke-Installer {
    param(
        [string]$Script,
        [string]$HomeDir,
        [string]$Cwd,
        [string[]]$Arguments = @()
    )
    $env:HOME = $HomeDir
    $env:USERPROFILE = $HomeDir
    Push-Location $Cwd
    try {
        $output = (& $PwshExe -NoProfile -File $Script @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    return [pscustomobject]@{ Output = $output; Code = $code }
}

function Get-Tree {
    param([string]$Root)
    if (-not (Test-Path $Root)) { return @() }
    $rootFull = (Resolve-Path $Root).Path
    return @(Get-ChildItem $Root -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            "${rel}|$((Get-FileHash $_.FullName).Hash)"
        } | Sort-Object)
}

function Get-DescriptionBlock {
    param([string]$SkillDir)
    $block = @()
    foreach ($line in (Get-Content -LiteralPath (Join-Path $SkillDir 'SKILL.md'))) {
        if ($block.Count -eq 0) { if ($line -match '^description:') { $block += $line.TrimEnd() } }
        elseif ($line -match '^[ \t]') { $block += $line.TrimEnd() }
        else { break }
    }
    return ($block -join "`n")
}

function Get-BackupDirs {
    param([string]$HomeDir)
    $cursor = Join-Path $HomeDir '.cursor'
    if (-not (Test-Path $cursor)) { return @() }
    return @(Get-ChildItem $cursor -Directory -Filter 'team-avatar-backup-*')
}

# ---------------------------------------------------------------------------
Write-Host '1. Fresh user-scope install builds the plugin folder'
$home1 = New-TempDir 'home'
$cwd1 = New-TempDir 'cwd'
$r = Invoke-Installer -Script $Installer -HomeDir $home1 -Cwd $cwd1
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
$plugin = Join-Path $home1 '.cursor/plugins/local/team-avatar'
$expected = @('.cursor-plugin/plugin.json', 'rules/orchestrator.mdc', 'agents/protocols/team-avatar.md', 'hooks/hooks.json')
$expected += $AGENTS | ForEach-Object { "agents/${_}.md" }
$expected += $COMMANDS | ForEach-Object { "commands/${_}.md" }
$expected += $HOOKS | ForEach-Object { "hooks/${_}" }
$missing = @($expected | Where-Object { -not (Test-Path (Join-Path $plugin $_)) })
Assert-That 'every spec file is present' ($missing.Count -eq 0) ($missing -join ', ')
$tree = Get-Tree $plugin
$nonSkill = @($tree | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { -not $_.StartsWith('skills/') })
$unexpected = @($nonSkill | Where-Object { $expected -notcontains $_ })
Assert-That 'no files beyond the spec layout outside skills/' ($unexpected.Count -eq 0) ($unexpected -join ', ')
$repoSkills = @(Get-ChildItem (Join-Path $RepoRoot 'skills') -Directory | ForEach-Object Name | Sort-Object) -join ','
$pluginSkills = @(Get-ChildItem (Join-Path $plugin 'skills') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object) -join ','
Assert-That 'every bundled skill folder is installed' ($pluginSkills -eq $repoSkills) "got ${pluginSkills}"
Assert-That 'root hooks.json is not in the plugin' (-not (Test-Path (Join-Path $plugin 'hooks.json')))
Assert-That 'root permissions.json is not in the plugin' (-not (Test-Path (Join-Path $plugin 'permissions.json')))
$manifest = $null
try { $manifest = Get-Content (Join-Path $plugin '.cursor-plugin/plugin.json') -Raw | ConvertFrom-Json } catch { }
Assert-That 'plugin.json is valid JSON named team-avatar' ($null -ne $manifest -and $manifest.name -eq 'team-avatar')
$hooksJson = $null
try { $hooksJson = Get-Content (Join-Path $plugin 'hooks/hooks.json') -Raw | ConvertFrom-Json } catch { }
Assert-That 'hooks/hooks.json is valid JSON' ($null -ne $hooksJson)
Assert-That 'permissions.json went to ~/.cursor' (Test-Path (Join-Path $home1 '.cursor/permissions.json'))
foreach ($dir in 'agents', 'rules', 'commands', 'hooks', 'skills') {
    Assert-That "nothing written straight into ~/.cursor/${dir}" (-not (Test-Path (Join-Path $home1 ".cursor/${dir}")))
}
Assert-That 'no backup folder on a clean home' (@(Get-BackupDirs $home1).Count -eq 0)
Assert-That 'prints the restart and Customize hint' ($r.Output -match 'Reload Window' -and $r.Output -match 'Customize')
Assert-That 'prints the 0.5.0 version and the 3.27 label' ($r.Output -match '0\.5\.0' -and $r.Output -match 'Cursor 3\.27\+')
if ($IsUnix) {
    $notExec = @($HOOKS | Where-Object { & test -x (Join-Path $plugin "hooks/$_"); $LASTEXITCODE -ne 0 })
    Assert-That 'hook scripts are executable' ($notExec.Count -eq 0) ($notExec -join ', ')
}

Write-Host '1b. An existing different permissions.json is left alone'
$home1b = New-TempDir 'home'
Write-TextFile (Join-Path $home1b '.cursor/permissions.json') '{"mine":true}'
$r = Invoke-Installer -Script $Installer -HomeDir $home1b -Cwd $cwd1
Assert-That 'permissions.json content kept' ((Get-Content (Join-Path $home1b '.cursor/permissions.json') -Raw) -eq '{"mine":true}')
Assert-That 'prints one line saying so' ($r.Output -match 'exists and differs')

Write-Host '1c. The Claude Code edition is installed too'
Assert-That 'a plain install says nothing about the Claude Code edition' ($r.Output -notmatch 'Claude Code edition')
$home1d = New-TempDir 'home'
Write-TextFile (Join-Path $home1d '.claude/plugins/installed_plugins.json') '{"version": 2, "plugins": {"team-avatar@team-avatar": [{"scope": "user"}]}}'
$r = Invoke-Installer -Script $Installer -HomeDir $home1d -Cwd $cwd1
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'the installer warns about the Claude Code edition' ($r.Output -match 'Claude Code edition of Team Avatar is installed')
Assert-That 'the warning names the Cursor setting' ($r.Output -match 'Include Third-Party Plugins')

Write-Host '1d. A skill with a bundled name in ~/.agents/skills'
$home1c = New-TempDir 'home'
Write-TextFile (Join-Path $home1c '.agents/skills/planning/SKILL.md') "---`nname: planning`ndescription: my planning notes`n---`n"
$r = Invoke-Installer -Script $Installer -HomeDir $home1c -Cwd $cwd1
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'the note names the duplicate skill' ($r.Output -match 'bundled names: planning')
Assert-That 'the installer never suggests deleting a folder' ($r.Output -notmatch 'delete')
Assert-That '~/.agents/skills is untouched' (Test-Path (Join-Path $home1c '.agents/skills/planning/SKILL.md'))

# ---------------------------------------------------------------------------
Write-Host '2. Migration from the old installer layout'
if (-not $LegacyRepo -or -not (Test-Path (Join-Path $LegacyRepo 'install.ps1'))) {
    Assert-That 'legacy checkout available (set -LegacyRepo or TA_LEGACY_REPO)' $false "got '${LegacyRepo}'"
}
else {
    $home2 = New-TempDir 'home'
    $r = Invoke-Installer -Script (Join-Path $LegacyRepo 'install.ps1') -HomeDir $home2 -Cwd $cwd1
    Assert-That 'v0.4.2 installer exits 0' ($r.Code -eq 0) $r.Output
    $cursor2 = Join-Path $home2 '.cursor'
    $oldAgents = @(Get-ChildItem (Join-Path $cursor2 'agents') -Filter '*.md' -File)
    Assert-That 'old layout has agents in ~/.cursor/agents' ($oldAgents.Count -eq 8)
    $oldCommands = @(Get-ChildItem (Join-Path $cursor2 'commands') -Filter '*.md' -File)
    $oldSkills = @(Get-ChildItem (Join-Path $cursor2 'skills') -Directory)
    $oldHash = @{}
    foreach ($f in (Get-ChildItem $cursor2 -Recurse -File)) { $oldHash[$f.FullName.Substring($cursor2.Length).TrimStart('\', '/').Replace('\', '/')] = (Get-FileHash $f.FullName).Hash }
    $expectMoved = @{}
    foreach ($skill in $oldSkills) {
        $src = Join-Path $RepoRoot "skills/$($skill.Name)"
        $expectMoved[$skill.Name] = (Test-Path (Join-Path $src 'SKILL.md')) -and ((Get-DescriptionBlock $src) -ceq (Get-DescriptionBlock $skill.FullName))
    }
    Write-TextFile (Join-Path $cursor2 'agents/custom.md') "---`nname: custom`n---`n"
    Write-TextFile (Join-Path $cursor2 'commands/mine.md') "my own command`n"
    Write-TextFile (Join-Path $cursor2 'skills/MANIFEST') "architect/SKILL.md`n"

    $r = Invoke-Installer -Script $Installer -HomeDir $home2 -Cwd $cwd1
    Assert-That 'new installer exits 0' ($r.Code -eq 0) $r.Output
    $backups = @(Get-BackupDirs $home2)
    Assert-That 'exactly one backup folder' ($backups.Count -eq 1)
    $backup = $backups[0].FullName
    Assert-That 'every old agent is in the backup, none left in ~/.cursor/agents' (@($AGENTS | Where-Object { (Test-Path (Join-Path $backup "agents/$_.md")) -and -not (Test-Path (Join-Path $cursor2 "agents/$_.md")) }).Count -eq 8)
    Assert-That 'old protocol and rule are in the backup' ((Test-Path (Join-Path $backup 'agents/protocols/team-avatar.md')) -and (Test-Path (Join-Path $backup 'rules/orchestrator.mdc')))
    Assert-That 'old rule is gone from ~/.cursor/rules' (-not (Test-Path (Join-Path $cursor2 'rules/orchestrator.mdc')))
    Assert-That 'old hook scripts are in the backup' (@($HOOKS | Where-Object { Test-Path (Join-Path $backup "hooks/$_") }).Count -eq 3)
    Assert-That 'cactus-juice.md (no character name) is in the backup' ((Test-Path (Join-Path $backup 'commands/cactus-juice.md')) -and -not (Test-Path (Join-Path $cursor2 'commands/cactus-juice.md')))
    Assert-That 'backup keeps the old bytes' ((Get-FileHash (Join-Path $backup 'agents/aang.md')).Hash -eq $oldHash['agents/aang.md'])
    Assert-That 'user agent custom.md stays' (Test-Path (Join-Path $cursor2 'agents/custom.md'))
    Assert-That 'user command mine.md stays' (Test-Path (Join-Path $cursor2 'commands/mine.md'))
    Assert-That 'skills/MANIFEST is in the backup' ((Test-Path (Join-Path $backup 'skills/MANIFEST')) -and -not (Test-Path (Join-Path $cursor2 'skills/MANIFEST')))
    Assert-That 'prints each moved path' ($r.Output -match '\[moved\] agents/aang\.md')
    $pluginAgents = @($AGENTS | Where-Object { Test-Path (Join-Path $cursor2 "plugins/local/team-avatar/agents/$_.md") })
    Assert-That 'plugin is installed' ($pluginAgents.Count -eq 8 -and (Test-Path (Join-Path $cursor2 'plugins/local/team-avatar/.cursor-plugin/plugin.json')))
    $badSkills = @()
    foreach ($skill in $oldSkills) {
        $inBackup = Test-Path (Join-Path $backup "skills/$($skill.Name)")
        $inPlace = Test-Path (Join-Path $cursor2 "skills/$($skill.Name)")
        if ($inBackup -ne $expectMoved[$skill.Name] -or $inPlace -eq $inBackup) { $badSkills += $skill.Name }
    }
    Assert-That 'an old skill moves exactly when its description line matches the bundled one' ($badSkills.Count -eq 0) ($badSkills -join ', ')
    Assert-That 'at least one old skill matched and moved' (@($expectMoved.Values | Where-Object { $_ }).Count -ge 1)

    Write-Host '2b. Dry run moves nothing'
    $home2b = New-TempDir 'home'
    $null = Invoke-Installer -Script (Join-Path $LegacyRepo 'install.ps1') -HomeDir $home2b -Cwd $cwd1
    $before = Get-Tree (Join-Path $home2b '.cursor')
    $r = Invoke-Installer -Script $Installer -HomeDir $home2b -Cwd $cwd1 -Arguments @('-DryRun')
    $after = Get-Tree (Join-Path $home2b '.cursor')
    Assert-That 'tree unchanged' (($before -join "`n") -eq ($after -join "`n"))
    Assert-That 'prints what would move' ($r.Output -match '\[would move\] agents/aang\.md')

    Write-Host '3b. Uninstall also moves the old layout aside'
    $r = Invoke-Installer -Script $Installer -HomeDir $home2b -Cwd $cwd1 -Arguments @('-Uninstall')
    Assert-That 'uninstall exits 0' ($r.Code -eq 0) $r.Output
    Assert-That 'old agents are in a backup folder' (@(Get-BackupDirs $home2b).Count -eq 1 -and (Test-Path (Join-Path (@(Get-BackupDirs $home2b)[0].FullName) 'agents/aang.md')))
    Assert-That 'nothing left in ~/.cursor/agents' (-not (Test-Path (Join-Path $home2b '.cursor/agents/aang.md')))
}

# ---------------------------------------------------------------------------
Write-Host '2c. Backup rules on hand-made files'
$home3 = New-TempDir 'home'
$cursor3 = Join-Path $home3 '.cursor'
Write-TextFile (Join-Path $cursor3 'agents/aang.md') "---`nname: aang`ndescription: x`n---`n"
Write-TextFile (Join-Path $cursor3 'agents/sokka.md') "---`nname: sokka is planning things`n---`n"
Write-TextFile (Join-Path $cursor3 'agents/katara.md') "---`nname: katarax`n---`n"
Write-TextFile (Join-Path $cursor3 'agents/zuko.md') "---`nname: zuko-custom`n---`n"
Write-TextFile (Join-Path $cursor3 'agents/toph.md') "---`nname: toph`n"
Write-TextFile (Join-Path $cursor3 'commands/plan.md') "Plan with Sokka`n"
Write-TextFile (Join-Path $cursor3 'commands/doc.md') "Write the docs with IROH`n"
Write-TextFile (Join-Path $cursor3 'commands/cactus-juice.md') "CACTUS JUICE MODE`n"
Write-TextFile (Join-Path $cursor3 'commands/build.md') "Build the thing`n"
Write-TextFile (Join-Path $cursor3 'agents/appa.md') "---`nname: appa - Executes Plans`n---`n"
Write-TextFile (Join-Path $cursor3 'commands/fix.md') "Fix it. Apparently this works.`n"
Write-TextFile (Join-Path $cursor3 'hooks/guard-shell.sh') "#!/bin/sh`n# my own guard hook`n"
Write-TextFile (Join-Path $cursor3 'hooks/pre-commit-check.sh') "#!/usr/bin/env bash`n# Pre-commit hook: enforce hard constraints before any commit.`n"
Write-TextFile (Join-Path $cursor3 'skills/vercel-composition-patterns/SKILL.md') "---`nname: vercel-composition-patterns`ndescription:`n  My own notes on composition.`n---`n"
Write-TextFile (Join-Path $cursor3 'rules/orchestrator.mdc') "---`nalwaysApply: true`n---`nmy own rule`n"
$srcArchitect = Join-Path $RepoRoot 'skills/architect'
$srcDebugging = Join-Path $RepoRoot 'skills/debugging'
Write-TextFile (Join-Path $cursor3 'skills/architect/SKILL.md') ("---`nname: architect`n$(Get-DescriptionBlock $srcArchitect)`n---`nold body`n")
Write-TextFile (Join-Path $cursor3 'skills/debugging/SKILL.md') "---`nname: debugging`ndescription: my own debugging notes`n---`n"
Write-TextFile (Join-Path $cursor3 'skills/planning/notes.txt') "no SKILL.md here`n"
$r = Invoke-Installer -Script $Installer -HomeDir $home3 -Cwd $cwd1
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
$b3 = @(Get-BackupDirs $home3)[0].FullName
Assert-That 'agent with exact "name: aang" moves' ((Test-Path (Join-Path $b3 'agents/aang.md')) -and -not (Test-Path (Join-Path $cursor3 'agents/aang.md')))
Assert-That 'agent with "name: sokka is ..." moves' (Test-Path (Join-Path $b3 'agents/sokka.md'))
Assert-That 'agent "name: katarax" stays' ((Test-Path (Join-Path $cursor3 'agents/katara.md')) -and -not (Test-Path (Join-Path $b3 'agents/katara.md')))
Assert-That 'agent "name: zuko-custom" stays' ((Test-Path (Join-Path $cursor3 'agents/zuko.md')) -and -not (Test-Path (Join-Path $b3 'agents/zuko.md')))
Assert-That 'command that names a character moves (any case)' ((Test-Path (Join-Path $b3 'commands/plan.md')) -and (Test-Path (Join-Path $b3 'commands/doc.md')))
Assert-That 'command that says "cactus juice" moves' (Test-Path (Join-Path $b3 'commands/cactus-juice.md'))
Assert-That 'command with no character or cactus juice stays' ((Test-Path (Join-Path $cursor3 'commands/build.md')) -and -not (Test-Path (Join-Path $b3 'commands/build.md')))
Assert-That 'rule without "Team Avatar orchestration" stays' ((Test-Path (Join-Path $cursor3 'rules/orchestrator.mdc')) -and -not (Test-Path (Join-Path $b3 'rules/orchestrator.mdc')))
Assert-That 'skill with the same description line moves' ((Test-Path (Join-Path $b3 'skills/architect/SKILL.md')) -and -not (Test-Path (Join-Path $cursor3 'skills/architect')))
Assert-That 'skill with a different description stays and says so' ((Test-Path (Join-Path $cursor3 'skills/debugging/SKILL.md')) -and $r.Output -match '\[left\] skills/debugging')
Assert-That 'skill folder without SKILL.md stays' (Test-Path (Join-Path $cursor3 'skills/planning/notes.txt'))
Assert-That 'agent with "name: appa - ..." moves' (Test-Path (Join-Path $b3 'agents/appa.md'))
Assert-That 'command that only says "apparently" stays' ((Test-Path (Join-Path $cursor3 'commands/fix.md')) -and -not (Test-Path (Join-Path $b3 'commands/fix.md')))
Assert-That 'hook script with its own second line stays' ((Test-Path (Join-Path $cursor3 'hooks/guard-shell.sh')) -and -not (Test-Path (Join-Path $b3 'hooks/guard-shell.sh')))
Assert-That 'hook script with a shipped second line moves' ((Test-Path (Join-Path $b3 'hooks/pre-commit-check.sh')) -and -not (Test-Path (Join-Path $cursor3 'hooks/pre-commit-check.sh')))
Assert-That 'same-named skill with its own multi-line description stays' ((Test-Path (Join-Path $cursor3 'skills/vercel-composition-patterns/SKILL.md')) -and -not (Test-Path (Join-Path $b3 'skills/vercel-composition-patterns')))

Write-Host '2d. -NoSkills leaves every old skill folder'
$home4 = New-TempDir 'home'
Write-TextFile (Join-Path $home4 '.cursor/skills/architect/SKILL.md') ("---`nname: architect`n$(Get-DescriptionBlock $srcArchitect)`n---`n")
$r = Invoke-Installer -Script $Installer -HomeDir $home4 -Cwd $cwd1 -Arguments @('-NoSkills')
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'old skill stays and says so' ((Test-Path (Join-Path $home4 '.cursor/skills/architect/SKILL.md')) -and $r.Output -match '\[left\] skills/architect')
Assert-That 'plugin has no skills folder' (-not (Test-Path (Join-Path $home4 '.cursor/plugins/local/team-avatar/skills')))

Write-Host '2e. A user hooks.json keeps the old hook scripts in place'
$home2e = New-TempDir 'home'
Write-TextFile (Join-Path $home2e '.cursor/hooks.json') '{"version": 1, "hooks": {}}'
Write-TextFile (Join-Path $home2e '.cursor/hooks/pre-commit-check.sh') "#!/usr/bin/env bash`n# Pre-commit hook: enforce hard constraints before any commit.`n"
$r = Invoke-Installer -Script $Installer -HomeDir $home2e -Cwd $cwd1
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'old hook script stays' (Test-Path (Join-Path $home2e '.cursor/hooks/pre-commit-check.sh'))

# ---------------------------------------------------------------------------
Write-Host '3. Uninstall removes the plugin folder'
$r = Invoke-Installer -Script $Installer -HomeDir $home1 -Cwd $cwd1 -Arguments @('-Uninstall')
Assert-That 'uninstall exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'plugin folder is gone' (-not (Test-Path $plugin))
Assert-That "user's permissions.json is kept" (Test-Path (Join-Path $home1 '.cursor/permissions.json'))

Write-Host '3c. Offline uninstall from a lone copy still removes the plugin'
$home3c = New-TempDir 'home'
$null = Invoke-Installer -Script $Installer -HomeDir $home3c -Cwd $cwd1
New-Item -ItemType Directory -Path (Join-Path $home3c '.cursor/skills') -Force | Out-Null
Copy-Item (Join-Path $RepoRoot 'skills/planning') (Join-Path $home3c '.cursor/skills/planning') -Recurse
$lone = New-TempDir 'lone'
Copy-Item $Installer (Join-Path $lone 'install.ps1')
$r = Invoke-Installer -Script (Join-Path $lone 'install.ps1') -HomeDir $home3c -Cwd $cwd1 -Arguments @('-Uninstall')
Assert-That 'offline uninstall exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'offline uninstall removed the plugin' (-not (Test-Path (Join-Path $home3c '.cursor/plugins/local/team-avatar')))
Assert-That 'offline uninstall left the old skill in place' (Test-Path (Join-Path $home3c '.cursor/skills/planning/SKILL.md'))
Assert-That 'offline uninstall says why' ($r.Output -match 'Could not read the bundled skills')

# ---------------------------------------------------------------------------
Write-Host '4. Disable then enable toggles the rule inside the plugin folder'
$home5 = New-TempDir 'home'
$null = Invoke-Installer -Script $Installer -HomeDir $home5 -Cwd $cwd1
$rules5 = Join-Path $home5 '.cursor/plugins/local/team-avatar/rules'
$r = Invoke-Installer -Script $Installer -HomeDir $home5 -Cwd $cwd1 -Arguments @('-Disable')
Assert-That 'disable exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'rule renamed to .disabled' ((Test-Path (Join-Path $rules5 'orchestrator.mdc.disabled')) -and -not (Test-Path (Join-Path $rules5 'orchestrator.mdc')))
$r = Invoke-Installer -Script $Installer -HomeDir $home5 -Cwd $cwd1 -Arguments @('-Enable')
Assert-That 'enable exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'rule restored' ((Test-Path (Join-Path $rules5 'orchestrator.mdc')) -and -not (Test-Path (Join-Path $rules5 'orchestrator.mdc.disabled')))
Assert-That 'nothing created in ~/.cursor/rules' (-not (Test-Path (Join-Path $home5 '.cursor/rules')))

# ---------------------------------------------------------------------------
Write-Host '5. Project scope keeps the .cursor/ layout'
$home6 = New-TempDir 'home'
$proj = New-TempDir 'project'
$r = Invoke-Installer -Script $Installer -HomeDir $home6 -Cwd $proj -Arguments @('-Scope', 'project')
Assert-That 'installer exits 0' ($r.Code -eq 0) $r.Output
$pc = Join-Path $proj '.cursor'
# On Windows the installer leaves .cursor/hooks.json out, because Cursor runs hooks through PowerShell there.
$projExpected = @('rules/orchestrator.mdc', 'agents/protocols/team-avatar.md', 'permissions.json')
if ($IsUnix) { $projExpected += 'hooks.json' }
$projExpected += $AGENTS | ForEach-Object { "agents/${_}.md" }
$projExpected += $COMMANDS | ForEach-Object { "commands/${_}.md" }
$projExpected += $HOOKS | ForEach-Object { "hooks/${_}" }
$projMissing = @($projExpected | Where-Object { -not (Test-Path (Join-Path $pc $_)) })
Assert-That 'project layout files present' ($projMissing.Count -eq 0) ($projMissing -join ', ')
if ($IsUnix) {
    Assert-That '.cursor/hooks.json uses .cursor/hooks/ paths' ((Get-Content (Join-Path $pc 'hooks.json') -Raw) -match '\.cursor/hooks/guard-shell\.sh')
}
else {
    Assert-That 'no .cursor/hooks.json on Windows' (-not (Test-Path (Join-Path $pc 'hooks.json')))
}
Assert-That 'no hooks/hooks.json copied into .cursor/hooks' (-not (Test-Path (Join-Path $pc 'hooks/hooks.json')))
Assert-That 'no plugin manifest in the project' (-not (Test-Path (Join-Path $pc '.cursor-plugin')) -and -not (Test-Path (Join-Path $pc 'plugins')))
Assert-That 'nothing written under the home' (-not (Test-Path (Join-Path $home6 '.cursor')))

# ---------------------------------------------------------------------------
Write-Host '6. Running twice gives the same tree'
$home7 = New-TempDir 'home'
$null = Invoke-Installer -Script $Installer -HomeDir $home7 -Cwd $cwd1
$first = Get-Tree (Join-Path $home7 '.cursor')
$r = Invoke-Installer -Script $Installer -HomeDir $home7 -Cwd $cwd1
$second = Get-Tree (Join-Path $home7 '.cursor')
Assert-That 'second run exits 0' ($r.Code -eq 0) $r.Output
Assert-That 'tree is identical after the second run' (($first -join "`n") -eq ($second -join "`n"))
Assert-That 'second run creates no backup folder' (@(Get-BackupDirs $home7).Count -eq 0)
$pluginFile = Join-Path $home7 '.cursor/plugins/local/team-avatar/agents/aang.md'
[IO.File]::AppendAllText($pluginFile, "local edit`n")
$r = Invoke-Installer -Script $Installer -HomeDir $home7 -Cwd $cwd1
Assert-That 'without -Force a changed plugin file is kept' ((Get-Content $pluginFile -Raw) -match 'local edit')
$r = Invoke-Installer -Script $Installer -HomeDir $home7 -Cwd $cwd1 -Arguments @('-Force')
Assert-That '-Force overwrites it' ((Get-Content $pluginFile -Raw) -notmatch 'local edit')
Assert-That 'tree matches the first install again' ((Get-Tree (Join-Path $home7 '.cursor')) -join "`n" -eq ($first -join "`n"))

# ---------------------------------------------------------------------------
Write-Host '7. Remote mode builds the same tree from a lone install.ps1'
$port = Get-Random -Minimum 20000 -Maximum 60000
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:${port}/")
$listener.Start()
$server = [powershell]::Create()
$null = $server.AddScript({
        param($Listener, $Root)
        while ($Listener.IsListening) {
            try { $ctx = $Listener.GetContext() } catch { break }
            $file = Join-Path $Root ([Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/')))
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $bytes = [IO.File]::ReadAllBytes($file)
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            else { $ctx.Response.StatusCode = 404 }
            $ctx.Response.Close()
        }
    }).AddArgument($listener).AddArgument($RepoRoot)
$null = $server.BeginInvoke()
try {
    $home8 = New-TempDir 'home'
    $lone8 = New-TempDir 'lone'
    Copy-Item $Installer (Join-Path $lone8 'install.ps1')
    $env:OH_MY_CURSOR_SOURCE_BASE_URL = "http://localhost:${port}"
    $r = Invoke-Installer -Script (Join-Path $lone8 'install.ps1') -HomeDir $home8 -Cwd $cwd1
    Assert-That 'remote install exits 0' ($r.Code -eq 0) $r.Output
    Assert-That 'remote install builds the same tree as a local install' (((Get-Tree (Join-Path $home8 '.cursor')) -join "`n") -eq ($first -join "`n"))
}
finally {
    $env:OH_MY_CURSOR_SOURCE_BASE_URL = 'http://127.0.0.1:9'
    $listener.Stop()
    $server.Dispose()
}

# ---------------------------------------------------------------------------
Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Passed: $script:Passed  Failed: $script:Failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
