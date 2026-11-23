<#
.SYNOPSIS
    Reports each suite component whose latest GitHub release is newer than the
    version the latest published suite release carries (guard H-4).

.DESCRIPTION
    Read only. Uses the GitHub CLI (gh) and the GitHub API; it changes nothing.

    For each of the twelve components it reads the latest published release
    (tag and publish time) and the version the latest published suite release
    carries. The carried version comes from, in this order:
      1. The suite-manifest.json release asset (written by release.yml since the
         release that added this guard).
      2. The "Carry <component> <version>" lines in the notes of the latest suite
         release, then of earlier releases (a release that does not name a
         component leaves it unchanged, so the newest mention wins).
    A component with neither source is UNKNOWN.

    Status per component:
      OK       the carried version equals the latest release.
      BEHIND   the latest release is newer than the carried version.
      AHEAD    the carried version is newer than the latest release (a retracted
               or replaced release; check by hand).
      UNKNOWN  no carried version could be read.

    Warn versus fail: a BEHIND component is a warning for the grace period
    (default 72 hours since its release was published, -GraceHours). Past the
    grace period the run exits 1. AHEAD and UNKNOWN are warnings and never fail.

    Exit codes: 0 no failure (warnings may print), 1 at least one component is
    BEHIND past the grace period, 2 the guard could not read GitHub.

    In GitHub Actions a warning prints as a ::warning:: annotation and a failure
    as ::error::.

.PARAMETER GraceHours
    Hours a component release may wait for a suite release before the run fails.

.PARAMETER Owner
    GitHub owner of the repositories.

.PARAMETER Json
    Print the result as JSON instead of a table.

.EXAMPLE
    .\tools\Test-SuiteDrift.ps1
    Run before a suite release to list the components the release must carry,
    and after it to confirm every row is OK.
#>
[CmdletBinding()]
param(
    [int]$GraceHours = 72,
    [string]$Owner = 'jasonulbright',
    [switch]$Json
)

# The twelve component repositories the installer carries (the suite repository
# itself is the thirteenth and is not compared). Tests/SuiteDrift.Tests.ps1 checks
# this list against the $Components table of tools/build-suite-installer.ps1.
$script:SuiteComponentRepos = @(
    'app-packager', 'site-hygiene', 'collection-and-compliance-manager', 'collection-manager',
    'deployment-helper', 'detection-tester', 'dp-content-manager', 'installer-analysis',
    'maintenance-window-manager', 'pivots-and-scripts', 'update-planner', 'device-inspector'
)

function ConvertTo-SuiteVersion {
    # Turns 'v2026.11.22.0161' or '2026.11.22.0161' into a [version]; $null when unusable.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim().TrimStart('v', 'V')
    if ($t -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    try { return [version]$t } catch { return $null }
}

function Get-CarriedFromManifest {
    # Returns a hashtable name -> version text from the text of suite-manifest.json; empty when unusable.
    param([string]$ManifestJson)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($ManifestJson)) { return $map }
    try { $m = $ManifestJson | ConvertFrom-Json } catch { return $map }
    if ($null -eq $m -or $null -eq $m.components) { return $map }
    foreach ($c in @($m.components)) {
        if ($c.name -and $c.version) { $map[[string]$c.name] = [string]$c.version }
    }
    return $map
}

function Get-CarriedFromNotes {
    # NotesNewestFirst: release note texts, newest suite release first. The newest mention of a component wins.
    param([string[]]$NotesNewestFirst, [string[]]$Names)
    $map = @{}
    foreach ($notes in $NotesNewestFirst) {
        if ([string]::IsNullOrWhiteSpace($notes)) { continue }
        foreach ($name in $Names) {
            if ($map.ContainsKey($name)) { continue }
            $m = [regex]::Match($notes, '(?<![\w-])' + [regex]::Escape($name) + '(?![\w-])\s+v?(\d+(?:\.\d+){2,3})')
            if ($m.Success) { $map[$name] = $m.Groups[1].Value }
        }
    }
    return $map
}

function Compare-SuiteComponent {
    # One row for one component. Pure: no network, no clock (Now is a parameter).
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$LatestTag,
        [string]$PublishedUtc,
        [string]$Carried,
        [string]$CarriedSource = '',
        [Parameter(Mandatory)][datetime]$Now,
        [int]$GraceHours = 72
    )
    $latest = ConvertTo-SuiteVersion $LatestTag
    $have = ConvertTo-SuiteVersion $Carried
    $ageHours = $null
    if ($PublishedUtc) {
        $pub = [datetime]::Parse($PublishedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        $ageHours = [math]::Round(($Now.ToUniversalTime() - $pub).TotalHours, 1)
    }
    $status = 'UNKNOWN'
    $level = 'warn'
    if ($null -ne $latest -and $null -ne $have) {
        if ($have -eq $latest) { $status = 'OK'; $level = 'ok' }
        elseif ($have -lt $latest) {
            $status = 'BEHIND'
            $level = if ($null -ne $ageHours -and $ageHours -gt $GraceHours) { 'fail' } else { 'warn' }
        }
        else { $status = 'AHEAD'; $level = 'warn' }
    }
    [pscustomobject]@{
        Component = $Name
        LatestTag = $LatestTag
        Carried   = $Carried
        Source    = $CarriedSource
        Status    = $status
        AgeHours  = $ageHours
        Level     = $level
    }
}

