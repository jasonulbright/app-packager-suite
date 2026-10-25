#Requires -Modules Pester

<#
.SYNOPSIS
    Tests the folder merge that the suite installer runs when a renamed
    install folder and its replacement both exist (suite-core and
    app-packager-suite).

.DESCRIPTION
    The first Describe runs installer\merge-user-folder.ps1 as a child process
    on the host that runs the tests. The second builds a fixture installer
    from the build script's own generator and runs it over a fake earlier
    install; it is skipped when makensis.exe is absent. The fixture installs
    under a temporary folder with its own Start Menu folder and ARP key.
#>

BeforeDiscovery {
    $script:HasNsis = Test-Path -LiteralPath 'C:\Program Files (x86)\NSIS\makensis.exe'
}

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:MergeScript = Join-Path $script:RepoRoot 'installer\merge-user-folder.ps1'
    $script:HostExe = (Get-Process -Id $PID).Path

    function Invoke-Merge {
        param([string]$Source, [string]$Destination)
        $output = & $script:HostExe -NoProfile -ExecutionPolicy Bypass -File $script:MergeScript -Source $Source -Destination $Destination 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }

    function Write-TestFile {
        param([string]$Path, [string]$Text)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $Path -Value $Text -Encoding ASCII
    }

    function Read-TestFile {
        param([string]$Path)
        (Get-Content -LiteralPath $Path -Raw).Trim()
    }
}

Describe 'merge-user-folder.ps1' {
    BeforeEach {
        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('suite-merge ' + [Guid]::NewGuid().ToString('N'))
        $script:src = Join-Path $script:work "suite-core's [old]"
        $script:dst = Join-Path $script:work 'app-packager-suite'
        New-Item -ItemType Directory -Path $script:src, $script:dst -Force | Out-Null
    }

    AfterEach {
        if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps both versions of a conflicting settings file and merges nested user data' {
        Write-TestFile (Join-Path $script:src 'suite.settings.json') 'old'
        Write-TestFile (Join-Path $script:dst 'suite.settings.json') 'new'
        Write-TestFile (Join-Path $script:src 'suite.windowstate.json') 'state'
        Write-TestFile (Join-Path $script:src 'same.json') 'same'
        Write-TestFile (Join-Path $script:dst 'same.json') 'same'
        Write-TestFile (Join-Path $script:src 'Logs\launcher.log') 'log'
        Write-TestFile (Join-Path $script:src 'Logs\deep\more [1].log') 'deep'
        Write-TestFile (Join-Path $script:dst 'start-suite.ps1') 'shipped'

        $result = Invoke-Merge -Source $script:src -Destination $script:dst

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:src | Should -BeFalse
        Read-TestFile (Join-Path $script:dst 'suite.settings.json') | Should -Be 'new'
        $kept = Join-Path $script:dst "legacy\suite-core's [old]"
        Read-TestFile (Join-Path $kept 'suite.settings.json') | Should -Be 'old'
        Test-Path -LiteralPath (Join-Path $kept 'same.json') | Should -BeFalse
        Read-TestFile (Join-Path $script:dst 'suite.windowstate.json') | Should -Be 'state'
        Read-TestFile (Join-Path $script:dst 'Logs\launcher.log') | Should -Be 'log'
        Read-TestFile (Join-Path $script:dst 'Logs\deep\more [1].log') | Should -Be 'deep'
        Read-TestFile (Join-Path $script:dst 'start-suite.ps1') | Should -Be 'shipped'
        $result.Output | Should -Match 'Conflict: suite\.settings\.json'
    }

    It 'leaves the old folder and every unmoved file in place when a move fails, then finishes on the next run' {
        Write-TestFile (Join-Path $script:src 'suite.settings.json') 'old'
        Write-TestFile (Join-Path $script:dst 'suite.settings.json') 'new'
        Write-TestFile (Join-Path $script:src 'only-old.json') 'only'
        $held = Join-Path $script:src 'Logs\held.log'
        Write-TestFile $held 'held'
        $script:lock = [IO.File]::Open($held, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)

        $first = Invoke-Merge -Source $script:src -Destination $script:dst

        $first.ExitCode | Should -Be 2
        Test-Path -LiteralPath $held | Should -BeTrue
        Test-Path -LiteralPath $script:src | Should -BeTrue
        Read-TestFile (Join-Path $script:dst 'only-old.json') | Should -Be 'only'
        Read-TestFile (Join-Path $script:dst "legacy\suite-core's [old]\suite.settings.json") | Should -Be 'old'
        Test-Path -LiteralPath (Join-Path $script:dst 'Logs\held.log') | Should -BeFalse

        $script:lock.Dispose(); $script:lock = $null
        $second = Invoke-Merge -Source $script:src -Destination $script:dst

        $second.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:src | Should -BeFalse
        Read-TestFile (Join-Path $script:dst 'Logs\held.log') | Should -Be 'held'
        Read-TestFile (Join-Path $script:dst "legacy\suite-core's [old]\suite.settings.json") | Should -Be 'old'
    }

    It 'does not overwrite a conflict copy that an earlier run kept' {
        Write-TestFile (Join-Path $script:dst 'suite.settings.json') 'new'
        Write-TestFile (Join-Path $script:dst "legacy\suite-core's [old]\suite.settings.json") 'first'
        Write-TestFile (Join-Path $script:src 'suite.settings.json') 'second'

        (Invoke-Merge -Source $script:src -Destination $script:dst).ExitCode | Should -Be 0

        Read-TestFile (Join-Path $script:dst "legacy\suite-core's [old]\suite.settings.json") | Should -Be 'first'
        Read-TestFile (Join-Path $script:dst "legacy\suite-core's [old]\suite.settings.json.1") | Should -Be 'second'
    }

    It 'treats a missing source folder as nothing to merge' {
        Remove-Item -LiteralPath $script:src -Recurse -Force
        (Invoke-Merge -Source $script:src -Destination $script:dst).ExitCode | Should -Be 0
    }

    It 'refuses a missing destination folder and keeps the source' {
        Write-TestFile (Join-Path $script:src 'suite.settings.json') 'old'
        Remove-Item -LiteralPath $script:dst -Recurse -Force
        (Invoke-Merge -Source $script:src -Destination $script:dst).ExitCode | Should -Be 2
        Read-TestFile (Join-Path $script:src 'suite.settings.json') | Should -Be 'old'
    }
}

