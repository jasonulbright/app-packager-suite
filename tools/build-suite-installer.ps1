<#
.SYNOPSIS
    Builds the AppPackager Suite all-in-one NSIS installer.

.DESCRIPTION
    Stages the payload from the local sibling repositories at their current
    HEAD via git archive, writes suite-manifest.json describing the suite and
    each component, generates components.nsh in the staging folder from the
    same component table, compiles installer\suite.nsi with makensis, and
    emits SuiteSetup-<version>.exe plus checksums.txt into installer\out.

    Adding a component is one row in $Components: staging, the manifest, the
    payload File blocks and the start-menu shortcuts all read that row.

    Test files are stripped from the payload: nothing under a Tests folder and
    no *.Tests.ps1 file reaches a shipped artifact. Each component's
    RELEASING.md is stripped too, and so are the root-level docs and
    screenshots folders, screenshot.png, .github, .coderabbit.yaml and
    Invoke-Checks.ps1.

.PARAMETER SuiteVersion
    Suite version stamped into the installer, the manifest and the file name.
    Defaults to the build date as yyyy.MM.dd.

.PARAMETER MakeNsis
    Path to makensis.exe.

.PARAMETER KeepStage
    Leave the staging folder in place for inspection.

.PARAMETER StageRoot
    Staging folder. Defaults to a new folder under the temp path. A folder
    inside a component checkout shows as untracked files and fails that
    checkout's clean-tree check.

.PARAMETER SkipReleaseCheck
    Skip the two remote checks (tag on origin, GitHub release) for every
    component; the local checks (clean tree, HEAD at the highest v* tag,
    tag version equals payload version) still run.

.PARAMETER AllowUnpublished
    Component repositories whose release this build is part of. Their
    remote checks are waived because the tag and release land after the
    installer is built and verified.

.PARAMETER ValidateOnly
    Stage and check every component, then stop before compiling.
#>
[CmdletBinding()]
param(
    [string]$SuiteVersion,
    [string]$MakeNsis = 'C:\Program Files (x86)\NSIS\makensis.exe',
    [switch]$KeepStage,
    [string]$StageRoot,
    # Skips the remote checks (tag on origin, GitHub release) for an offline build.
    [switch]$SkipReleaseCheck,
    # Component repositories whose release this very build is part of: the
    # remote checks are waived for them alone, since tag and release land after
    # the installer is built and verified.
    [string[]]$AllowUnpublished = @(),
    # Runs the component checks and stops before compiling.
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$InstallerDir = Join-Path $RepoRoot 'installer'
$OutDir       = Join-Path $InstallerDir 'out'
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path ([IO.Path]::GetTempPath()) ('suite-stage-' + [Guid]::NewGuid().ToString('N'))
}
$NsiPath      = Join-Path $InstallerDir 'suite.nsi'
$SiblingRoot  = Split-Path -Parent $RepoRoot

