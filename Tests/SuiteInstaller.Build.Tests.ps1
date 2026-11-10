#Requires -Modules Pester

<#
.SYNOPSIS
    Tests the release guard of tools\build-suite-installer.ps1 against a
    fixture of thirteen tiny git repositories, and checks the release workflow
    runs the tests before it builds.

.DESCRIPTION
    The fixture holds one repository per row of the build script's component
    table, each committed and tagged v1.0.0, beside a copy of the build
    script. The script runs as a child process with -ValidateOnly and
    -SkipReleaseCheck, so no installer is compiled and no network is used.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:BuildScript = Join-Path $script:RepoRoot 'tools\build-suite-installer.ps1'
    $script:HostExe = (Get-Process -Id $PID).Path

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuildScript, [ref]$null, [ref]$null)
    $assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Components' }, $true) | Select-Object -First 1
    $script:Components = @(& ([scriptblock]::Create($assign.Right.Extent.Text)))

    function Invoke-Git {
        param([string]$Path, [string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        $out = & git -C $Path -c user.name=fixture -c user.email=fixture@example.test -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('git ' + ($Arguments -join ' ') + ' failed in ' + $Path + ': ' + ($out | Out-String)) }
    }

    function New-FixtureRepo {
        param([string]$Root, [object]$Component)
        $ErrorActionPreference = 'Continue'
        $path = Join-Path $Root $Component.Repo
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        & git -C $path init -q 2>&1 | Out-Null
        if ($Component.VersionSource -eq 'ScriptHeader') {
            Set-Content -LiteralPath (Join-Path $path $Component.Entry) -Value @('# fixture', 'Version : 1.0.0') -Encoding ASCII
        }
        else {
            Set-Content -LiteralPath (Join-Path $path $Component.Entry) -Value '# fixture' -Encoding ASCII
        }
        if ($Component.VersionSource -eq 'Changelog') {
            Set-Content -LiteralPath (Join-Path $path $Component.VersionFile) -Value @('# Changelog', '', '## [1.0.0] - 2026-01-01') -Encoding ASCII
        }
        if ($Component.VersionSource -eq 'ModuleManifest') {
            $manifest = Join-Path $path $Component.VersionFile
            New-Item -ItemType Directory -Path (Split-Path -Parent $manifest) -Force | Out-Null
            Set-Content -LiteralPath $manifest -Value "@{ ModuleVersion = '1.0.0' }" -Encoding ASCII
        }
        if ($Component.Repo -eq 'app-packager-suite') {
            New-Item -ItemType Directory -Path (Join-Path $path 'tools'), (Join-Path $path 'installer') -Force | Out-Null
            Copy-Item -LiteralPath $script:BuildScript -Destination (Join-Path $path 'tools\build-suite-installer.ps1')
            Set-Content -LiteralPath (Join-Path $path 'installer\suite.nsi') -Value '; fixture' -Encoding ASCII
        }
        Invoke-Git $path @('add', '-A')
        Invoke-Git $path @('commit', '-q', '-m', 'fixture')
        Invoke-Git $path @('tag', 'v1.0.0')
    }

    function Invoke-FixtureBuild {
        param([string]$Root, [string[]]$Extra = @())
        # Windows PowerShell turns native stderr into terminating errors under Stop.
        $ErrorActionPreference = 'Continue'
        $script = Join-Path $Root 'app-packager-suite\tools\build-suite-installer.ps1'
        $output = & $script:HostExe -NoProfile -ExecutionPolicy Bypass -File $script -SuiteVersion 1.0.0 -MakeNsis $script:HostExe -SkipReleaseCheck -ValidateOnly @Extra 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
}

Describe 'build-suite-installer.ps1 release guard' {
    BeforeAll {
        $script:Fixture = Join-Path ([IO.Path]::GetTempPath()) ('suite-build-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Fixture -Force | Out-Null
        foreach ($c in $script:Components) { New-FixtureRepo -Root $script:Fixture -Component $c }
    }

    AfterAll {
        if ($script:Fixture) { Remove-Item -LiteralPath $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts a clean clone that has no ignore rules for build output' {
        $result = Invoke-FixtureBuild -Root $script:Fixture
        $result.Output | Should -Not -Match 'uncommitted change'
        $result.Output | Should -Match 'All 13 components are at their latest release'
        $result.ExitCode | Should -Be 0
    }

    It 'leaves nothing untracked in the suite checkout after a build' {
        $null = Invoke-FixtureBuild -Root $script:Fixture
        $status = @(& git -C (Join-Path $script:Fixture 'app-packager-suite') status --porcelain --untracked-files=all)
        $status | Should -BeNullOrEmpty
    }

    It 'rejects a staging folder inside the checkout' {
        $inside = Join-Path $script:Fixture 'app-packager-suite\installer\stage'
        $result = Invoke-FixtureBuild -Root $script:Fixture -Extra @('-StageRoot', $inside)
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'uncommitted change'
        Test-Path -LiteralPath $inside | Should -BeFalse
    }

    It 'still rejects a modified tracked file in the suite checkout' {
        $file = Join-Path $script:Fixture 'app-packager-suite\start-suite.ps1'
        Add-Content -LiteralPath $file -Value '# edit' -Encoding ASCII
        try {
            $result = Invoke-FixtureBuild -Root $script:Fixture
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'app-packager-suite: working tree has 1 uncommitted change'
        }
        finally { Invoke-Git (Join-Path $script:Fixture 'app-packager-suite') @('checkout', '--', 'start-suite.ps1') }
    }

    It 'still rejects an untracked file in a component checkout' {
        $file = Join-Path $script:Fixture 'site-hygiene\stray.txt'
        Set-Content -LiteralPath $file -Value 'stray' -Encoding ASCII
        try {
            $result = Invoke-FixtureBuild -Root $script:Fixture
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'site-hygiene: working tree has 1 uncommitted change'
        }
        finally { Remove-Item -LiteralPath $file -Force }
    }

    It 'removes its staging folder when a check fails' {
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('suite-stage-probe-' + [Guid]::NewGuid().ToString('N'))
        $file = Join-Path $script:Fixture 'site-hygiene\stray.txt'
        Set-Content -LiteralPath $file -Value 'stray' -Encoding ASCII
        try {
            $result = Invoke-FixtureBuild -Root $script:Fixture -Extra @('-StageRoot', $stage)
            $result.ExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $stage | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $file -Force }
    }
}

Describe 'release.yml test gate' {
    BeforeAll {
        $script:Workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\release.yml') -Raw
    }

    It 'runs Pester under Windows PowerShell and PowerShell 7 in separate jobs with a pinned version' {
        $script:Workflow | Should -Match '(?s)\n  test-powershell:.*?shell: powershell\r?\n        run: \|\r?\n          \$ErrorActionPreference = ''Stop''\r?\n          Import-Module Pester'
        $script:Workflow | Should -Match '(?s)\n  test-pwsh:.*?shell: pwsh\r?\n        run: \|\r?\n          \$ErrorActionPreference = ''Stop''\r?\n          Import-Module Pester'
        ([regex]::Matches($script:Workflow, 'Install-Module -Name Pester -RequiredVersion 5\.7\.1')).Count | Should -Be 2
        ([regex]::Matches($script:Workflow, 'Invoke-Pester -Configuration \$config')).Count | Should -Be 2
    }

    It 'makes the build wait for both test jobs' {
        $script:Workflow | Should -Match '(?s)\n  build:\r?\n    needs: \[test-powershell, test-pwsh\]\r?\n'
    }
}

Describe 'Remove-TestArtifact payload strip' {
    BeforeAll {
        $buildAst = [System.Management.Automation.Language.Parser]::ParseFile($script:BuildScript, [ref]$null, [ref]$null)
        $fn = $buildAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-TestArtifact' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        $script:Payload = Join-Path ([IO.Path]::GetTempPath()) ('strip-' + [Guid]::NewGuid().ToString('N'))
        foreach ($d in 'docs\images', 'screenshots', '.github\workflows', 'Tests', 'Lib', 'Module\docs') {
            New-Item -ItemType Directory -Path (Join-Path $script:Payload $d) -Force | Out-Null
        }
        foreach ($f in 'docs\images\a.png', 'screenshots\b.png', 'screenshot.png', '.github\workflows\c.yml', '.coderabbit.yaml', 'Invoke-Checks.ps1', 'RELEASING.md', 'Tests\x.ps1', 'Lib\keep.dll', 'Module\docs\keep.txt', 'start-tool.ps1', 'README.md') {
            Set-Content -LiteralPath (Join-Path $script:Payload $f) -Value 'x'
        }
        $script:Removed = Remove-TestArtifact -Root $script:Payload
    }
    AfterAll { Remove-Item -LiteralPath $script:Payload -Recurse -Force -ErrorAction SilentlyContinue }

    It 'removes the root-level docs, screenshots and repository tooling' {
        foreach ($n in 'docs', 'screenshots', 'screenshot.png', '.github', '.coderabbit.yaml', 'Invoke-Checks.ps1', 'RELEASING.md', 'Tests') {
            Test-Path -LiteralPath (Join-Path $script:Payload $n) | Should -BeFalse -Because $n
        }
    }
    It 'keeps the files that run, and a docs folder below the component root' {
        foreach ($n in 'Lib\keep.dll', 'Module\docs\keep.txt', 'start-tool.ps1', 'README.md') {
            Test-Path -LiteralPath (Join-Path $script:Payload $n) | Should -BeTrue -Because $n
        }
    }
    It 'counts every removed file' {
        $script:Removed | Should -Be 8
    }
}
