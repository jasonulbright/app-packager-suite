#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
<#
.SYNOPSIS
    The repository x guard matrix: every ConfigMgr tool repository of the suite keeps the same set of guard tests.
.DESCRIPTION
    Each cell of the matrix is one guard test file in the Tests folder of one repository. A repository that lacks a guard
    file fails its cell. The repositories sit next to this one (the folder of this repository's parent) or in the folder
    that SUITE_REPOS_ROOT names. When a repository folder is absent the cell is skipped, unless SUITE_REQUIRE_REPOS is 1
    (the pull request workflow sets it after it clones the repositories). The test reads file names only. It opens no window.
#>

BeforeDiscovery {
    $suiteRoot = Split-Path -Parent $PSScriptRoot
    $reposRoot = if ($env:SUITE_REPOS_ROOT) { $env:SUITE_REPOS_ROOT } else { Split-Path -Parent $suiteRoot }
    $repos = @(
        'collection-and-compliance-manager', 'collection-manager', 'deployment-helper', 'detection-tester', 'device-inspector',
        'dp-content-manager', 'installer-analysis', 'maintenance-window-manager', 'pivots-and-scripts', 'site-hygiene', 'update-planner'
    )
    # Guard name -> the file names that count. A repository may name its theme guard in either way.
    $guards = [ordered]@{
        'Theme guard'   = @('Theme.Guard.Tests.ps1', 'ThemeGuard.Tests.ps1')
        'Theme source'  = @('Theme.Source.Guard.Tests.ps1')
        'ButtonStyle'   = @('ButtonStyle.Guard.Tests.ps1')
        'ButtonStates'  = @('ButtonStates.Window.Tests.ps1')
        'Chrome'        = @('Chrome.Window.Tests.ps1')
        'Density'       = @('Density.Tests.ps1')
        'FontWeight'    = @('FontWeight.Guard.Tests.ps1')
        'Footer'        = @('Footer.Guard.Tests.ps1')
        'Encoding'      = @('Encoding.Guard.Tests.ps1')
        'GuideImages'   = @('GuideImages.Guard.Tests.ps1')
        'Readme.Images' = @('Readme.Images.Guard.Tests.ps1')
        'WindowGuard'   = @('WindowGuard.Tests.ps1')
    }
    $script:MatrixCases = foreach ($repo in $repos) {
        foreach ($guard in $guards.Keys) {
            @{ Repo = $repo; Guard = $guard; Names = $guards[$guard]; TestsDir = (Join-Path (Join-Path $reposRoot $repo) 'Tests'); RepoDir = (Join-Path $reposRoot $repo) }
        }
    }
    $script:RepoData = @(@{ Repos = $repos })
}

BeforeAll {
    $script:SuiteRoot = Split-Path -Parent $PSScriptRoot
    function Get-MissingGuard {
        param([string]$TestsDir, [hashtable]$Guards)
        foreach ($guard in $Guards.Keys) {
            $found = @($Guards[$guard] | Where-Object { Test-Path -LiteralPath (Join-Path $TestsDir $_) -PathType Leaf })
            if ($found.Count -eq 0) { $guard }
        }
    }
}

Describe 'Repository x guard matrix' {
    It '<Repo> has the <Guard> guard' -ForEach $script:MatrixCases {
        if (-not (Test-Path -LiteralPath $RepoDir -PathType Container)) {
            if ($env:SUITE_REQUIRE_REPOS -eq '1') { throw "The repository folder $RepoDir does not exist." }
            Set-ItResult -Skipped -Because "the repository folder $RepoDir does not exist (set SUITE_REQUIRE_REPOS=1 to require it)"
            return
        }
        $found = @($Names | Where-Object { Test-Path -LiteralPath (Join-Path $TestsDir $_) -PathType Leaf })
        $found.Count | Should -BeGreaterThan 0 -Because "$Repo must have one of: $($Names -join ', ') in its Tests folder"
    }

    It 'lists every consumer repository of sync-suitecommon.ps1 except app-packager' -ForEach $script:RepoData {
        $text = Get-Content -LiteralPath (Join-Path $script:SuiteRoot 'sync-suitecommon.ps1') -Raw
        $consumers = @([regex]::Matches($text, "Join-Path \`$projectsRoot '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $consumers.Count | Should -BeGreaterThan 10
        $missing = @($consumers | Where-Object { $_ -ne 'app-packager' -and $_ -notin $Repos })
        $missing | Should -BeNullOrEmpty -Because 'add the new repository to the matrix of this test'
    }

    It 'reports a guard that a repository lacks (the check itself)' {
        $dir = Join-Path $TestDrive 'repo\Tests'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Footer.Guard.Tests.ps1') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dir 'ThemeGuard.Tests.ps1') -Value 'x'
        $guards = @{ 'Footer' = @('Footer.Guard.Tests.ps1'); 'Theme guard' = @('Theme.Guard.Tests.ps1', 'ThemeGuard.Tests.ps1'); 'Encoding' = @('Encoding.Guard.Tests.ps1') }
        @(Get-MissingGuard -TestsDir $dir -Guards $guards) | Should -Be @('Encoding')
    }
}
