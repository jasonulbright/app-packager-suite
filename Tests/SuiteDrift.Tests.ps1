#Requires -Modules Pester

<#
.SYNOPSIS
    Tests the comparison logic of tools/Test-SuiteDrift.ps1 (guard H-4) with
    fixtures. No network and no gh call: the script is dot-sourced and only its
    pure functions run.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:RepoRoot 'tools\Test-SuiteDrift.ps1'
    . $script:ScriptPath
    $script:Fix = Join-Path $PSScriptRoot 'Fixtures\SuiteDrift'
    $script:Now = [datetime]::Parse('2026-11-23T12:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    function script:Get-Row {
        param([string]$Tag, [string]$Carried, [string]$Published = '2026-11-23T10:00:00Z', [int]$Grace = 72)
        Compare-SuiteComponent -Name 'x' -LatestTag $Tag -PublishedUtc $Published -Carried $Carried -CarriedSource 'manifest' -Now $script:Now -GraceHours $Grace
    }
}

Describe 'Compare-SuiteComponent' {
    It 'is OK when the carried version equals the latest tag' {
        $r = Get-Row -Tag 'v2026.11.22.0161' -Carried '2026.11.22.0161'
        $r.Status | Should -Be 'OK'
        $r.Level | Should -Be 'ok'
    }

    It 'is BEHIND and only a warning inside the grace period' {
        $r = Get-Row -Tag 'v2026.11.23.0162' -Carried '2026.11.22.0161' -Published '2026-11-23T10:00:00Z'
        $r.Status | Should -Be 'BEHIND'
        $r.Level | Should -Be 'warn'
        $r.AgeHours | Should -Be 2
    }

    It 'is BEHIND and a failure past the grace period' {
        $r = Get-Row -Tag 'v2026.11.23.0162' -Carried '2026.11.22.0161' -Published '2026-11-19T10:00:00Z'
        $r.Status | Should -Be 'BEHIND'
        $r.Level | Should -Be 'fail'
    }

    It 'treats the grace limit itself as a warning' {
        $r = Get-Row -Tag 'v2026.11.23.0162' -Carried '2026.11.22.0161' -Published '2026-11-20T12:00:00Z' -Grace 72
        $r.AgeHours | Should -Be 72
        $r.Level | Should -Be 'warn'
    }

    It 'compares numerically, not as text (build 0100 is newer than 0099)' {
        (Get-Row -Tag 'v2026.11.22.0100' -Carried '2026.11.22.0099').Status | Should -Be 'BEHIND'
        (Get-Row -Tag 'v2026.11.22.0099' -Carried '2026.11.22.0100').Status | Should -Be 'AHEAD'
    }

    It 'is AHEAD and only a warning when the suite carries a newer version than the latest release' {
        $r = Get-Row -Tag 'v2026.11.22.0161' -Carried '2026.11.23.0162'
        $r.Status | Should -Be 'AHEAD'
        $r.Level | Should -Be 'warn'
    }

    It 'is UNKNOWN and only a warning when no carried version could be read' {
        $r = Get-Row -Tag 'v2026.11.22.0161' -Carried ''
        $r.Status | Should -Be 'UNKNOWN'
        $r.Level | Should -Be 'warn'
    }
}

Describe 'Get-CarriedFromManifest' {
    It 'reads name and version of each component' {
        $map = Get-CarriedFromManifest (Get-Content -LiteralPath (Join-Path $script:Fix 'manifest-full.json') -Raw)
        $map['app-packager'] | Should -Be '2026.11.22.0161'
        $map.Count | Should -Be 3
    }

    It 'returns nothing for a missing manifest' {
        (Get-CarriedFromManifest '').Count | Should -Be 0
        (Get-CarriedFromManifest $null).Count | Should -Be 0
    }

    It 'returns nothing for a manifest that is not JSON or has no components' {
        (Get-CarriedFromManifest 'not json {').Count | Should -Be 0
        (Get-CarriedFromManifest '{ "suite": "x" }').Count | Should -Be 0
    }
}

Describe 'Get-CarriedFromNotes' {
    BeforeAll {
        $script:Newest = Get-Content -LiteralPath (Join-Path $script:Fix 'notes-newest.md') -Raw
        $script:Older = Get-Content -LiteralPath (Join-Path $script:Fix 'notes-older.md') -Raw
        $script:Names = 'app-packager', 'update-planner', 'device-inspector', 'site-hygiene', 'deployment-helper', 'collection-manager', 'collection-and-compliance-manager', 'detection-tester', 'pivots-and-scripts'
    }

    It 'takes the newest mention of each component' {
        $map = Get-CarriedFromNotes -NotesNewestFirst @($script:Newest, $script:Older) -Names $script:Names
        $map['app-packager'] | Should -Be '2026.11.23.0162'
        $map['update-planner'] | Should -Be '2026.11.22.0017'
    }

    It 'falls back to an older release for a component the newest one leaves unchanged' {
        $map = Get-CarriedFromNotes -NotesNewestFirst @($script:Newest, $script:Older) -Names $script:Names
        $map['site-hygiene'] | Should -Be '2026.11.22.0043'
        $map['deployment-helper'] | Should -Be '2026.11.22.0031'
        $map['collection-manager'] | Should -Be '2026.11.22.0035'
    }

    It 'does not mistake collection-manager for collection-and-compliance-manager' {
        $map = Get-CarriedFromNotes -NotesNewestFirst @($script:Older) -Names $script:Names
        $map.ContainsKey('collection-and-compliance-manager') | Should -BeFalse
    }

    It 'leaves a component out when no release names it' {
        $map = Get-CarriedFromNotes -NotesNewestFirst @($script:Newest, $script:Older) -Names $script:Names
        $map.ContainsKey('pivots-and-scripts') | Should -BeFalse
    }

    It 'returns nothing for empty notes' {
        (Get-CarriedFromNotes -NotesNewestFirst @('', $null) -Names $script:Names).Count | Should -Be 0
    }
}

Describe 'Get-SuiteDriftExitCode' {
    It 'is 0 when every row is ok or a warning' {
        Get-SuiteDriftExitCode @([pscustomobject]@{ Level = 'ok' }, [pscustomobject]@{ Level = 'warn' }) | Should -Be 0
    }
    It 'is 1 when any row fails' {
        Get-SuiteDriftExitCode @([pscustomobject]@{ Level = 'ok' }, [pscustomobject]@{ Level = 'fail' }) | Should -Be 1
    }
}

Describe 'Component list' {
    It 'matches the Components table of the installer build script' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tools\build-suite-installer.ps1') -Raw
        $repos = @([regex]::Matches($text, "Repo = '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'app-packager-suite' } | Sort-Object -Unique)
        $repos | Should -Be @($script:SuiteComponentRepos | Sort-Object)
    }
}