# One row per shipped component. Folder is both the payload subfolder and the
# install-root subfolder. VersionSource selects the version reader; a header
# Version line trails the CHANGELOG in most tool repositories, so only the
# repositories whose header is maintained use ScriptHeader.
$Components = @(
    # Icon: a shipped .ico, relative to the component folder, for the Start Menu shortcut; omitted, the shortcut shows the PowerShell icon.
    [pscustomobject]@{ Folder = 'app-packager-suite'; Repo = 'app-packager-suite'; Entry = 'start-suite.ps1';                  Shortcut = 'AppPackager Suite Launcher';      VersionSource = 'ModuleManifest'; VersionFile = 'SuiteCommon\SuiteCommon.psd1'; Icon = 'assets\apppackager-suite.ico' }
    [pscustomobject]@{ Folder = 'app-packager'; Repo = 'app-packager'; Entry = 'start-apppackager.ps1';            Shortcut = 'App Packager';                    VersionSource = 'ScriptHeader';   VersionFile = '' }
    [pscustomobject]@{ Folder = 'site-hygiene'; Repo = 'site-hygiene'; Entry = 'start-sitehygiene.ps1';            Shortcut = 'Site Hygiene';                    VersionSource = 'Changelog';      VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'collection-and-compliance-manager'; Repo = 'collection-and-compliance-manager'; Entry = 'start-ccm.ps1';                  Shortcut = 'Collection and Compliance Manager'; VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'collection-manager';                Repo = 'collection-manager';                Entry = 'start-collectionmanager.ps1';    Shortcut = 'Collection Manager';                VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'deployment-helper';                Repo = 'deployment-helper';                 Entry = 'start-deploymenthelper.ps1';     Shortcut = 'Deployment Helper';                 VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'detection-tester';                 Repo = 'detection-tester';                  Entry = 'start-detectiontester.ps1';      Shortcut = 'Detection Method Tester';           VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'dp-content-manager';               Repo = 'dp-content-manager';                Entry = 'start-dpcontentmgr.ps1';         Shortcut = 'DP Content Manager';                VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'installer-analysis';               Repo = 'installer-analysis';                Entry = 'start-installeranalysis.ps1';    Shortcut = 'Installer Analysis';                VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'maintenance-window-manager';       Repo = 'maintenance-window-manager';        Entry = 'start-maintenancewindowmgr.ps1'; Shortcut = 'Maintenance Window Manager';        VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'pivots-and-scripts';               Repo = 'pivots-and-scripts';                Entry = 'start-pivotsandscripts.ps1';     Shortcut = 'Pivots and Scripts';                VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'update-planner';                   Repo = 'update-planner';                    Entry = 'start-updateplanner.ps1';        Shortcut = 'Update Planner';                    VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
    [pscustomobject]@{ Folder = 'device-inspector';                 Repo = 'device-inspector';                  Entry = 'start-deviceinspector.ps1';      Shortcut = 'Device Inspector';                  VersionSource = 'Changelog'; VersionFile = 'CHANGELOG.md' }
)

# Install-root subfolders that changed name. An upgrade moves the old folder,
# user state included, to the new name before the payload is written.
$FolderRenames = @(
    [pscustomobject]@{ From = 'suite-core'; To = 'app-packager-suite' }
)

# Components an earlier installer shipped that no longer exist. An upgrade runs
# installer\retire-component.ps1 for the old folder: it zips the folder to
# <MigrateTo>\legacy\<Folder>.zip (a time-stamped name when that exists, never an
# overwrite), checks the zip, and merges every file through
# merge-user-folder.ps1 into <MigrateTo>\legacy\<Folder>\. The folder is removed
# only when no file is left in it.
$RetiredComponents = @(
    [pscustomobject]@{ Folder = 'mecm-health-dashboard'; MigrateTo = 'site-hygiene' }
    [pscustomobject]@{ Folder = 'supersedence-auditor';  MigrateTo = 'site-hygiene' }
)

# Top-level folders of a component that hold default files a tool also writes
# to (a tool saves its own templates beside the shipped ones). The build moves
# their files out of the component payload into a defaults tree, and
# installer\suite-userdata.ps1 places them without overwriting an edited file.
$DefaultFolders = @('Templates')

# Folders under %LOCALAPPDATA% that suite tools use for user data outside the
# install root. Uninstall never removes them; it names the ones that exist.
$ExternalUserData = @('DetectionTester', 'SignalRidgeLabs\PivotsAndScripts', 'AppPackager', 'AppPackagerData')

# Start Menu shortcut names that changed or belong to a retired component.
# Setup and uninstall delete them; without this an upgrade leaves them.
$RetiredShortcuts = @(
    'MECM Health Dashboard'
    'ConfigMgr Health Dashboard'
    'Supersedence and Dependency Auditor'
)

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ('[build] ' + $Message)
}

function Get-ChangelogVersion {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path -TotalCount 40)) {
        if ($line -match '^##\s+\[?([0-9][0-9\.]*[0-9])\]?') { return $Matches[1] }
    }
    return $null
}

function Get-ManifestVersion {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match "ModuleVersion\s*=\s*'([^']+)'") { return $Matches[1] }
    }
    return $null
}

function Get-ScriptHeaderVersion {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path -TotalCount 80)) {
        if ($line -match '^\s*Version\s*:\s*([0-9][0-9\.]*[0-9])\s*$') { return $Matches[1] }
    }
    return $null
}