Describe 'Suite installer upgrade over a renamed folder that already has its replacement' -Skip:(-not $script:HasNsis) {
    BeforeAll {
        $script:MakeNsis = 'C:\Program Files (x86)\NSIS\makensis.exe'
        $buildScript = Join-Path $script:RepoRoot 'tools\build-suite-installer.ps1'

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-ComponentsInclude' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
        $assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$FolderRenames', '$RetiredComponents', '$RetiredShortcuts' }, $true)
        foreach ($a in $assign) { . ([scriptblock]::Create($a.Extent.Text)) }

        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('suite-rename-' + [Guid]::NewGuid().ToString('N'))
        $stage = Join-Path $script:work 'stage'
        $script:inst = Join-Path $script:work 'inst'
        New-Item -ItemType Directory -Path $stage, $script:inst -Force | Out-Null

        $table = @(
            [pscustomobject]@{ Folder = 'app-packager-suite'; Entry = 'start-suite.ps1';       Shortcut = 'Fixture Rename Launcher'; Icon = 'assets\apppackager-suite.ico' }
            [pscustomobject]@{ Folder = 'site-hygiene';       Entry = 'start-sitehygiene.ps1'; Shortcut = 'Fixture Rename Site Hygiene' }
        )
        foreach ($c in $table) {
            $dir = Join-Path $stage $c.Folder
            New-Item -ItemType Directory -Path (Join-Path $dir 'Module') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir $c.Entry) -Value '# shipped' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'Module\fixture.psm1') -Value '# fixture' -Encoding ASCII
        }
        New-Item -ItemType Directory -Path (Join-Path $stage 'app-packager-suite\assets') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'assets\apppackager-suite.ico') -Destination (Join-Path $stage 'app-packager-suite\assets\apppackager-suite.ico')
        '{ "suite": "fixture" }' | Set-Content -LiteralPath (Join-Path $stage 'suite-manifest.json') -Encoding ASCII
        Write-ComponentsInclude -Table $table -Path (Join-Path $stage 'components.nsh') -Renames $FolderRenames -Retired $RetiredComponents -RetiredShortcuts $RetiredShortcuts

        $script:suiteName = 'AppPackager Suite Rename Fixture ' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:suiteKey = 'AppPackagerSuiteRenameFixture'
        $script:exe = Join-Path $script:work 'SuiteSetup-fixture.exe'
        $out = & $script:MakeNsis '/V2' '/DSUITEVERSION=0.0.0' "/DPAYLOADDIR=$stage" "/DOUTFILE=$($script:exe)" "/DSUITE_NAME=$($script:suiteName)" "/DSUITE_KEY=$($script:suiteKey)" (Join-Path $script:RepoRoot 'installer\suite.nsi') 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('makensis failed: ' + ($out -join "`n")) }

        $script:startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $script:suiteName
        $script:arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:suiteKey

        function Invoke-FixtureInstall {
            $p = Start-Process -FilePath $script:exe -ArgumentList @('/S', ('/D=' + $script:inst)) -Wait -PassThru
            $p.ExitCode
        }

        # An earlier install left suite-core with user state; a later partial
        # install created app-packager-suite with its own settings.
        $old = Join-Path $script:inst 'suite-core'
        $new = Join-Path $script:inst 'app-packager-suite'
        foreach ($pair in @(
                @((Join-Path $old 'suite.settings.json'), '{ "SiteCode": "OLD" }'),
                @((Join-Path $old 'suite.windowstate.json'), '{ "Left": 5 }'),
                @((Join-Path $old 'Logs\launcher.log'), 'old log'),
                @((Join-Path $old 'Logs\held.log'), 'held log'),
                @((Join-Path $old 'Reports\nested\report.csv'), 'report'),
                @((Join-Path $old 'start-suite.ps1'), '# old shipped'),
                @((Join-Path $new 'suite.settings.json'), '{ "SiteCode": "NEW" }'))) {
            $dir = Split-Path -Parent $pair[0]
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -LiteralPath $pair[0] -Value $pair[1] -Encoding ASCII
        }

        $held = Join-Path $old 'Logs\held.log'
        $lock = [IO.File]::Open($held, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { $script:firstExit = Invoke-FixtureInstall }
        finally { $lock.Dispose() }
        $script:afterFirst = [pscustomobject]@{
            OldExists   = Test-Path -LiteralPath $old
            HeldInOld   = Test-Path -LiteralPath $held
            HeldInNew   = Test-Path -LiteralPath (Join-Path $new 'Logs\held.log')
            OldLogMoved = Test-Path -LiteralPath (Join-Path $new 'Logs\launcher.log')
        }

        $script:secondExit = Invoke-FixtureInstall
        $read = { param($rel) $f = Join-Path $script:inst $rel; if (Test-Path -LiteralPath $f) { (Get-Content -LiteralPath $f -Raw).Trim() } else { $null } }
        $script:afterSecond = [pscustomobject]@{
            OldExists    = Test-Path -LiteralPath $old
            Held         = & $read 'app-packager-suite\Logs\held.log'
            Report       = & $read 'app-packager-suite\Reports\nested\report.csv'
            WindowState  = & $read 'app-packager-suite\suite.windowstate.json'
            Settings     = & $read 'app-packager-suite\suite.settings.json'
            KeptSettings = & $read 'app-packager-suite\legacy\suite-core\suite.settings.json'
        }

        # Third run: only the old folder exists, so the plain rename runs.
        Remove-Item -LiteralPath $new -Recurse -Force
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $old 'rename-only.json') -Value '{ "x": 1 }' -Encoding ASCII
        $script:thirdExit = Invoke-FixtureInstall
    }

    AfterAll {
        if ($script:inst) {
            $un = Join-Path $script:inst 'Uninstall.exe'
            if (Test-Path -LiteralPath $un) {
                Start-Process -FilePath $un -ArgumentList @('/S', ('_?=' + $script:inst)) -Wait | Out-Null
            }
        }
        if ($script:arpKey) { Remove-Item -LiteralPath $script:arpKey -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:startMenu) { Remove-Item -LiteralPath $script:startMenu -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'generates a merge step instead of a JSON-only move' {
        $nsh = Get-Content -LiteralPath (Join-Path $script:work 'stage\components.nsh') -Raw
        $nsh | Should -Match 'merge-user-folder\.ps1'
        $nsh | Should -Not -Match 'FindFirst \$0 \$1 ".*suite-core\\\*\.json"'
        $nsh | Should -Not -Match 'RMDir /r "\$INSTDIR\\suite-core"'
    }

    It 'installs when a file in the old folder cannot move, and keeps that file and its folder' {
        $script:firstExit | Should -Be 0
        $script:afterFirst.OldExists | Should -BeTrue
        $script:afterFirst.HeldInOld | Should -BeTrue
        $script:afterFirst.HeldInNew | Should -BeFalse
        $script:afterFirst.OldLogMoved | Should -BeTrue
    }

    It 'finishes the merge on the next run and removes the old folder' {
        $script:secondExit | Should -Be 0
        $script:afterSecond.OldExists | Should -BeFalse
        $script:afterSecond.Held | Should -Be 'held log'
        $script:afterSecond.Report | Should -Be 'report'
        $script:afterSecond.WindowState | Should -Match '"Left": 5'
    }

    It 'keeps the current settings file and preserves the conflicting old one' {
        $script:afterSecond.Settings | Should -Match 'NEW'
        $script:afterSecond.KeptSettings | Should -Match 'OLD'
    }

    It 'still renames the old folder when no replacement exists' {
        $script:thirdExit | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:inst 'suite-core') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $script:inst 'app-packager-suite\rename-only.json') -Raw) | Should -Match '"x": 1'
    }
}
