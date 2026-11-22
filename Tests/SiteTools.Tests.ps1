#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }

<#
.SYNOPSIS
    Tests of the site context of the launcher and the suite tools (Q-112f): Resolve-SuiteToolSite, the tool prefs split,
    the tool paths, the per-tool migration and the two-site isolation.

.DESCRIPTION
    Every test builds an old-layout profile in a temp folder (the tool folder beside the script holds the old prefs and
    data), a data root in the same temp folder, and runs the function under test. Site codes are fictional (AB1, CD2) and
    hosts are example.com. Nothing touches the real profile or the real data root. The launcher helpers are lifted out of
    start-suite.ps1 by their AST, because that file is a window script.
    Run: Invoke-Pester -Path .\Tests\SiteTools.Tests.ps1 -Output Detailed
#>

Describe 'Site context of the launcher and the tools' {
BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Get-Module SuiteCommon | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    $script:EnvNames = 'SUITE_CM_SITECODE', 'APP_PACKAGER_SITE', 'APP_PACKAGER_DATA_ROOT', 'SUITE_CM_PROVIDER'

    function Write-Seed {
        param([string]$Root, [string]$Relative, [string]$Text)
        $p = Join-Path $Root $Relative
        $d = Split-Path $p -Parent
        if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
    }
    function Get-TreeHash {
        param([string]$Root)
        $h = @{}
        if (Test-Path $Root) { foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) { $h[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } }
        return $h
    }
    function Assert-NoChange {
        param($Before, $After)
        foreach ($k in $Before.Keys) {
            $After.ContainsKey($k) | Should -BeTrue -Because "$k must still exist"
            $After[$k] | Should -Be $Before[$k] -Because "$k must keep its content"
        }
    }
    # An old Site Hygiene folder beside the script: prefs with global and site keys, scan files, history, reports.
    function New-OldHygiene {
        param([string]$Suite, [string]$SiteCode = 'AB1')
        $t = Join-Path $Suite 'site-hygiene'
        Write-Seed $t 'SiteHygiene.prefs.json' ('{"DarkMode":false,"SiteCode":"' + $SiteCode + '","SMSProvider":"cm01.example.com","SQLServer":"sql01.example.com","AlertToast":true}')
        Write-Seed $t 'SiteHygiene.lastscan.json' '{"scanned":"2026-11-20"}'
        Write-Seed $t 'SiteHygiene.suppressions.json' '{"suppressed":["OBJ-1"]}'
        Write-Seed $t 'History\metrics-history.csv' "date,count`n2026-11-20,3`n"
        Write-Seed $t 'Reports\hygiene-1.html' '<html>r</html>'
        Write-Seed $t 'Logs\SiteHygiene.log' 'global log'
        return $t
    }
    function Set-Active {
        param([string]$DataRoot, [string]$Folder)
        [void](Set-SuiteActiveSite -SiteCode $Folder -DataRoot $DataRoot)
    }
}

BeforeEach {
    $script:Saved = @{}
    foreach ($n in $script:EnvNames) { $script:Saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
    $script:Temp = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $script:Suite = Join-Path $script:Temp 'AppPackagerSuite'
    $script:Data = Join-Path $script:Temp 'Data'
    $script:Local = Join-Path $script:Temp 'Local'
    [void](New-Item -ItemType Directory -Path $script:Suite, $script:Data, $script:Local -Force)
}

AfterEach {
    foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:Saved[$n]) }
}

