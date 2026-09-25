#Requires -Modules Pester

<#
.SYNOPSIS
    Builds a fixture installer from tools\build-suite-installer.ps1's own
    generator and runs it over a fake earlier install to verify the
    upgrade paths: retired components, retired shortcuts, user state.

.DESCRIPTION
    Skipped when makensis.exe is absent. The fixture installs under a
    temporary folder with its own Start Menu folder and ARP key
    (SUITE_NAME and SUITE_KEY overrides), then uninstalls, so nothing of
    the real suite install is touched.
#>

BeforeDiscovery {
    $script:MakeNsis = 'C:\Program Files (x86)\NSIS\makensis.exe'
    $script:HasNsis = Test-Path -LiteralPath $script:MakeNsis
}

Describe 'Suite installer upgrade over a retired component' -Skip:(-not $script:HasNsis) {
    BeforeAll {
        # Discovery-phase variables do not reach the run phase.
        $script:MakeNsis = 'C:\Program Files (x86)\NSIS\makensis.exe'
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $buildScript = Join-Path $repoRoot 'tools\build-suite-installer.ps1'

        # The generator and the tables live inside the build script; lift them
        # out of its AST instead of running the whole build.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-ComponentsInclude' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
        $assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$RetiredComponents', '$RetiredShortcuts' }, $true)
        foreach ($a in $assign) { . ([scriptblock]::Create($a.Extent.Text)) }

        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('suite-upgrade-' + [Guid]::NewGuid().ToString('N'))
        $stage = Join-Path $script:work 'stage'
        $script:inst = Join-Path $script:work 'inst'
        New-Item -ItemType Directory -Path $stage, $script:inst -Force | Out-Null

        # Two tiny components stand in for the payload.
        $table = @(
            [pscustomobject]@{ Folder = 'app-packager-suite'; Entry = 'start-suite.ps1';       Shortcut = 'Fixture Launcher' }
            [pscustomobject]@{ Folder = 'site-hygiene';       Entry = 'start-sitehygiene.ps1'; Shortcut = 'Fixture Site Hygiene' }
        )
        foreach ($c in $table) {
            $dir = Join-Path $stage $c.Folder
            New-Item -ItemType Directory -Path (Join-Path $dir 'Module') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir $c.Entry) -Value '# fixture' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'Module\fixture.psm1') -Value '# fixture' -Encoding ASCII
        }
        '{ "suite": "fixture" }' | Set-Content -LiteralPath (Join-Path $stage 'suite-manifest.json') -Encoding ASCII
        Write-ComponentsInclude -Table $table -Path (Join-Path $stage 'components.nsh') -Retired $RetiredComponents -RetiredShortcuts $RetiredShortcuts
        $script:nsh = Get-Content -LiteralPath (Join-Path $stage 'components.nsh') -Raw

        $script:suiteName = 'AppPackager Suite Fixture ' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:suiteKey  = 'AppPackagerSuiteFixture'
        $script:exe = Join-Path $script:work 'SuiteSetup-fixture.exe'
        $out = & $script:MakeNsis '/V2' "/DSUITEVERSION=0.0.0" "/DPAYLOADDIR=$stage" "/DOUTFILE=$($script:exe)" "/DSUITE_NAME=$($script:suiteName)" "/DSUITE_KEY=$($script:suiteKey)" (Join-Path $repoRoot 'installer\suite.nsi') 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('makensis failed: ' + ($out -join "`n")) }

        # The earlier install: both retired components with shipped files,
        # user files, and one unlisted file in the dashboard folder; a
        # site-hygiene folder with its own preferences; retired shortcuts.
        $dash = Join-Path $script:inst 'mecm-health-dashboard'
        foreach ($d in 'Lib', 'Module', 'screenshots', 'History', 'Logs', 'Reports') { New-Item -ItemType Directory -Path (Join-Path $dash $d) -Force | Out-Null }
        foreach ($f in 'start-mecmhealthdashboard.ps1', 'MainWindow.xaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'Lib\MahApps.Metro.dll', 'Module\MECMHealthDashCommon.psm1', 'screenshots\main-dark.png') {
            Set-Content -LiteralPath (Join-Path $dash $f) -Value 'shipped' -Encoding ASCII
        }
        '{ "SQLServer": "sql01" }' | Set-Content -LiteralPath (Join-Path $dash 'MECMHealthDash.prefs.json') -Encoding ASCII
        '{ "Left": 1 }' | Set-Content -LiteralPath (Join-Path $dash 'MECMHealthDash.windowstate.json') -Encoding ASCII
        'Timestamp' | Set-Content -LiteralPath (Join-Path $dash 'History\metrics-history.csv') -Encoding ASCII
        'log' | Set-Content -LiteralPath (Join-Path $dash 'Logs\HealthDash-1.log') -Encoding ASCII
        'csv' | Set-Content -LiteralPath (Join-Path $dash 'Reports\r.csv') -Encoding ASCII
        'mine' | Set-Content -LiteralPath (Join-Path $dash 'notes.txt') -Encoding ASCII

        $aud = Join-Path $script:inst 'supersedence-auditor'
        foreach ($d in 'Lib', 'Module', 'screenshots') { New-Item -ItemType Directory -Path (Join-Path $aud $d) -Force | Out-Null }
        foreach ($f in 'start-supersedenceauditor.ps1', 'MainWindow.xaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'Lib\MahApps.Metro.dll', 'Module\SupersedenceAuditorCommon.psm1', 'screenshots\main-dark.png') {
            Set-Content -LiteralPath (Join-Path $aud $f) -Value 'shipped' -Encoding ASCII
        }
        '{ "SiteCode": "MCM" }' | Set-Content -LiteralPath (Join-Path $aud 'SupersedenceAuditor.prefs.json') -Encoding ASCII

        $hyg = Join-Path $script:inst 'site-hygiene'
        New-Item -ItemType Directory -Path $hyg -Force | Out-Null
        '{ "SiteCode": "XYZ" }' | Set-Content -LiteralPath (Join-Path $hyg 'SiteHygiene.prefs.json') -Encoding ASCII

        $script:startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $script:suiteName
        New-Item -ItemType Directory -Path $script:startMenu -Force | Out-Null
        foreach ($old in $RetiredShortcuts) { Set-Content -LiteralPath (Join-Path $script:startMenu ($old + '.lnk')) -Value 'old' -Encoding ASCII }

        # /D must be the last argument and unquoted.
        $p = Start-Process -FilePath $script:exe -ArgumentList @('/S', ('/D=' + $script:inst)) -Wait -PassThru
        $script:installExit = $p.ExitCode
        $script:arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:suiteKey
    }

    AfterAll {
        # Every step is guarded so a setup failure still leaves no fixture behind.
        if ($script:inst) {
            $un = Join-Path $script:inst 'Uninstall.exe'
            if (Test-Path -LiteralPath $un) {
                # _?= keeps the uninstaller from copying itself to TEMP so -Wait waits for the real run.
                Start-Process -FilePath $un -ArgumentList @('/S', ('_?=' + $script:inst)) -Wait | Out-Null
            }
            $script:legacyAfterUninstall = Test-Path -LiteralPath (Join-Path $script:inst 'site-hygiene\legacy\mecm-health-dashboard\MECMHealthDash.prefs.json')
        }
        if ($script:arpKey) {
            $script:arpAfterUninstall = Test-Path -LiteralPath $script:arpKey
            Remove-Item -LiteralPath $script:arpKey -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:startMenu) { Remove-Item -LiteralPath $script:startMenu -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'generates a retire macro for every retired component' {
        $script:nsh | Should -Match '!macro SUITE_RETIRE_COMPONENTS'
        $script:nsh | Should -Match 'legacy\\mecm-health-dashboard'
        $script:nsh | Should -Match 'legacy\\supersedence-auditor'
        $script:nsh | Should -Match 'Delete "\$StartMenuDir\\ConfigMgr Health Dashboard\.lnk"'
    }

    It 'installs silently' {
        $script:installExit | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:inst 'site-hygiene\start-sitehygiene.ps1') | Should -BeTrue
        Test-Path -LiteralPath $script:arpKey | Should -BeTrue
    }

    It 'moves the dashboard json, history, logs, and reports under site-hygiene\legacy and removes the folder' {
        $legacy = Join-Path $script:inst 'site-hygiene\legacy\mecm-health-dashboard'
        Get-Content -LiteralPath (Join-Path $legacy 'MECMHealthDash.prefs.json') -Raw | Should -Match 'sql01'
        Test-Path -LiteralPath (Join-Path $legacy 'MECMHealthDash.windowstate.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $legacy 'History\metrics-history.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $legacy 'Logs\HealthDash-1.log') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $legacy 'Reports\r.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:inst 'mecm-health-dashboard') | Should -BeFalse
    }

    It 'archives the whole old folder to a zip before removing it' {
        $zip = Join-Path $script:inst 'site-hygiene\legacy\mecm-health-dashboard.zip'
        Test-Path -LiteralPath $zip | Should -BeTrue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $archive.Dispose() }
        $names | Should -Contain 'mecm-health-dashboard/notes.txt'
        $names | Should -Contain 'mecm-health-dashboard/start-mecmhealthdashboard.ps1'
        $names | Should -Contain 'mecm-health-dashboard/MECMHealthDash.prefs.json'
    }

    It 'removes the auditor folder and keeps its json in legacy' {
        Test-Path -LiteralPath (Join-Path $script:inst 'supersedence-auditor') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:inst 'site-hygiene\legacy\supersedence-auditor.zip') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:inst 'site-hygiene\legacy\supersedence-auditor\SupersedenceAuditor.prefs.json') -Raw | Should -Match 'MCM'
    }

    It 'leaves the site-hygiene preferences untouched' {
        Get-Content -LiteralPath (Join-Path $script:inst 'site-hygiene\SiteHygiene.prefs.json') -Raw | Should -Match 'XYZ'
    }

    It 'replaces the retired shortcuts with the current ones' {
        foreach ($old in $RetiredShortcuts) { Test-Path -LiteralPath (Join-Path $script:startMenu ($old + '.lnk')) | Should -BeFalse }
        Test-Path -LiteralPath (Join-Path $script:startMenu 'Fixture Site Hygiene.lnk') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:startMenu 'Fixture Launcher.lnk') | Should -BeTrue
    }

    It 'is idempotent: a second run over the migrated layout changes nothing and succeeds' {
        $p = Start-Process -FilePath $script:exe -ArgumentList @('/S', ('/D=' + $script:inst)) -Wait -PassThru
        $p.ExitCode | Should -Be 0
        Get-Content -LiteralPath (Join-Path $script:inst 'site-hygiene\legacy\mecm-health-dashboard\MECMHealthDash.prefs.json') -Raw | Should -Match 'sql01'
        Test-Path -LiteralPath (Join-Path $script:inst 'mecm-health-dashboard') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:inst 'site-hygiene\legacy\mecm-health-dashboard.zip') | Should -BeTrue
    }
}

Describe 'Suite installer upgrade: uninstall keeps legacy user files' -Skip:(-not $script:HasNsis) {
    It 'removes the ARP entry and keeps the migrated files' {
        # Set by the previous block's AfterAll, which runs the uninstaller.
        $script:arpAfterUninstall | Should -BeFalse
        $script:legacyAfterUninstall | Should -BeTrue
    }
}