function Get-ComponentVersion {
    param(
        [Parameter(Mandatory)][object]$Component,
        [Parameter(Mandatory)][string]$StagedRoot
    )
    $version = switch ($Component.VersionSource) {
        'ScriptHeader'   { Get-ScriptHeaderVersion -Path (Join-Path $StagedRoot $Component.Entry) }
        'Changelog'      { Get-ChangelogVersion    -Path (Join-Path $StagedRoot $Component.VersionFile) }
        'ModuleManifest' { Get-ManifestVersion     -Path (Join-Path $StagedRoot $Component.VersionFile) }
        default          { throw ('Unknown version source: ' + $Component.VersionSource) }
    }

    # Drift guard: a Version header in the entry script that disagrees with
    # the version of record ships a wrong number inside the payload.
    $headerVersion = Get-ScriptHeaderVersion -Path (Join-Path $StagedRoot $Component.Entry)
    if ($headerVersion -and $version -and $headerVersion -ne $version) {
        Write-Warning ('{0}: entry header reads {1} but the version of record is {2}; fix the header before releasing.' -f $Component.Repo, $headerVersion, $version)
    }
    return $version
}

function Export-RepoHead {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
        throw ('Not a git repository: ' + $RepoPath)
    }
    $zip = Join-Path ([IO.Path]::GetTempPath()) ('suitestage-' + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        & git -C $RepoPath archive --format=zip -o $zip HEAD
        if ($LASTEXITCODE -ne 0) { throw ('git archive failed for ' + $RepoPath) }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
}

function Remove-TestArtifact {
    param([Parameter(Mandatory)][string]$Root)
    $removed = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -Filter 'Tests' -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $dir.FullName) {
            $removed += @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File).Count
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $file.FullName -Force
        $removed++
    }
    # The release procedure is a maintainer file; each component's own zip
    # excludes it, so the installer payload does too.
    $releasing = Join-Path $Root 'RELEASING.md'
    if (Test-Path -LiteralPath $releasing) {
        Remove-Item -LiteralPath $releasing -Force
        $removed++
    }
    # Documentation, screenshots and repository tooling stay in each
    # component's repository. The installer carries only what runs. Only the
    # component root is touched: a folder with the same name deeper in the
    # tree can be runtime content.
    foreach ($name in @('docs', 'screenshots', 'screenshot.png', '.github', '.coderabbit.yaml', 'Invoke-Checks.ps1')) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                $removed += @(Get-ChildItem -LiteralPath $path -Recurse -File -Force).Count
            }
            else { $removed++ }
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    return $removed
}

function Get-HeadCommit {
    param([Parameter(Mandatory)][string]$RepoPath)
    $sha = (& git -C $RepoPath rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw ('git rev-parse failed for ' + $RepoPath) }
    return $sha.Trim()
}

function Get-LatestReleaseTag {
    # Highest v-prefixed tag by version order; the installer may only carry
    # a component at a commit that has been released under such a tag.
    param([Parameter(Mandatory)][string]$RepoPath)
    $tags = @(& git -C $RepoPath tag --list 'v*' --sort=-v:refname)
    if ($LASTEXITCODE -ne 0) { throw ('git tag failed for ' + $RepoPath) }
    return ($tags | Where-Object { $_ -match '^v\d' } | Select-Object -First 1)
}