Context 'Site list, identity and active site' {
    It 'lists no site when the data root has none' {
        @(Get-SuiteSiteList -DataRoot $script:Data).Count | Should -Be 0
    }

    It 'creates site.json, lists the site, and keeps the provider order' {
        (Set-SuiteSiteIdentity -SiteCode 'ab1' -Provider 'cm01.example.com' -DataRoot $script:Data) | Should -Be 'AB1'
        (Set-SuiteSiteIdentity -SiteCode 'AB1' -Provider 'cm02.example.com' -DataRoot $script:Data) | Should -Be 'AB1'
        (Set-SuiteSiteIdentity -SiteCode 'AB1' -Provider 'CM01.example.com' -DataRoot $script:Data) | Should -Be 'AB1'
        $list = @(Get-SuiteSiteList -DataRoot $script:Data)
        $list.Count | Should -Be 1
        $list[0].FolderName | Should -Be 'AB1'
        $list[0].Providers | Should -Be @('CM01.example.com', 'cm02.example.com')
        $j = Get-Content -LiteralPath (Join-Path $script:Data 'sites\AB1\site.json') -Raw | ConvertFrom-Json
        $j.schemaVersion | Should -Be 1
        $j.siteCode | Should -Be 'AB1'
    }

    It 'refuses a bad or reserved site code and writes nothing' {
        (Set-SuiteSiteIdentity -SiteCode 'SMS' -DataRoot $script:Data) | Should -BeNullOrEmpty
        (Set-SuiteSiteIdentity -SiteCode 'AB' -DataRoot $script:Data) | Should -BeNullOrEmpty
        (Set-SuiteActiveSite -SiteCode 'A B' -DataRoot $script:Data) | Should -BeFalse
        Test-Path (Join-Path $script:Data 'sites') | Should -BeFalse
        Test-Path (Join-Path $script:Data 'active-site.json') | Should -BeFalse
    }

    It 'writes active-site.json that the contract reader accepts, and the file-only read ignores the environment' {
        Set-SuiteActiveSite -SiteCode 'CD2' -DataRoot $script:Data | Should -BeTrue
        (Get-SuiteActiveSite -DataRoot $script:Data).SiteCode | Should -Be 'CD2'
        $env:SUITE_CM_SITECODE = 'AB1'
        (Get-SuiteActiveSite -DataRoot $script:Data).SiteCode | Should -Be 'AB1'
        $f = Get-SuiteActiveSite -DataRoot $script:Data -IgnoreEnvironment
        $f.SiteCode | Should -Be 'CD2'
        $f.Source | Should -Be 'active-site.json'
    }

    It 'keeps a site.json that exists but cannot be read' {
        $dir = Join-Path $script:Data 'sites\AB1'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        [IO.File]::WriteAllText((Join-Path $dir 'site.json'), '{ not json')
        (Set-SuiteSiteIdentity -SiteCode 'AB1' -Provider 'cm01.example.com' -DataRoot $script:Data) | Should -BeNullOrEmpty
        (Get-Content (Join-Path $dir 'site.json') -Raw) | Should -Be '{ not json'
    }

    It 'ignores folders that are not valid site names' {
        [void](New-Item -ItemType Directory -Path (Join-Path $script:Data 'sites\notasite'), (Join-Path $script:Data 'sites\ab1') -Force)
        [void](Set-SuiteSiteIdentity -SiteCode 'EF3' -DataRoot $script:Data)
        $names = @(Get-SuiteSiteList -DataRoot $script:Data | ForEach-Object FolderName)
        $names | Should -Contain 'EF3'
        $names | Should -Not -Contain 'notasite'
        $names | Should -Not -Contain 'ab1'
    }
}

