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
        $assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$RetiredComponents', '$RetiredShortcuts', '$ExternalUserData' }, $true)
        foreach ($a in $assign) { . ([scriptblock]::Create($a.Extent.Text)) }

        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('suite-upgrade-' + [Guid]::NewGuid().ToString('N'))
        $stage = Join-Path $script:work 'stage'
        $script:inst = Join-Path $script:work 'inst'
        New-Item -ItemType Directory -Path $stage, $script:inst -Force | Out-Null

        # Two tiny components stand in for the payload.
        $table = @(
            [pscustomobject]@{ Folder = 'app-packager-suite'; Entry = 'start-suite.ps1';       Shortcut = 'Fixture Launcher'; Icon = 'assets\apppackager-suite.ico' }
            [pscustomobject]@{ Folder = 'site-hygiene';       Entry = 'start-sitehygiene.ps1'; Shortcut = 'Fixture Site Hygiene' }
        )
        foreach ($c in $table) {
            $dir = Join-Path $stage $c.Folder
            New-Item -ItemType Directory -Path (Join-Path $dir 'Module') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir $c.Entry) -Value '# fixture' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'Module\fixture.psm1') -Value '# fixture' -Encoding ASCII
        }
        # suite.nsi takes the setup icon from the suite component's assets folder.
        New-Item -ItemType Directory -Path (Join-Path $stage 'app-packager-suite\assets') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\apppackager-suite.ico') -Destination (Join-Path $stage 'app-packager-suite\assets\apppackager-suite.ico')
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
        $script:nsh | Should -Match 'retire-component\.ps1'
        $script:nsh | Should -Match 'SUITE_RETIRE_SRC", t "\$INSTDIR\\mecm-health-dashboard"'
        $script:nsh | Should -Match 'SUITE_RETIRE_SRC", t "\$INSTDIR\\supersedence-auditor"'
        $script:nsh | Should -Match 'SUITE_RETIRE_LEGACY", t "\$INSTDIR\\site-hygiene\\legacy"'
        # No recursive delete of a retired folder: the merge script removes it when empty.
        $retire = [regex]::Match($script:nsh, '(?s)!macro SUITE_RETIRE_COMPONENTS.*?!macroend').Value
        $retire | Should -Not -BeNullOrEmpty
        $retire | Should -Not -Match 'RMDir'
        $script:nsh | Should -Match 'Delete "\$StartMenuDir\\ConfigMgr Health Dashboard\.lnk"'
        # The launcher shortcut carries the suite icon; the other shortcut does not.
        $script:nsh | Should -Match ([regex]::Escape('start-suite.ps1"'' "$INSTDIR\app-packager-suite\assets\apppackager-suite.ico" 0'))
        $script:nsh | Should -Not -Match 'start-sitehygiene\.ps1"'' "'
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