function Test-ComponentRelease {
    <#
    .SYNOPSIS
        Refuses a component whose checkout is not exactly its latest release.
    .DESCRIPTION
        Every component repository must be clean, checked out at its highest
        v* tag, and that tag's version must equal the version the payload
        carries. Unless -SkipReleaseCheck, the tag must also exist on origin
        and have a GitHub release. Any miss throws, so a bumped component
        that was never released, or a stale checkout of one that was, cannot
        ship inside the suite installer.
    #>
    param(
        [Parameter(Mandatory)][object]$Component,
        [Parameter(Mandatory)][string]$StagedVersion,
        [switch]$Offline
    )
    $repoPath = $Component.RepoPath
    $name = $Component.Repo

    $dirty = @(& git -C $repoPath status --porcelain)
    if ($dirty.Count -gt 0) {
        throw ('{0}: working tree has {1} uncommitted change(s); commit and release them or discard them before building the suite.' -f $name, $dirty.Count)
    }

    $tag = Get-LatestReleaseTag -RepoPath $repoPath
    if (-not $tag) { throw ('{0}: no v* release tag found.' -f $name) }
    $tagVersion = $tag.Substring(1)
    if ($tagVersion -ne $StagedVersion) {
        throw ('{0}: payload carries version {1} but the latest release tag is {2}; release the bump (or check out the tag) before building the suite.' -f $name, $StagedVersion, $tag)
    }

    $headSha = Get-HeadCommit -RepoPath $repoPath
    $tagSha = (& git -C $repoPath rev-list -n 1 $tag).Trim()
    if ($headSha -ne $tagSha) {
        $ahead = (& git -C $repoPath rev-list --count ($tag + '..HEAD')).Trim()
        throw ('{0}: HEAD ({1}) is not the {2} commit ({3}); {4} commit(s) past the tag would ship unreleased.' -f $name, $headSha.Substring(0, 7), $tag, $tagSha.Substring(0, 7), $ahead)
    }

    $releaseState = 'tag only (remote checks skipped)'
    if (-not $Offline) {
        $remoteTag = @(& git -C $repoPath ls-remote --tags origin ('refs/tags/' + $tag) 2>$null)
        if ($LASTEXITCODE -ne 0 -or $remoteTag.Count -eq 0) {
            throw ('{0}: tag {1} is not on origin; push it before building the suite.' -f $name, $tag)
        }
        $releaseState = 'tag on origin'
        $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
        if ($gh) {
            $remoteUrl = (& git -C $repoPath remote get-url origin).Trim()
            if ($remoteUrl -match 'github\.com[:/]([^/]+/[^/.]+)') {
                $null = & $gh.Source release view $tag --repo $Matches[1] --json tagName 2>$null
                if ($LASTEXITCODE -ne 0) {
                    throw ('{0}: tag {1} has no GitHub release on {2}; publish it before building the suite.' -f $name, $tag, $Matches[1])
                }
                $releaseState = 'GitHub release ' + $tag
            }
        }
    }
    return $releaseState
}

function Move-DefaultFolder {
    <#
    .SYNOPSIS
        Moves each component's default-file folders out of the component payload
        into <stage>\defaults\<component>\ and returns the number of files moved.
    #>
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][object[]]$Table,
        [Parameter(Mandatory)][string[]]$Folders
    )
    $moved = 0
    foreach ($c in $Table) {
        foreach ($f in $Folders) {
            $src = Join-Path (Join-Path $StageRoot $c.Folder) $f
            if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
            $moved += @(Get-ChildItem -LiteralPath $src -Recurse -File -Force).Count
            $destParent = Join-Path (Join-Path $StageRoot 'defaults') $c.Folder
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            Move-Item -LiteralPath $src -Destination (Join-Path $destParent $f)
        }
    }
    return $moved
}