Context 'Resolve-SuiteToolSite' {
    It 'is not active when no source names a site' {
        $t = Join-Path $script:Suite 'site-hygiene'
        [void](New-Item -ItemType Directory -Path $t -Force)
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $r.Active | Should -BeFalse
        $r.Reason | Should -Match 'launcher'
        Test-Path (Join-Path $script:Data 'sites') | Should -BeFalse
    }

    It 'takes the site from active-site.json, copies the tool''s old site data once, and keeps every old file' {
        $t = New-OldHygiene -Suite $script:Suite
        Write-Seed $script:Suite 'device-inspector\DeviceInspector.prefs.json' '{"SiteCode":"AB1","SMSProvider":"cm01.example.com","LastDevice":"PC01"}'
        Write-Seed $script:Suite 'device-inspector\Reports\di-1.html' '<html>di</html>'
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $before = Get-TreeHash $script:Suite

        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -LegacyPrefsPath (Join-Path $t 'SiteHygiene.prefs.json') -DataRoot $script:Data -LocalRoot $script:Local
        $r.Active | Should -BeTrue
        $r.SiteFolder | Should -Be 'AB1'
        $r.SiteCode | Should -Be 'AB1'
        $r.Source | Should -Be 'active-site.json'
        $r.ToolFolder | Should -Be (Join-Path $script:Data 'sites\AB1\tools\site-hygiene')
        $r.Migration | Should -Be 'Migrated'
        $r.Provider | Should -Be 'cm01.example.com'

        $tf = $r.ToolFolder
        (Get-Content (Join-Path $tf 'prefs.json') -Raw | ConvertFrom-Json).SQLServer | Should -Be 'sql01.example.com'
        (Get-Content (Join-Path $tf 'prefs.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'DarkMode'
        Test-Path (Join-Path $tf 'lastscan.json') | Should -BeTrue
        Test-Path (Join-Path $tf 'suppressions.json') | Should -BeTrue
        Test-Path (Join-Path $tf 'history\metrics-history.csv') | Should -BeTrue
        Test-Path (Join-Path $tf 'reports\hygiene-1.html') | Should -BeTrue
        Test-Path (Join-Path $tf 'migrated.json') | Should -BeTrue
        # Only this tool was migrated.
        Test-Path (Join-Path $script:Data 'sites\AB1\tools\device-inspector') | Should -BeFalse
        # Old files stay and keep their content.
        Assert-NoChange -Before $before -After (Get-TreeHash $script:Suite)
    }

    It 'runs the migration once per tool: a second start copies nothing and does not touch the site files' {
        $t = New-OldHygiene -Suite $script:Suite
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $first = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $first.Migration | Should -Be 'Migrated'
        $siteBefore = Get-TreeHash (Join-Path $script:Data 'sites')
        Write-Seed $t 'Reports\hygiene-2.html' '<html>new old file</html>'
        $second = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $second.Migration | Should -Be 'done earlier'
        Test-Path (Join-Path $first.ToolFolder 'reports\hygiene-2.html') | Should -BeFalse
        Assert-NoChange -Before $siteBefore -After (Get-TreeHash (Join-Path $script:Data 'sites'))
    }

    It 'falls back to the SiteCode in the old prefs file when no site is chosen' {
        $t = New-OldHygiene -Suite $script:Suite -SiteCode 'CD2'
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -LegacyPrefsPath (Join-Path $t 'SiteHygiene.prefs.json') -DataRoot $script:Data -LocalRoot $script:Local
        $r.Active | Should -BeTrue
        $r.SiteFolder | Should -Be 'CD2'
        $r.Source | Should -Be 'prefs'
    }

    It 'falls back to the old paths for this session when the copy fails, and writes no marker' {
        $t = New-OldHygiene -Suite $script:Suite
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        # A file where the site folder must be: the copy cannot write site.json.
        [void](New-Item -ItemType Directory -Path (Join-Path $script:Data 'sites') -Force)
        [IO.File]::WriteAllText((Join-Path $script:Data 'sites\AB1'), 'not a folder')
        $before = Get-TreeHash $script:Suite
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $r.Active | Should -BeFalse
        $r.Migration | Should -Be 'Failed'
        $r.Reason | Should -Match 'old data location'
        Assert-NoChange -Before $before -After (Get-TreeHash $script:Suite)
    }

    It 'the file-only read ignores a stale environment, so a second switch in the launcher takes effect' {
        $t = New-OldHygiene -Suite $script:Suite
        [void](Set-SuiteSiteIdentity -SiteCode 'AB1' -Provider 'cm01.example.com' -DataRoot $script:Data)
        [void](Set-SuiteSiteIdentity -SiteCode 'CD2' -Provider 'cm02.example.com' -DataRoot $script:Data)
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $env:SUITE_CM_SITECODE = 'AB1'; $env:APP_PACKAGER_SITE = 'AB1'
        Set-Active -DataRoot $script:Data -Folder 'CD2'
        (Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local -NoMigration).SiteFolder | Should -Be 'AB1'
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local -NoMigration -IgnoreEnvironment
        $r.SiteFolder | Should -Be 'CD2'
        $r.Provider | Should -Be 'cm02.example.com'
    }

    It 'starts of several tools together copy each tool once and keep every journal entry' {
        $hy = New-OldHygiene -Suite $script:Suite
        Write-Seed $script:Suite 'device-inspector\DeviceInspector.prefs.json' '{"SiteCode":"AB1","SMSProvider":"cm01.example.com"}'
        Write-Seed $script:Suite 'device-inspector\Reports\di-1.html' '<html>di</html>'
        $di = Join-Path $script:Suite 'device-inspector'
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $a = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $hy -DataRoot $script:Data -LocalRoot $script:Local
        $b = Resolve-SuiteToolSite -Tool 'device-inspector' -ToolRoot $di -DataRoot $script:Data -LocalRoot $script:Local
        $a.Migration | Should -Be 'Migrated'
        $b.Migration | Should -Be 'Migrated'
        $journal = Get-Content (Join-Path $script:Data 'sites\AB1\migration.json') -Raw | ConvertFrom-Json
        $ids = @($journal.items | ForEach-Object id) | Sort-Object -Unique
        $ids | Should -Contain 'suite.site-hygiene'
        $ids | Should -Contain 'suite.device-inspector'
        @(Get-ChildItem (Join-Path $script:Data 'sites\AB1') -Recurse -File -Filter '*.tmp').Count | Should -Be 0
    }

    It 'does not copy old data of another site into the active site folder' {
        $t = New-OldHygiene -Suite $script:Suite -SiteCode 'AB1'
        Set-Active -DataRoot $script:Data -Folder 'CD2'
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $r.SiteFolder | Should -Be 'CD2'
        Test-Path (Join-Path $r.ToolFolder 'prefs.json') | Should -BeFalse
        # The prefs name AB1, so nothing of this tool (scan data, history, reports have no site field) goes into CD2.
        @(Get-ChildItem -LiteralPath $r.ToolFolder -Recurse -File | ForEach-Object Name) | Should -Be @('migrated.json')
        (Get-Content (Join-Path $script:Data 'sites\CD2\site.json') -Raw | ConvertFrom-Json).siteCode | Should -Be 'CD2'
    }

    It 'makes no copy for a reused site code (AB1~2)' {
        $t = New-OldHygiene -Suite $script:Suite
        Set-Active -DataRoot $script:Data -Folder 'AB1~2'
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $r.SiteFolder | Should -Be 'AB1~2'
        $r.SiteCode | Should -Be 'AB1'
        $r.Migration | Should -Match 'reused'
        Test-Path (Join-Path $script:Data 'sites\AB1~2\tools') | Should -BeFalse
    }

    It 'honors the environment over active-site.json' {
        $t = New-OldHygiene -Suite $script:Suite
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $env:SUITE_CM_SITECODE = 'CD2'
        $r = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local -NoMigration
        $r.SiteFolder | Should -Be 'CD2'
        $r.Source | Should -Be 'SUITE_CM_SITECODE'
    }

    It 'migrates the Pivots and Scripts sessions and its prefs from the local data folder' {
        $pivots = Join-Path $script:Local 'SignalRidgeLabs\PivotsAndScripts'
        Write-Seed $pivots 'preferences.json' '{"SiteCode":"AB1","SMSProvider":"cm01.example.com","ApproveAfterSubmit":true}'
        Write-Seed $pivots 'Sessions\s1.json' '{"ID":"s1","SiteCode":"AB1","Provider":"cm01.example.com"}'
        Write-Seed $pivots 'Sessions\s2.json' '{"ID":"s2","SiteCode":"CD2"}'
        $t = Join-Path $script:Suite 'pivots-and-scripts'
        [void](New-Item -ItemType Directory -Path $t -Force)
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $before = Get-TreeHash $pivots
        $r = Resolve-SuiteToolSite -Tool 'pivots-and-scripts' -ToolRoot $t -DataRoot $script:Data -LocalRoot $script:Local
        $r.Active | Should -BeTrue
        Test-Path (Join-Path $r.ToolFolder 'sessions\s1.json') | Should -BeTrue
        Test-Path (Join-Path $r.ToolFolder 'sessions\s2.json') | Should -BeFalse -Because 'the session names another site'
        $p = Get-Content (Join-Path $r.ToolFolder 'prefs.json') -Raw | ConvertFrom-Json
        $p.SiteCode | Should -Be 'AB1'
        $p.PSObject.Properties.Name | Should -Not -Contain 'ApproveAfterSubmit'
        Assert-NoChange -Before $before -After (Get-TreeHash $pivots)
    }
}

Context 'Tool paths' {
    It 'returns the old path with no site and the site path with one' {
        $none = [pscustomobject]@{ Active = $false }
        Resolve-SuiteToolPath -Site $none -Name 'reports' -LegacyPath 'C:\old\Reports' | Should -Be 'C:\old\Reports'
        $site = [pscustomobject]@{ Active = $true; ToolFolder = (Join-Path $script:Data 'sites\AB1\tools\site-hygiene') }
        $p = Resolve-SuiteToolPath -Site $site -Name 'reports' -LegacyPath 'C:\old\Reports'
        $p | Should -Be (Join-Path $site.ToolFolder 'reports')
        Test-Path $p | Should -BeFalse
        Resolve-SuiteToolPath -Site $site -Name 'rings\runs' -LegacyPath 'x' -Create | Should -Be (Join-Path $site.ToolFolder 'rings\runs')
        Test-Path (Join-Path $site.ToolFolder 'rings\runs') -PathType Container | Should -BeTrue
        Resolve-SuiteToolPath -Site $site -Name 'a\b.json' -LegacyPath 'x' -File -Create | Should -Be (Join-Path $site.ToolFolder 'a\b.json')
        Test-Path (Join-Path $site.ToolFolder 'a') -PathType Container | Should -BeTrue
        Test-Path (Join-Path $site.ToolFolder 'a\b.json') | Should -BeFalse
    }

    It 'refuses a name that leaves the tool folder' {
        $site = [pscustomobject]@{ Active = $true; ToolFolder = (Join-Path $script:Data 'sites\AB1\tools\site-hygiene') }
        { Resolve-SuiteToolPath -Site $site -Name '..\..\x' -LegacyPath 'x' } | Should -Throw
    }
}

Context 'Tool prefs split' {
    BeforeEach {
        $script:Defaults = { @{ DarkMode = $true; SiteCode = ''; SMSProvider = ''; SQLServer = ''; AlertToast = $false } }
        $script:Keys = @('SiteCode', 'SMSProvider', 'SQLServer')
    }

    It 'reads and writes the old file as before when no site is active' {
        $path = Join-Path $script:Temp 'prefs.json'
        $none = [pscustomobject]@{ Active = $false }
        $p = Read-SuiteToolPrefs -Path $path -Defaults (& $script:Defaults) -Site $none -SiteKeys $script:Keys
        $p['SiteCode'] | Should -Be ''
        $p['SiteCode'] = 'AB1'
        (Save-SuiteToolPrefs -Path $path -Settings $p -Site $none -SiteKeys $script:Keys) | Should -BeTrue
        (Get-Content $path -Raw | ConvertFrom-Json).SiteCode | Should -Be 'AB1'
    }

    It 'keeps the site keys apart from the global keys, and never changes the site code' {
        $t = New-OldHygiene -Suite $script:Suite
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $legacy = Join-Path $t 'SiteHygiene.prefs.json'
        $site = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -LegacyPrefsPath $legacy -DataRoot $script:Data -LocalRoot $script:Local
        $p = Read-SuiteToolPrefs -Path $legacy -Defaults (& $script:Defaults) -Site $site -SiteKeys $script:Keys
        $p['SQLServer'] | Should -Be 'sql01.example.com'
        $p['SiteCode'] | Should -Be 'AB1'
        $p['AlertToast'] | Should -BeTrue
        $p['SQLServer'] = 'sql02.example.com'
        $p['SiteCode'] = 'ZZ9'
        $p['SMSProvider'] = 'cm09.example.com'
        $p['DarkMode'] = $true
        (Save-SuiteToolPrefs -Path $legacy -Settings $p -Site $site -SiteKeys $script:Keys) | Should -BeTrue

        $sitePrefs = Get-Content (Join-Path $site.ToolFolder 'prefs.json') -Raw | ConvertFrom-Json
        $sitePrefs.SQLServer | Should -Be 'sql02.example.com'
        $sitePrefs.SiteCode | Should -Be 'AB1'
        $sitePrefs.SMSProvider | Should -Be 'cm09.example.com'
        $old = Get-Content $legacy -Raw | ConvertFrom-Json
        $old.DarkMode | Should -BeTrue
        $old.SQLServer | Should -Be 'sql01.example.com' -Because 'the old file keeps its old site values for one release'
        $old.SiteCode | Should -Be 'AB1'
        # The provider moved to the front of the list in site.json.
        (Get-SuiteSiteList -DataRoot $script:Data)[0].Providers[0] | Should -Be 'cm09.example.com'
    }

    It 'does not carry the values of one site into another (two-site isolation)' {
        $t = New-OldHygiene -Suite $script:Suite
        $legacy = Join-Path $t 'SiteHygiene.prefs.json'
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $ab1 = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -LegacyPrefsPath $legacy -DataRoot $script:Data -LocalRoot $script:Local
        $pa = Read-SuiteToolPrefs -Path $legacy -Defaults (& $script:Defaults) -Site $ab1 -SiteKeys $script:Keys
        $pa['SQLServer'] = 'sql-ab1.example.com'
        [void](Save-SuiteToolPrefs -Path $legacy -Settings $pa -Site $ab1 -SiteKeys $script:Keys)
        Write-Seed (Resolve-SuiteToolPath -Site $ab1 -Name 'reports' -LegacyPath 'x' -Create) 'ab1-report.html' 'AB1 report'
        $ab1Before = Get-TreeHash (Join-Path $script:Data 'sites\AB1')

        Set-Active -DataRoot $script:Data -Folder 'CD2'
        $cd2 = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -LegacyPrefsPath $legacy -DataRoot $script:Data -LocalRoot $script:Local
        $cd2.SiteFolder | Should -Be 'CD2'
        $pc = Read-SuiteToolPrefs -Path $legacy -Defaults (& $script:Defaults) -Site $cd2 -SiteKeys $script:Keys
        $pc['SiteCode'] | Should -Be 'CD2'
        $pc['SQLServer'] | Should -Be '' -Because 'the SQL server of AB1 is not the SQL server of CD2'
        $pc['SMSProvider'] | Should -Be ''
        $pc['DarkMode'] | Should -Be $false -Because 'global keys come from the old file for every site'
        $pc['SQLServer'] = 'sql-cd2.example.com'
        $pc['SMSProvider'] = 'cm02.example.com'
        [void](Save-SuiteToolPrefs -Path $legacy -Settings $pc -Site $cd2 -SiteKeys $script:Keys)
        Write-Seed (Resolve-SuiteToolPath -Site $cd2 -Name 'reports' -LegacyPath 'x' -Create) 'cd2-report.html' 'CD2 report'

        # The writes of CD2 changed nothing in the AB1 folder.
        Assert-NoChange -Before $ab1Before -After (Get-TreeHash (Join-Path $script:Data 'sites\AB1'))
        (Get-ChildItem (Join-Path $script:Data 'sites\AB1\tools\site-hygiene\reports') | ForEach-Object Name) | Should -Not -Contain 'cd2-report.html'
        (Get-ChildItem (Join-Path $script:Data 'sites\CD2\tools\site-hygiene\reports') | ForEach-Object Name) | Should -Not -Contain 'ab1-report.html'
        (Get-Content (Join-Path $script:Data 'sites\AB1\tools\site-hygiene\prefs.json') -Raw | ConvertFrom-Json).SQLServer | Should -Be 'sql-ab1.example.com'
        (Get-Content (Join-Path $script:Data 'sites\CD2\tools\site-hygiene\prefs.json') -Raw | ConvertFrom-Json).SQLServer | Should -Be 'sql-cd2.example.com'

        # Back to AB1: its values return.
        Set-Active -DataRoot $script:Data -Folder 'AB1'
        $again = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $t -LegacyPrefsPath $legacy -DataRoot $script:Data -LocalRoot $script:Local
        (Read-SuiteToolPrefs -Path $legacy -Defaults (& $script:Defaults) -Site $again -SiteKeys $script:Keys)['SQLServer'] | Should -Be 'sql-ab1.example.com'
    }
}

Context 'Launcher site helpers' {
    BeforeAll {
        $script:LauncherPath = Join-Path $script:RepoRoot 'start-suite.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$null, [ref]$null)
        foreach ($name in 'Save-LauncherSite', 'Set-LaunchEnvironment') {
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            if (-not $fn) { throw "$name is missing from start-suite.ps1" }
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }

    BeforeEach { $env:APP_PACKAGER_DATA_ROOT = $script:Data }

    It 'saves the site, the provider and the active site' {
        $r = Save-LauncherSite -SiteText ' cd2 ' -Provider 'cm02.example.com'
        $r.Saved | Should -BeTrue
        $r.Folder | Should -Be 'CD2'
        $root = Get-SuiteDataRoot
        (Get-SuiteActiveSite -DataRoot $root -IgnoreEnvironment).SiteCode | Should -Be 'CD2'
        (Get-SuiteSiteList -DataRoot $root)[0].Providers[0] | Should -Be 'cm02.example.com'
        $s = Get-Content (Join-Path $root 'sites\CD2\settings.json') -Raw | ConvertFrom-Json
        $s.SiteCode | Should -Be 'CD2'
        $s.SMSProvider | Should -Be 'cm02.example.com'
    }

    It 'refuses a reserved or malformed code and changes nothing' {
        foreach ($bad in 'SMS', 'AB', 'ABCD', 'A-1', '') {
            $r = Save-LauncherSite -SiteText $bad -Provider 'cm01.example.com'
            $r.Saved | Should -BeFalse
            $r.Message | Should -Match 'three letters or digits'
        }
        Test-Path (Join-Path (Get-SuiteDataRoot) 'sites') | Should -BeFalse
        Test-Path (Join-Path (Get-SuiteDataRoot) 'active-site.json') | Should -BeFalse
    }

    It 'switches twice: the second Save takes effect even after the environment was set for a tool' {
        $global:Prefs = @{ SiteCode = ''; SMSProvider = '' }
        $script:SettingsPath = Join-Path $script:Temp 'suite.settings.json'
        $script:LauncherSite = [pscustomobject]@{ Active = $false; SiteFolder = ''; SiteCode = ''; Provider = '' }
        (Save-LauncherSite -SiteText 'AB1' -Provider 'cm01.example.com').Saved | Should -BeTrue
        $script:LauncherSite = Resolve-SuiteToolSite -Tool 'app-packager-suite' -ToolRoot (Join-Path $script:Suite 'app-packager-suite') -LegacyPrefsPath $script:SettingsPath -NoMigration -IgnoreEnvironment
        Set-LaunchEnvironment
        $env:SUITE_CM_SITECODE | Should -Be 'AB1'
        (Save-LauncherSite -SiteText 'CD2' -Provider 'cm02.example.com').Saved | Should -BeTrue
        $script:LauncherSite = Resolve-SuiteToolSite -Tool 'app-packager-suite' -ToolRoot (Join-Path $script:Suite 'app-packager-suite') -LegacyPrefsPath $script:SettingsPath -NoMigration -IgnoreEnvironment
        $script:LauncherSite.SiteFolder | Should -Be 'CD2'
        Set-LaunchEnvironment
        $env:SUITE_CM_SITECODE | Should -Be 'CD2'
        $env:SUITE_CM_PROVIDER | Should -Be 'cm02.example.com'
    }

    It 'refuses a new site that carries the provider of another site' {
        (Save-LauncherSite -SiteText 'AB1' -Provider 'cm01.example.com').Saved | Should -BeTrue
        $r = Save-LauncherSite -SiteText 'CD2' -Provider 'cm01.example.com'
        $r.Saved | Should -BeFalse
        $r.Message | Should -Match 'belongs to site AB1'
        Test-Path (Join-Path (Get-SuiteDataRoot) 'sites\CD2') | Should -BeFalse
        (Save-LauncherSite -SiteText 'CD2' -Provider '').Saved | Should -BeTrue
        (Save-LauncherSite -SiteText 'AB1' -Provider 'cm01.example.com').Saved | Should -BeTrue
    }

    It 'sets the environment of a started tool from the active site' {
        $global:Prefs = @{ SiteCode = 'OLD'; SMSProvider = 'old.example.com' }
        $script:LauncherSite = [pscustomobject]@{ Active = $true; SiteFolder = 'CD2'; SiteCode = 'CD2'; Provider = 'cm02.example.com' }
        Set-LaunchEnvironment
        $env:SUITE_CM_SITECODE | Should -Be 'CD2'
        $env:APP_PACKAGER_SITE | Should -Be 'CD2'
        $env:SUITE_CM_PROVIDER | Should -Be 'cm02.example.com'
        $script:LauncherSite = [pscustomobject]@{ Active = $true; SiteFolder = 'CD2~2'; SiteCode = 'CD2'; Provider = 'cm03.example.com' }
        Set-LaunchEnvironment
        $env:SUITE_CM_SITECODE | Should -BeNullOrEmpty -Because 'a tool would read the code as the first site CD2'
        $env:APP_PACKAGER_SITE | Should -Be 'CD2~2'
    }

    It 'falls back to the old launcher values when no site is chosen' {
        $global:Prefs = @{ SiteCode = 'EF3'; SMSProvider = 'old.example.com' }
        $script:LauncherSite = [pscustomobject]@{ Active = $false; SiteFolder = ''; SiteCode = ''; Provider = '' }
        Set-LaunchEnvironment
        $env:SUITE_CM_SITECODE | Should -Be 'EF3'
        $env:SUITE_CM_PROVIDER | Should -Be 'old.example.com'
        $env:APP_PACKAGER_SITE | Should -BeNullOrEmpty
    }
}

Context 'Footer note' {
    It 'adds a note after the site text, keeps it through a footer update, and clears it' {
        try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop } catch { Set-ItResult -Skipped -Because 'WPF is not available'; return }
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'Site AB1 - cm01.example.com'
        $tb.Tag = @{ Base = $tb.Text; Note = '' }
        $win = New-Object psobject
        $win | Add-Member -MemberType ScriptMethod -Name FindName -Value { param($n) if ($n -eq 'txtFooterSite') { $tb } } -PassThru | Out-Null
        Set-SuiteFooterNote -Window $win -Text 'The launcher now uses site CD2.'
        $tb.Text | Should -Match 'The launcher now uses site CD2\.$'
        Update-SuiteFooter -Window $win -SiteCode 'AB1' -SiteServer 'cm01.example.com'
        $tb.Text | Should -Match 'cm01\.example\.com .* The launcher now uses site CD2\.$'
        $tb.ToolTip | Should -Match 'launcher'
        Set-SuiteFooterNote -Window $win -Text ''
        $tb.Text | Should -Not -Match 'launcher'
        $tb.ToolTip | Should -BeNullOrEmpty
    }
}
}