Describe 'Suite installer data safety: retire twice, conflicts, edited templates, uninstall' -Skip:(-not $script:HasNsis) {
    BeforeAll {
        $script:MakeNsis = 'C:\Program Files (x86)\NSIS\makensis.exe'
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $buildScript = Join-Path $repoRoot 'tools\build-suite-installer.ps1'

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$null, [ref]$null)
        foreach ($name in 'Write-ComponentsInclude', 'Move-DefaultFolder') {
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        $assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$RetiredComponents', '$RetiredShortcuts', '$ExternalUserData', '$DefaultFolders' }, $true)
        foreach ($a in $assign) { . ([scriptblock]::Create($a.Extent.Text)) }

        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('suite-datasafety-' + [Guid]::NewGuid().ToString('N'))
        $script:inst = Join-Path $script:work 'inst'
        New-Item -ItemType Directory -Path $script:inst -Force | Out-Null
        $script:suiteName = 'AppPackager Suite DataSafety ' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:suiteKey = 'AppPackagerSuiteDataSafetyFixture'
        $script:arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:suiteKey
        $script:startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $script:suiteName

        # One build per payload version. The payload has a launcher, site-hygiene,
        # and collection-manager with two tracked templates.
        function New-DataFixtureInstaller {
            param([string]$Tag, [string]$TemplateA, [string]$TemplateB)
            $stage = Join-Path $script:work ('stage-' + $Tag)
            $table = @(
                [pscustomobject]@{ Folder = 'app-packager-suite'; Entry = 'start-suite.ps1';             Shortcut = 'Fixture Launcher'; Icon = 'assets\apppackager-suite.ico' }
                [pscustomobject]@{ Folder = 'site-hygiene';       Entry = 'start-sitehygiene.ps1';       Shortcut = 'Fixture Site Hygiene' }
                [pscustomobject]@{ Folder = 'collection-manager'; Entry = 'start-collectionmanager.ps1'; Shortcut = 'Fixture Collection Manager' }
            )
            foreach ($c in $table) {
                $dir = Join-Path $stage $c.Folder
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $dir $c.Entry) -Value ('# fixture ' + $Tag) -Encoding ASCII
            }
            New-Item -ItemType Directory -Path (Join-Path $stage 'app-packager-suite\assets') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\apppackager-suite.ico') -Destination (Join-Path $stage 'app-packager-suite\assets\apppackager-suite.ico')
            $tpl = Join-Path $stage 'collection-manager\Templates'
            New-Item -ItemType Directory -Path $tpl -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tpl 'a.json') -Value $TemplateA -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tpl 'b.json') -Value $TemplateB -Encoding ASCII
            '{ "suite": "fixture" }' | Set-Content -LiteralPath (Join-Path $stage 'suite-manifest.json') -Encoding ASCII
            $null = Move-DefaultFolder -StageRoot $stage -Table $table -Folders $DefaultFolders
            Write-ComponentsInclude -Table $table -Path (Join-Path $stage 'components.nsh') -Retired $RetiredComponents -RetiredShortcuts $RetiredShortcuts -ExternalData $ExternalUserData
            $exe = Join-Path $script:work ('SuiteSetup-' + $Tag + '.exe')
            $out = & $script:MakeNsis '/V2' "/DSUITEVERSION=0.0.$Tag" "/DPAYLOADDIR=$stage" "/DOUTFILE=$exe" "/DSUITE_NAME=$($script:suiteName)" "/DSUITE_KEY=$($script:suiteKey)" (Join-Path $repoRoot 'installer\suite.nsi') 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('makensis failed: ' + ($out -join "`n")) }
            return $exe
        }
        function Invoke-Setup {
            param([string]$Exe)
            $p = Start-Process -FilePath $Exe -ArgumentList @('/S', ('/D=' + $script:inst)) -Wait -PassThru
            return $p.ExitCode
        }
        function Get-Digest { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

        $script:exe1 = New-DataFixtureInstaller -Tag '1' -TemplateA '{ "v": 1, "a": true }' -TemplateB '{ "v": 1, "b": true }'
        $script:exe2 = New-DataFixtureInstaller -Tag '2' -TemplateA '{ "v": 2, "a": true }' -TemplateB '{ "v": 2, "b": true }'

        # Earlier state: a retired folder with data outside the old lists, a
        # legacy folder that already holds a different History\h1.json, and an
        # archive from an earlier run.
        $script:legacyRoot = Join-Path $script:inst 'site-hygiene\legacy'
        $dash = Join-Path $script:inst 'mecm-health-dashboard'
        foreach ($d in 'History', 'Custom') { New-Item -ItemType Directory -Path (Join-Path $dash $d) -Force | Out-Null }
        'old h1' | Set-Content -LiteralPath (Join-Path $dash 'History\h1.json') -Encoding ASCII
        'mine' | Set-Content -LiteralPath (Join-Path $dash 'notes.txt') -Encoding ASCII
        'keep' | Set-Content -LiteralPath (Join-Path $dash 'Custom\keep.txt') -Encoding ASCII
        New-Item -ItemType Directory -Path (Join-Path $script:legacyRoot 'mecm-health-dashboard\History') -Force | Out-Null
        'existing h1' | Set-Content -LiteralPath (Join-Path $script:legacyRoot 'mecm-health-dashboard\History\h1.json') -Encoding ASCII
        'earlier archive' | Set-Content -LiteralPath (Join-Path $script:legacyRoot 'mecm-health-dashboard.zip') -Encoding ASCII
        $script:earlierZipHash = Get-Digest (Join-Path $script:legacyRoot 'mecm-health-dashboard.zip')

        $script:exit1 = Invoke-Setup -Exe $script:exe1
        $script:zipsAfterFirst = @(Get-ChildItem -LiteralPath $script:legacyRoot -Filter 'mecm-health-dashboard*.zip' | ForEach-Object Name)

        # Second retire of the same folder (A-1): it comes back with new files.
        New-Item -ItemType Directory -Path (Join-Path $dash 'History') -Force | Out-Null
        'h2' | Set-Content -LiteralPath (Join-Path $dash 'History\h2.json') -Encoding ASCII
        'mine 2' | Set-Content -LiteralPath (Join-Path $dash 'notes2.txt') -Encoding ASCII
        $script:exit2 = Invoke-Setup -Exe $script:exe1
        $script:zipsAfterSecond = @(Get-ChildItem -LiteralPath $script:legacyRoot -Filter 'mecm-health-dashboard*.zip' | ForEach-Object Name)

        # Edited and added templates, then the upgrade to a payload with new defaults (A-3).
        $script:tplDir = Join-Path $script:inst 'collection-manager\Templates'
        if (-not (Test-Path -LiteralPath (Join-Path $script:tplDir 'a.json'))) { throw ('DBG listing: ' + ((Get-ChildItem $script:inst -Recurse -File | ForEach-Object FullName) -join ' ; ') + ' LOGS: ' + ((Get-ChildItem $env:TEMP -Filter 'ud-dbg-*.log' | ForEach-Object { Get-Content $_.FullName -Raw }) -join ' ## ')) }
        $script:templatesAfterFirstInstall = @((Get-Content -LiteralPath (Join-Path $script:tplDir 'a.json') -Raw), (Get-Content -LiteralPath (Join-Path $script:tplDir 'b.json') -Raw))
        'USER EDIT' | Set-Content -LiteralPath (Join-Path $script:tplDir 'b.json') -Encoding ASCII
        'user template' | Set-Content -LiteralPath (Join-Path $script:tplDir 'mine.json') -Encoding ASCII
        $script:exit3 = Invoke-Setup -Exe $script:exe2
        $script:templatesAfterUpgrade = @((Get-Content -LiteralPath (Join-Path $script:tplDir 'a.json') -Raw), (Get-Content -LiteralPath (Join-Path $script:tplDir 'b.json') -Raw), (Get-Content -LiteralPath (Join-Path $script:tplDir 'b.json.new') -Raw))

        # Silent uninstall.
        $un = Join-Path $script:inst 'Uninstall.exe'
        $p = Start-Process -FilePath $un -ArgumentList @('/S', ('_?=' + $script:inst)) -Wait -PassThru
        $script:uninstallExit = $p.ExitCode
        $script:arpAfterUninstall = Test-Path -LiteralPath $script:arpKey
        $script:nsh = Get-Content -LiteralPath (Join-Path $script:work 'stage-2\components.nsh') -Raw
    }

    AfterAll {
        if ($script:arpKey) { Remove-Item -LiteralPath $script:arpKey -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:startMenu) { Remove-Item -LiteralPath $script:startMenu -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'installs and upgrades silently' {
        $script:exit1 | Should -Be 0
        $script:exit2 | Should -Be 0
        $script:exit3 | Should -Be 0
    }

    It 'A-1: never overwrites an earlier archive; each retire adds a new zip' {
        (Get-FileHash -LiteralPath (Join-Path $script:legacyRoot 'mecm-health-dashboard.zip') -Algorithm SHA256).Hash | Should -Be $script:earlierZipHash
        $script:zipsAfterFirst.Count | Should -Be 2
        $script:zipsAfterSecond.Count | Should -Be 3
        $script:zipsAfterSecond | Should -Contain 'mecm-health-dashboard.zip'
    }

    It 'A-1: the second archive holds the files of the returned folder' {
        $second = @($script:zipsAfterSecond | Where-Object { $_ -notin $script:zipsAfterFirst })
        $second.Count | Should -Be 1
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $script:legacyRoot $second[0]))
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $archive.Dispose() }
        $names | Should -Contain 'mecm-health-dashboard/notes2.txt'
        $names | Should -Contain 'mecm-health-dashboard/History/h2.json'
    }

    It 'A-2: files outside the old json and folder lists are merged, not deleted' {
        $merged = Join-Path $script:legacyRoot 'mecm-health-dashboard'
        Get-Content -LiteralPath (Join-Path $merged 'notes.txt') -Raw | Should -Match 'mine'
        Get-Content -LiteralPath (Join-Path $merged 'Custom\keep.txt') -Raw | Should -Match 'keep'
        Get-Content -LiteralPath (Join-Path $merged 'notes2.txt') -Raw | Should -Match 'mine 2'
        Test-Path -LiteralPath (Join-Path $script:inst 'mecm-health-dashboard') | Should -BeFalse
    }

    It 'A-2: a differing file already in legacy is kept, and the old copy is kept beside it' {
        $merged = Join-Path $script:legacyRoot 'mecm-health-dashboard'
        Get-Content -LiteralPath (Join-Path $merged 'History\h1.json') -Raw | Should -Match 'existing h1'
        $holders = @(Get-ChildItem -LiteralPath $merged -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'old h1' })
        $holders.Count | Should -Be 1
    }

    It 'A-3: places the default templates on a fresh install' {
        $script:templatesAfterFirstInstall[0] | Should -Match '"v": 1'
        $script:templatesAfterFirstInstall[1] | Should -Match '"v": 1'
    }

    It 'A-3: an upgrade replaces an untouched template with the new default' {
        $script:templatesAfterUpgrade[0] | Should -Match '"v": 2'
    }

    It 'A-3: an upgrade keeps an edited template and a user template, and writes the new default beside the edit' {
        $script:templatesAfterUpgrade[1] | Should -Match 'USER EDIT'
        $script:templatesAfterUpgrade[2] | Should -Match '"v": 2'
        Get-Content -LiteralPath (Join-Path $script:tplDir 'mine.json') -Raw | Should -Match 'user template'
    }

    It 'A-3: uninstall deletes the untouched template and keeps the edited and user templates' {
        $script:uninstallExit | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:tplDir 'a.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:tplDir 'b.json.new') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:tplDir 'b.json') -Raw | Should -Match 'USER EDIT'
        Get-Content -LiteralPath (Join-Path $script:tplDir 'mine.json') -Raw | Should -Match 'user template'
        Test-Path -LiteralPath (Join-Path $script:inst 'suite-defaults.json') | Should -BeFalse
    }

    It 'A-5: a silent uninstall keeps all user data and the legacy tree' {
        Test-Path -LiteralPath (Join-Path $script:legacyRoot 'mecm-health-dashboard\notes.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:legacyRoot 'mecm-health-dashboard.zip') | Should -BeTrue
        $script:arpAfterUninstall | Should -BeFalse
    }

    It 'A-5: the generated uninstall code reports what stays and removes data only by folder' {
        $script:nsh | Should -Match '!macro SUITE_REPORT_KEPT'
        $script:nsh | Should -Match 'DetailPrint "Kept: \$INSTDIR\\site-hygiene"'
        $script:nsh | Should -Match 'DetailPrint "Kept \(shared or outside the suite folder\): \$LOCALAPPDATA\\DetectionTester"'
        $remove = [regex]::Match($script:nsh, '(?s)!macro SUITE_REMOVE_USER_DATA.*?!macroend').Value
        $remove | Should -Match 'RMDir /r "\$INSTDIR\\site-hygiene"'
        $remove | Should -Match 'RMDir /r "\$INSTDIR\\mecm-health-dashboard"'
        # Never the install root itself.
        $remove | Should -Not -Match 'RMDir /r "\$INSTDIR"'
    }

    It 'A-5: the uninstaller asks only through a page that a silent run skips, default off' {
        $nsi = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\suite.nsi') -Raw
        $nsi | Should -Match 'UninstPage custom un\.DataPageShow un\.DataPageLeave'
        $nsi | Should -Match 'StrCpy \$RemoveData 0'
        $nsi | Should -Match '\$\{NSD_SetState\} \$RemoveCheck \$\{BST_UNCHECKED\}'
    }
}