# suite.nsi includes this file from the payload directory; it holds every
# per-component line so the .nsi itself never names a component.
function Write-ComponentsInclude {
    param(
        [Parameter(Mandatory)][object[]]$Table,
        [Parameter(Mandatory)][string]$Path,
        [object[]]$Renames = @(),
        [object[]]$Retired = @(),
        [string[]]$RetiredShortcuts = @(),
        [string[]]$ExternalData = @()
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('; Generated by tools\build-suite-installer.ps1. Do not edit.')
    $lines.Add('')
    # A directory rename keeps every user file. It fails while a file in the
    # old folder is loaded by a running tool, so the user closes it and retries.
    # When both folders exist, merge-user-folder.ps1 moves every file absent from
    # the new folder, keeps a differing old file under legacy\, and removes the
    # old folder only when no file is left in it.
    $lines.Add('!macro SUITE_MIGRATE_FOLDERS')
    $n = 0
    foreach ($r in $Renames) {
        $from = '$INSTDIR\' + $r.From
        $to = '$INSTDIR\' + $r.To
        $lines.Add('  IfFileExists "' + $from + '\*.*" 0 migrate_done_' + $n)
        $lines.Add('  IfFileExists "' + $to + '\*.*" migrate_merge_' + $n)
        $lines.Add('  migrate_rename_' + $n + ':')
        $lines.Add('  ClearErrors')
        $lines.Add('  Rename "' + $from + '" "' + $to + '"')
        $lines.Add('  IfErrors 0 migrate_done_' + $n)
        $lines.Add('  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Setup cannot move $\"' + $from + '$\". Close every ${SUITE_NAME} tool, then select Retry." /SD IDCANCEL IDRETRY migrate_rename_' + $n)
        $lines.Add('  Abort')
        $lines.Add('  migrate_merge_' + $n + ':')
        $lines.Add('  InitPluginsDir')
        $lines.Add('  File "/oname=$PLUGINSDIR\merge-user-folder.ps1" "${INSTALLERSRC}\merge-user-folder.ps1"')
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_MERGE_SRC", t "' + $from + '")' + "'")
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_MERGE_DST", t "' + $to + '")' + "'")
        $lines.Add('  DetailPrint "Merging ' + $r.From + ' into ' + $r.To + '"')
        $lines.Add('  nsExec::ExecToLog ' + "'" + '"$PSExe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\merge-user-folder.ps1"' + "'")
        $lines.Add('  Pop $0')
        $lines.Add('  StrCmp $0 0 migrate_done_' + $n)
        $lines.Add('  DetailPrint "Merge of ' + $r.From + ' stopped (exit $0); files that could not move stay in the old folder."')
        $lines.Add('  migrate_done_' + $n + ':')
        $n++
    }
    $lines.Add('!macroend')
    $lines.Add('')
    # The paths reach PowerShell through environment variables, so a quote
    # or an apostrophe in the install path never breaks the command line.
    # retire-component.ps1 zips the old folder to a name that is never an
    # existing file, checks the zip, and merges every file through
    # merge-user-folder.ps1 into <MigrateTo>\legacy\<Folder>. The old folder
    # goes only when no file is left in it. A failed archive (exit 3) or a
    # file that cannot move (exit 2) leaves the folder in place.
    $lines.Add('!macro SUITE_RETIRE_COMPONENTS')
    $n = 0
    foreach ($r in $Retired) {
        $old = '$INSTDIR\' + $r.Folder
        $legacyRoot = '$INSTDIR\' + $r.MigrateTo + '\legacy'
        $lines.Add('  IfFileExists "' + $old + '\*.*" 0 retire_done_' + $n)
        $lines.Add('  InitPluginsDir')
        $lines.Add('  File "/oname=$PLUGINSDIR\merge-user-folder.ps1" "${INSTALLERSRC}\merge-user-folder.ps1"')
        $lines.Add('  File "/oname=$PLUGINSDIR\retire-component.ps1" "${INSTALLERSRC}\retire-component.ps1"')
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_RETIRE_SRC", t "' + $old + '")' + "'")
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_RETIRE_LEGACY", t "' + $legacyRoot + '")' + "'")
        $lines.Add('  DetailPrint "Archiving and merging ' + $r.Folder + ' into ' + $legacyRoot + '"')
        $lines.Add('  nsExec::ExecToLog ' + "'" + '"$PSExe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\retire-component.ps1"' + "'")
        $lines.Add('  Pop $0')
        $lines.Add('  StrCmp $0 0 retire_done_' + $n)
        $lines.Add('  DetailPrint "Retire of ' + $r.Folder + ' stopped (exit $0); the folder, or the files that could not move, stay in place."')
        $lines.Add('  retire_done_' + $n + ':')
        $n++
    }
    $lines.Add('!macroend')
    $lines.Add('')
    $lines.Add('!macro SUITE_INSTALL_FILES')
    foreach ($c in $Table) {
        $lines.Add('  SetOutPath "$INSTDIR\' + $c.Folder + '"')
        $lines.Add('  File /r "${PAYLOADDIR}\' + $c.Folder + '\*.*"')
    }
    $lines.Add('!macroend')
    $lines.Add('')
    # Default files (templates) that a tool also writes to. The build moved them
    # out of the component payload into <stage>\defaults; suite-userdata.ps1
    # places them without overwriting an edited file and records what it shipped
    # in suite-defaults.json. The script also stays in the install root, so the
    # uninstaller can run it. Emitted only when the stage holds defaults.
    $stageRoot = Split-Path -Parent $Path
    $hasDefaults = (Test-Path -LiteralPath (Join-Path $stageRoot 'defaults') -PathType Container) -and
        (@(Get-ChildItem -LiteralPath (Join-Path $stageRoot 'defaults') -Recurse -File).Count -gt 0)
    $lines.Add('!macro SUITE_PLACE_DEFAULTS')
    if ($hasDefaults) {
        $lines.Add('  InitPluginsDir')
        $lines.Add('  SetOutPath "$INSTDIR"')
        $lines.Add('  File "${INSTALLERSRC}\suite-userdata.ps1"')
        $lines.Add('  File "/oname=$PLUGINSDIR\suite-userdata.ps1" "${INSTALLERSRC}\suite-userdata.ps1"')
        $lines.Add('  SetOutPath "$PLUGINSDIR\defaults"')
        $lines.Add('  File /r "${PAYLOADDIR}\defaults\*.*"')
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_UD_MODE", t "Place")' + "'")
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_UD_ROOT", t "$INSTDIR")' + "'")
        $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_UD_DEFAULTS", t "$PLUGINSDIR\defaults")' + "'")
        $lines.Add('  DetailPrint "Placing default templates (edited files are kept)"')
        $lines.Add('  nsExec::ExecToLog ' + "'" + '"$PSExe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\suite-userdata.ps1"' + "'")
        $lines.Add('  Pop $0')
        $lines.Add('  StrCmp $0 0 +2')
        $lines.Add('  DetailPrint "Placing default templates stopped (exit $0); files that could not be handled are left as they were."')
        $lines.Add('  SetOutPath "$INSTDIR"')
    }
    $lines.Add('!macroend')
    $lines.Add('')
    $lines.Add('!macro SUITE_CREATE_SHORTCUTS')
    foreach ($old in $RetiredShortcuts) {
        $lines.Add('  Delete "$StartMenuDir\' + $old + '.lnk"')
    }
    foreach ($c in $Table) {
        # SetOutPath fixes each shortcut's working directory at its own folder.
        $lines.Add('  SetOutPath "$INSTDIR\' + $c.Folder + '"')
        $icon = ''
        if ($c.PSObject.Properties['Icon'] -and -not [string]::IsNullOrWhiteSpace([string]$c.Icon)) {
            $icon = ' "$INSTDIR\' + $c.Folder + '\' + $c.Icon + '" 0'
        }
        $lines.Add('  CreateShortcut "$StartMenuDir\' + $c.Shortcut + '.lnk" "$PSExe" \')
        $lines.Add('    ' + "'" + '${PS_ARGS_PRE} "$INSTDIR\' + $c.Folder + '\' + $c.Entry + '"' + "'" + $icon)
    }
    $lines.Add('!macroend')
    $lines.Add('')
    $lines.Add('!macro SUITE_DELETE_SHORTCUTS')
    foreach ($old in $RetiredShortcuts) {
        $lines.Add('  Delete "$StartMenuDir\' + $old + '.lnk"')
    }
    foreach ($c in $Table) {
        $lines.Add('  Delete "$StartMenuDir\' + $c.Shortcut + '.lnk"')
    }
    $lines.Add('!macroend')
    $lines.Add('')
    # Uninstall deletes only the files this build shipped; user state written
    # after install stays, and each directory is removed only when empty.
    # Default files go through suite-userdata.ps1: an untouched file is deleted,
    # an edited one stays.
    $lines.Add('!macro SUITE_UNINSTALL_FILES')
    $lines.Add('  IfFileExists "$INSTDIR\suite-userdata.ps1" 0 uninstall_defaults_done')
    $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_UD_MODE", t "Remove")' + "'")
    $lines.Add('  System::Call ' + "'" + 'kernel32::SetEnvironmentVariable(t "SUITE_UD_ROOT", t "$INSTDIR")' + "'")
    $lines.Add('  nsExec::ExecToLog ' + "'" + '"$PSExe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\suite-userdata.ps1"' + "'")
    $lines.Add('  Pop $0')
    $lines.Add('  uninstall_defaults_done:')
    $lines.Add('  Delete "$INSTDIR\suite-userdata.ps1"')
    $stageDir = Split-Path -Parent $Path
    foreach ($c in $Table) {
        $componentRoot = Join-Path $stageDir $c.Folder
        $files = Get-ChildItem -LiteralPath $componentRoot -File -Recurse | Sort-Object FullName
        foreach ($f in $files) {
            $relative = $f.FullName.Substring($componentRoot.Length).TrimStart('\')
            $lines.Add('  Delete "$INSTDIR\' + $c.Folder + '\' + $relative + '"')
        }
        $dirs = Get-ChildItem -LiteralPath $componentRoot -Directory -Recurse |
            Sort-Object { $_.FullName.Length } -Descending
        foreach ($d in $dirs) {
            $relative = $d.FullName.Substring($componentRoot.Length).TrimStart('\')
            $lines.Add('  RMDir "$INSTDIR\' + $c.Folder + '\' + $relative + '"')
        }
        $lines.Add('  RMDir "$INSTDIR\' + $c.Folder + '"')
    }
    $lines.Add('!macroend')
    $lines.Add('')
    # The folders that can hold user data: every component folder, each retired
    # folder and each renamed-from folder. "Remove my data" deletes only these
    # folders under the install root, never the install root itself, so a
    # custom install path cannot widen it.
    $dataFolders = @(@($Table | ForEach-Object { $_.Folder }) + @($Retired | ForEach-Object { $_.Folder }) + @($Renames | ForEach-Object { $_.From }) | Select-Object -Unique)
    $lines.Add('!macro SUITE_REMOVE_USER_DATA')
    foreach ($f in $dataFolders) {
        $lines.Add('  RMDir /r "$INSTDIR\' + $f + '"')
    }
    $lines.Add('!macroend')
    $lines.Add('')
    # Names what the uninstall left, with paths. Output is for the details
    # list; a silent uninstall shows none.
    $lines.Add('!macro SUITE_REPORT_KEPT')
    $lines.Add('  StrCpy $R9 0')
    foreach ($f in $dataFolders) {
        $lines.Add('  IfFileExists "$INSTDIR\' + $f + '\*.*" 0 +3')
        $lines.Add('  DetailPrint "Kept: $INSTDIR\' + $f + '"')
        $lines.Add('  StrCpy $R9 1')
    }
    foreach ($e in $ExternalData) {
        $lines.Add('  IfFileExists "$LOCALAPPDATA\' + $e + '\*.*" 0 +3')
        $lines.Add('  DetailPrint "Kept (shared or outside the suite folder): $LOCALAPPDATA\' + $e + '"')
        $lines.Add('  StrCpy $R9 1')
    }
    $lines.Add('  StrCmp $R9 0 +2')
    $lines.Add('  DetailPrint "Your settings, logs, reports and history were not removed. Delete the folders above by hand to remove them."')
    $lines.Add('!macroend')
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

if ([string]::IsNullOrWhiteSpace($SuiteVersion)) {
    $SuiteVersion = (Get-Date).ToString('yyyy.MM.dd')
}
if ($SuiteVersion -notmatch '^[0-9][0-9A-Za-z\.\-]*$') {
    throw ('Unusable suite version: ' + $SuiteVersion)
}
if (-not (Test-Path -LiteralPath $MakeNsis)) {
    throw ('makensis.exe not found: ' + $MakeNsis)
}
if (-not (Test-Path -LiteralPath $NsiPath)) {
    throw ('Installer script not found: ' + $NsiPath)
}

foreach ($component in $Components) {
    $repoPath = if ($component.Repo -eq 'app-packager-suite') { $RepoRoot } else { Join-Path $SiblingRoot $component.Repo }
    Add-Member -InputObject $component -NotePropertyName 'RepoPath' -NotePropertyValue $repoPath -Force
    if (-not (Test-Path -LiteralPath $repoPath)) {
        throw ('Component repository missing: ' + $repoPath)
    }
}

try {
    if ((Test-Path -LiteralPath $StageRoot) -and @(Get-ChildItem -LiteralPath $StageRoot -Force).Count -gt 0) {
        throw ('Staging folder is not empty: ' + $StageRoot)
    }
    New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null

    $manifestComponents = New-Object System.Collections.Generic.List[object]

    foreach ($component in $Components) {
        Write-Step ('Staging ' + $component.Folder + ' from ' + $component.RepoPath)
        $dest = Join-Path $StageRoot $component.Folder
        Export-RepoHead -RepoPath $component.RepoPath -Destination $dest

        $stripped = Remove-TestArtifact -Root $dest
        if ($stripped -gt 0) { Write-Step ('  removed ' + $stripped + ' test and maintainer file(s) from the payload') }

        $entryPath = Join-Path $dest $component.Entry
        if (-not (Test-Path -LiteralPath $entryPath)) {
            throw ('Entry script missing from payload: ' + $entryPath)
        }

        $version = Get-ComponentVersion -Component $component -StagedRoot $dest
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw ('Could not determine a version for ' + $component.Folder)
        }

        $releaseState = Test-ComponentRelease -Component $component -StagedVersion $version -Offline:($SkipReleaseCheck -or ($AllowUnpublished -contains $component.Repo))

        $fileCount = @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count
        Write-Step ('  version ' + $version + ' (' + $component.VersionSource + '), ' + $releaseState + ', ' + $fileCount + ' file(s)')

        $manifestComponents.Add([ordered]@{
            name          = $component.Folder
            version       = $version
            versionSource = $component.VersionSource
            commit        = (Get-HeadCommit -RepoPath $component.RepoPath)
            entry         = $component.Entry
            shortcut      = $component.Shortcut
            files         = $fileCount
        })
    }

    Write-Step ('All ' + $Components.Count + ' components are at their latest release: ' + (($manifestComponents | ForEach-Object { $_.name + ' ' + $_.version }) -join ', '))

    if ($ValidateOnly) {
        Write-Step 'ValidateOnly: stopping before the installer is compiled.'
        return
    }

    $defaultsMoved = Move-DefaultFolder -StageRoot $StageRoot -Table $Components -Folders $DefaultFolders
    Write-Step ('Moved ' + $defaultsMoved + ' default file(s) into the defaults tree (placed by suite-userdata.ps1)')

    $manifest = [ordered]@{
        suite      = 'AppPackager Suite'
        version    = $SuiteVersion
        built      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        components = $manifestComponents.ToArray()
    }
    $manifestPath = Join-Path $StageRoot 'suite-manifest.json'
    ($manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $manifestPath -Encoding ASCII
    Write-Step ('Wrote ' + $manifestPath)

    $includePath = Join-Path $StageRoot 'components.nsh'
    Write-ComponentsInclude -Table $Components -Path $includePath -Renames $FolderRenames -Retired $RetiredComponents -RetiredShortcuts $RetiredShortcuts -ExternalData $ExternalUserData
    Write-Step ('Wrote ' + $includePath)

    $payloadBytes = (Get-ChildItem -LiteralPath $StageRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $payloadFiles = @(Get-ChildItem -LiteralPath $StageRoot -Recurse -File).Count

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $outFile = Join-Path $OutDir ('SuiteSetup-' + $SuiteVersion + '.exe')
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }

    Write-Step ('Compiling ' + $NsiPath)
    & $MakeNsis `
        ('/DSUITEVERSION=' + $SuiteVersion) `
        ('/DPAYLOADDIR=' + $StageRoot) `
        ('/DOUTFILE=' + $outFile) `
        $NsiPath
    if ($LASTEXITCODE -ne 0) { throw ('makensis failed with exit code ' + $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath $outFile)) { throw ('makensis produced no output at ' + $outFile) }

    $hash = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item -LiteralPath $outFile).Length
    $checksums = Join-Path $OutDir 'checksums.txt'
    ($hash + '  ' + (Split-Path -Leaf $outFile)) | Set-Content -LiteralPath $checksums -Encoding ASCII

    Write-Step ('Components: ' + $Components.Count)
    Write-Step ('Payload : ' + [Math]::Round($payloadBytes / 1MB, 2) + ' MB (' + $payloadFiles + ' files)')
    Write-Step ('Output  : ' + $outFile)
    Write-Step ('Size    : ' + [Math]::Round($size / 1MB, 2) + ' MB (' + $size + ' bytes)')
    Write-Step ('SHA256  : ' + $hash)
    Write-Step ('Checksum: ' + $checksums)
}
finally {
    if (-not $KeepStage -and (Test-Path -LiteralPath $StageRoot)) { Remove-Item -LiteralPath $StageRoot -Recurse -Force }
}