function Get-SuiteDriftExitCode {
    param([object[]]$Rows)
    if (@($Rows | Where-Object { $_.Level -eq 'fail' }).Count -gt 0) { return 1 }
    return 0
}

function Invoke-GhJson {
    param([string[]]$GhArgs)
    $out = & gh @GhArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('gh ' + ($GhArgs -join ' ') + ' failed: ' + ($out | Out-String).Trim()) }
    return (($out | Out-String) | ConvertFrom-Json)
}

function Get-SuiteDrift {
    param([string]$Owner, [int]$GraceHours, [datetime]$Now)
    $suiteRepo = $Owner + '/app-packager-suite'
    $suiteList = @(Invoke-GhJson @('api', ('repos/' + $suiteRepo + '/releases?per_page=30')) | Where-Object { -not $_.draft -and -not $_.prerelease })
    if ($suiteList.Count -eq 0) { throw 'The suite repository has no published release.' }
    $latestSuite = $suiteList[0]

    $manifestText = ''
    $asset = @($latestSuite.assets | Where-Object { $_.name -eq 'suite-manifest.json' })[0]
    if ($asset) {
        $manifestText = (& gh api -H 'Accept: application/octet-stream' ('repos/' + $suiteRepo + '/releases/assets/' + $asset.id) 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { $manifestText = '' }
    }
    $fromManifest = Get-CarriedFromManifest $manifestText
    $fromNotes = Get-CarriedFromNotes -NotesNewestFirst @($suiteList | ForEach-Object { [string]$_.body }) -Names $script:SuiteComponentRepos

    $rows = foreach ($repo in $script:SuiteComponentRepos) {
        $rel = Invoke-GhJson @('api', ('repos/' + $Owner + '/' + $repo + '/releases/latest'))
        $carried = ''; $source = ''
        if ($fromManifest.ContainsKey($repo)) { $carried = $fromManifest[$repo]; $source = 'manifest' }
        elseif ($fromNotes.ContainsKey($repo)) { $carried = $fromNotes[$repo]; $source = 'notes' }
        Compare-SuiteComponent -Name $repo -LatestTag $rel.tag_name -PublishedUtc $rel.published_at -Carried $carried -CarriedSource $source -Now $Now -GraceHours $GraceHours
    }
    [pscustomobject]@{ SuiteTag = $latestSuite.tag_name; Rows = @($rows) }
}

# Dot-sourcing (the tests do) loads the functions and runs nothing.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Get-SuiteDrift -Owner $Owner -GraceHours $GraceHours -Now (Get-Date)
    }
    catch {
        Write-Host ('Suite drift guard could not read GitHub: ' + $_.Exception.Message)
        exit 2
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4 }
    else {
        Write-Host ('Latest suite release: ' + $result.SuiteTag + '  (grace ' + $GraceHours + ' h)')
        $result.Rows | Format-Table Component, LatestTag, Carried, Source, Status, AgeHours -AutoSize | Out-String -Width 200 | Write-Host
    }
    $inActions = [bool]$env:GITHUB_ACTIONS
    foreach ($r in $result.Rows) {
        if ($r.Level -eq 'ok') { continue }
        $msg = '{0}: latest {1}, suite {2} carries {3} ({4}, {5} h since release)' -f $r.Component, $r.LatestTag, $result.SuiteTag, $(if ($r.Carried) { $r.Carried } else { 'nothing readable' }), $r.Status, $r.AgeHours
        if ($inActions) { Write-Host ('::' + $(if ($r.Level -eq 'fail') { 'error' } else { 'warning' }) + '::' + $msg) }
        else { Write-Host ($(if ($r.Level -eq 'fail') { 'FAIL ' } else { 'WARN ' }) + $msg) }
    }
    $code = Get-SuiteDriftExitCode $result.Rows
    if ($code -eq 0 -and @($result.Rows | Where-Object { $_.Level -eq 'ok' }).Count -eq $result.Rows.Count) { Write-Host 'Every component is carried by the latest suite release.' }
    exit $code
}
