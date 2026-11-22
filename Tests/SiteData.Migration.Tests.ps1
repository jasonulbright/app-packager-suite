#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }

<#
.SYNOPSIS
    Hash harness of the single-site migration (Q-112c), PowerShell side: Invoke-SuiteSiteMigration.

.DESCRIPTION
    Each test seeds an old-layout profile in a temp folder: launcher settings, PowerShell app preferences with secrets,
    history, Check ConfigMgr results, tool preferences, reports, rings, rollouts, audit logs, Pivots sessions, user
    templates. It runs the migration and compares the SHA-256 of every old file before and after. Site codes are
    fictional (AB1, CD2) and hosts are example.com. Nothing touches the real profile or the real data root.
    Run: Invoke-Pester -Path .\Tests\SiteData.Migration.Tests.ps1 -Output Detailed
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking
    $script:Manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Fixtures\SiteData\scope-manifest.json') -Raw | ConvertFrom-Json
    $script:Fixed = [datetime]::new(2026, 11, 22, 8, 0, 0, [DateTimeKind]::Utc)
    $script:Secrets = @('ghp_FAKE_github_token_1234', 'FAKE_intune_secret_value', 'FAKE_teamviewer_api_token', 'FAKE_nvd_key_value', 'https://hooks.example.com/FAKE_webhook')

    function Write-Seed {
        param([string]$Root, [string]$Relative, [string]$Text)
        $p = Join-Path $Root $Relative
        $d = Split-Path $p -Parent
        if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
    }

    function New-LegacyProfile {
        param([string]$Temp, [string]$SiteCode = 'AB1', [switch]$NoCode)
        $suite = Join-Path $Temp 'AppPackagerSuite'
        $local = Join-Path $Temp 'Local'
        $launcher = @{ SiteCode = $(if ($NoCode) { '' } else { $SiteCode }); SMSProvider = 'cm01.example.com'; DarkMode = $true; ToolsRoot = '' }
        Write-Seed $suite 'app-packager-suite\suite.settings.json' ($launcher | ConvertTo-Json)
        Write-Seed $suite 'app-packager-suite\suite.windowstate.json' '{"Left":10}'
        $prefs = [ordered]@{
            SiteCode = $(if ($NoCode) { '' } else { $SiteCode }); ProviderMachineName = 'cm01.example.com'; FileShareRoot = '\\files.example.com\content$'
            ContentDistribution = @{ DistributionPointGroup = 'All DPs'; TestCollection = 'Test Devices' }
            Wsus = @{ Server = 'wsus01.example.com'; Port = 8530 }; Theme = 'Dark'
            GitHubToken = $script:Secrets[0]; Intune = @{ TenantId = 'tenant.example.com'; ClientSecret = $script:Secrets[1] }
        }
        Write-Seed $suite 'app-packager\AppPackager.preferences.json' ($prefs | ConvertTo-Json -Depth 6)
        Write-Seed $suite 'app-packager\Packagers\packager-preferences.json' '{"opt":1}'
        Write-Seed $suite 'app-packager\Packagers\teamviewer-host-config.json' ('{"ApiToken":"' + $script:Secrets[2] + '"}')
        Write-Seed $suite 'app-packager\VersionMonitor\monitor-config.json' ('{"MECM":{"SiteCode":"' + $SiteCode + '","ServerFQDN":"cm01.example.com"},"NvdApiKey":"' + $script:Secrets[3] + '","WebhookUrl":"' + $script:Secrets[4] + '"}')
        Write-Seed $suite 'app-packager\Logs\app.log' 'log line'
        Write-Seed $suite 'site-hygiene\SiteHygiene.prefs.json' ('{"DarkMode":true,"SMSProvider":"cm01.example.com","SiteCode":"' + $SiteCode + '","SQLServer":"sql01.example.com"}')
        Write-Seed $suite 'site-hygiene\lastscan.json' '{"scanned":"2026-11-20"}'
        Write-Seed $suite 'site-hygiene\suppressions.json' '{"suppressed":["OBJ-1"]}'
        Write-Seed $suite 'site-hygiene\History\metrics-history.csv' "date,count`n2026-11-20,3`n"
        Write-Seed $suite 'site-hygiene\Reports\hygiene-1.html' '<html>r</html>'
        Write-Seed $suite 'deployment-helper\DeploymentHelper.prefs.json' ('{"SMSProvider":"cm01.example.com","SiteCode":"' + $SiteCode + '","DeploymentAuditLogPath":"C:\\old\\audit.jsonl"}')
        Write-Seed $suite 'deployment-helper\Rings\plan-1.json' '{"name":"Pilot","collection":"Pilot Devices"}'
        Write-Seed $suite 'deployment-helper\Rings\runs\run-001.json' '{"run":1}'
        Write-Seed $suite 'deployment-helper\Rollouts\roll-1.json' '{"roll":1}'
        Write-Seed $suite 'deployment-helper\Logs\deployment-audit.jsonl' "{`"op`":`"deploy`"}`n"
        Write-Seed $suite 'deployment-helper\Templates\mine.json' '{"user":"template"}'
        Write-Seed $suite 'update-planner\UpdatePlanner.prefs.json' ('{"SiteCode":"' + $SiteCode + '","SMSProvider":"cm01.example.com","Waves":["COL00001|Wave 1"],"Spacing":7}')
        Write-Seed $suite 'update-planner\Reports\update-plan-1.html' '<html>plan</html>'
        Write-Seed $suite 'update-planner\Logs\update-planner-actions.jsonl' "{`"a`":1}`n"
        Write-Seed $suite 'device-inspector\DeviceInspector.prefs.json' ('{"SiteCode":"' + $SiteCode + '","SMSProvider":"cm01.example.com","LastDevice":"CLIENT01"}')
        Write-Seed $suite 'device-inspector\Reports\di-1.html' '<html>di</html>'
        Write-Seed $suite 'device-inspector\Logs\DeviceInspector-actions.log' 'action'
        Write-Seed $suite 'collection-manager\CollectionManager.prefs.json' ('{"SiteCode":"' + $SiteCode + '","SMSProvider":"cm01.example.com"}')
        Write-Seed $suite 'collection-manager\Reports\c1.csv' 'c'
        Write-Seed $suite 'collection-and-compliance-manager\CCM.prefs.json' ('{"SiteCode":"' + $SiteCode + '"}')
        Write-Seed $suite 'maintenance-window-manager\MaintWindowMgr.prefs.json' ('{"SiteCode":"' + $SiteCode + '"}')
        Write-Seed $suite 'maintenance-window-manager\Reports\m1.csv' 'm'
        Write-Seed $suite 'dp-content-manager\DPContentMgr.prefs.json' ('{"SiteCode":"' + $SiteCode + '"}')
        Write-Seed $suite 'dp-content-manager\Reports\d1.csv' 'd'
        Write-Seed $suite 'pivots-and-scripts\Library\snippet.ps1' 'Get-Date'
        Write-Seed $local 'AppPackager\app-history.json' '{"package-chrome":{"LastChecked":"2026-04-19T17:00:00Z","LastKnownVersion":"140.0","LastCmChecked":"2026-04-19T17:00:00Z","LastCmVersion":"139.0"}}'
        Write-Seed $local 'AppPackager\CheckConfigMgrResult.csv' "App,Version,ConfigMgrVersion,Source`nchrome,140.0,139.0,CM`n"
        Write-Seed $local 'AppPackager\CheckConfigMgrResult.json' '[{"App":"chrome"}]'
        Write-Seed $local 'AppPackager\kev-catalog.json' '{"cve":[]}'
        Write-Seed $local 'SignalRidgeLabs\PivotsAndScripts\Sessions\s1.json' ('{"SiteCode":"' + $SiteCode + '","Provider":"cm01.example.com"}')
        Write-Seed $local 'SignalRidgeLabs\PivotsAndScripts\Sessions\s2.json' '{"SiteCode":"CD2","Provider":"cm02.example.com"}'
        Write-Seed $local 'SignalRidgeLabs\PivotsAndScripts\preferences.json' '{"theme":"dark"}'
        [pscustomobject]@{ Suite = $suite; Local = $local; Data = (Join-Path $Temp 'AppPackagerData') }
    }

    function Get-Tree {
        param([string]$Folder)
        $map = [ordered]@{}
        if (Test-Path $Folder) {
            foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force | Sort-Object FullName)) {
                $map[$f.FullName.Substring($Folder.Length)] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            }
        }
        $map
    }
    function Get-ProfileText {
        param($P)
        $a = Get-Tree $P.Suite; $b = Get-Tree $P.Local
        (($a.Keys | ForEach-Object { "S$_=$($a[$_])" }) + ($b.Keys | ForEach-Object { "L$_=$($b[$_])" })) -join "`n"
    }
    function Get-TreeText { param([string]$Folder) $t = Get-Tree $Folder; ($t.Keys | ForEach-Object { "$_=$($t[$_])" }) -join "`n" }
    function Get-Times { param([string]$Folder) if (-not (Test-Path $Folder)) { return '' }; (@(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName)=$($_.LastWriteTimeUtc.Ticks)" })) -join "`n" }
    function Invoke-Mig {
        param($P, [switch]$DryRun, [scriptblock]$Hook, [string]$SiteCode)
        $a = @{ SuiteRoot = $P.Suite; DataRoot = $P.Data; LocalRoot = $P.Local; NowUtc = $script:Fixed; DryRun = $DryRun }
        if ($Hook) { $a['Hook'] = $Hook }
        if ($SiteCode) { $a['SiteCode'] = $SiteCode }
        Invoke-SuiteSiteMigration @a
    }
}

Describe 'Invoke-SuiteSiteMigration' {
    BeforeEach {
        $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('ap-sitemig-' + [guid]::NewGuid().ToString('N'))
        $script:P = New-LegacyProfile -Temp $script:Temp
    }
    AfterEach { if (Test-Path $script:Temp) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'dry run lists every item with scope, source, destination and hash, and writes nothing' {
        $before = Get-ProfileText $script:P
        $r = Invoke-Mig $script:P -DryRun
        $r.Outcome | Should -Be 'DryRun'
        $r.SiteCode | Should -Be 'AB1'
        Test-Path $script:P.Data | Should -BeFalse
        Get-ProfileText $script:P | Should -Be $before
        foreach ($i in @($r.Items | Where-Object { $_.Status -eq 'Planned' })) {
            $i.Scope | Should -Be 'site'
            $i.Source | Should -Not -BeNullOrEmpty
            $i.Destination | Should -Not -BeNullOrEmpty
            $i.Sha256.Length | Should -Be 64
        }
        $text = Format-SuiteSiteMigrationReport -Report $r
        $text | Should -Match 'deployment-audit.jsonl'
        $text | Should -Match 'lastscan.json'
    }

    It 'copies every site file with an equal hash and leaves the old profile unchanged' {
        $before = Get-ProfileText $script:P
        $r = Invoke-Mig $script:P
        $r.Outcome | Should -Be 'Migrated'
        Get-ProfileText $script:P | Should -Be $before
        $site = Join-Path $script:P.Data 'sites\AB1'
        foreach ($i in @($r.Items | Where-Object { $_.Status -eq 'Copied' -and $_.Id -ne 'site.json' -and (Test-Path -LiteralPath $_.Source -PathType Leaf) -and $_.Id -notin 'ps.site-fields', 'ps.last-cm-version' -and $_.Id -notmatch 'prefs' -and $_.Destination -notmatch 'prefs.json$' })) {
            (Get-FileHash -LiteralPath $i.Destination).Hash | Should -Be (Get-FileHash -LiteralPath $i.Source).Hash
            $i.Sha256 | Should -Be (Get-FileHash -LiteralPath $i.Source).Hash.ToLowerInvariant()
            $i.Destination | Should -BeLike "$site*"
        }
        $pairs = @(
            @('Suite', 'site-hygiene\suppressions.json', 'tools\site-hygiene\suppressions.json'),
            @('Suite', 'site-hygiene\History\metrics-history.csv', 'tools\site-hygiene\history\metrics-history.csv'),
            @('Suite', 'deployment-helper\Rings\runs\run-001.json', 'tools\deployment-helper\rings\runs\run-001.json'),
            @('Suite', 'deployment-helper\Rollouts\roll-1.json', 'tools\deployment-helper\rollouts\roll-1.json'),
            @('Suite', 'deployment-helper\Logs\deployment-audit.jsonl', 'tools\deployment-helper\deployment-audit.jsonl'),
            @('Suite', 'update-planner\Reports\update-plan-1.html', 'tools\update-planner\reports\update-plan-1.html'),
            @('Local', 'AppPackager\CheckConfigMgrResult.csv', 'results\CheckConfigMgrResult.csv'),
            @('Local', 'SignalRidgeLabs\PivotsAndScripts\Sessions\s1.json', 'tools\pivots-and-scripts\sessions\s1.json')
        )
        foreach ($p in $pairs) {
            $src = Join-Path $script:P.($p[0]) $p[1]
            (Get-FileHash -LiteralPath (Join-Path $site $p[2])).Hash | Should -Be (Get-FileHash -LiteralPath $src).Hash
        }
        Test-Path (Join-Path $site 'site.json') | Should -BeTrue
        Test-Path (Join-Path $site 'migration.json') | Should -BeTrue
        $settings = Get-Content (Join-Path $site 'settings.json') -Raw | ConvertFrom-Json
        $settings.ProviderMachineName | Should -Be 'cm01.example.com'
        $settings.SMSProvider | Should -Be 'cm01.example.com'
        $settings.VersionMonitor.ServerFQDN | Should -Be 'cm01.example.com'
        $settings.PSObject.Properties.Name | Should -Not -Contain 'Theme'
        $state = Get-Content (Join-Path $site 'state\app-state.json') -Raw | ConvertFrom-Json
        $state.'package-chrome'.LastCmVersion | Should -Be '139.0'
        $state.'package-chrome'.PSObject.Properties.Name | Should -Not -Contain 'LastKnownVersion'
        $prefs = Get-Content (Join-Path $site 'tools\update-planner\prefs.json') -Raw | ConvertFrom-Json
        $prefs.Waves | Should -Contain 'COL00001|Wave 1'
        $prefs.PSObject.Properties.Name | Should -Not -Contain 'Spacing'
        (Get-Content (Join-Path $site 'tools\deployment-helper\prefs.json') -Raw) | Should -Not -Match 'DeploymentAuditLogPath'
        (Get-Content (Join-Path $site 'site.json') -Raw | ConvertFrom-Json).migratedFrom | Should -Be 'legacy-single-site'
    }

    It 'keeps global items in place and puts no secret into a site folder' {
        $r = Invoke-Mig $script:P
        $all = (Get-ChildItem -LiteralPath (Join-Path $script:P.Data 'sites') -File -Recurse | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        foreach ($s in $script:Secrets) { $all | Should -Not -Match ([regex]::Escape($s)) }
        ($r.Items | Where-Object { $_.Id -eq 'ps.secrets-dpapi' }).Status | Should -Be 'SecretNotCopied'
        ($r.Items | Where-Object { $_.Id -eq 'suite.launcher-ui' }).Status | Should -Be 'GlobalStays'
        Test-Path (Join-Path $script:P.Data 'sites\AB1\tools\deployment-helper\Templates') | Should -BeFalse
        Test-Path (Join-Path $script:P.Data 'sites\AB1\tools\pivots-and-scripts\Library') | Should -BeFalse
        Test-Path (Join-Path $script:P.Data 'sites\AB1\tools\pivots-and-scripts\library') | Should -BeFalse
    }

    It 'changes nothing on a second run and says so' {
        [void](Invoke-Mig $script:P)
        $tree = Get-TreeText $script:P.Data
        $times = Get-Times $script:P.Data
        $again = Invoke-Mig $script:P
        $again.Outcome | Should -Be 'NothingChanged'
        @($again.Items | Where-Object { $_.Status -eq 'Copied' }).Count | Should -Be 0
        @($again.Items | Where-Object { $_.Status -eq 'AlreadyDone' }).Count | Should -BeGreaterThan 10
        Get-TreeText $script:P.Data | Should -Be $tree
        Get-Times $script:P.Data | Should -Be $times
    }

    It 'resumes after a crash after any item to the same result as a clean run' {
        $clean = Invoke-Mig $script:P
        $cleanTree = Get-TreeText $script:P.Data
        $count = @($clean.Items | Where-Object { $_.Status -eq 'Copied' -and $_.Id -ne 'site.json' }).Count
        Remove-Item -LiteralPath $script:P.Data -Recurse -Force
        $before = Get-ProfileText $script:P
        for ($k = 1; $k -le $count; $k++) {
            $script:n = 0; $script:k = $k
            { Invoke-Mig $script:P -Hook { param($stage, $dest) if ($stage -eq 'item-done') { $script:n++; if ($script:n -eq $script:k) { throw 'simulated crash' } } } } | Should -Throw 'simulated crash'
            Get-ProfileText $script:P | Should -Be $before
            $resumed = Invoke-Mig $script:P
            @($resumed.Items | Where-Object { $_.Status -in 'Conflict', 'Failed' }).Count | Should -Be 0
            Get-TreeText $script:P.Data | Should -Be $cleanTree
            (Invoke-Mig $script:P).Outcome | Should -Be 'NothingChanged'
            Remove-Item -LiteralPath $script:P.Data -Recurse -Force
        }
    }

    It 'leaves no partial file at the destination after a crash in the middle of a copy' {
        $before = Get-ProfileText $script:P
        $script:crashed = $null
        { Invoke-Mig $script:P -Hook { param($stage, $dest) if ($stage -eq 'temp-written' -and $dest -like '*suppressions.json') { $script:crashed = $dest; throw 'simulated crash' } } } | Should -Throw
        $script:crashed | Should -Not -BeNullOrEmpty
        Test-Path $script:crashed | Should -BeFalse
        Test-Path ($script:crashed + '.migrating') | Should -BeTrue
        Get-ProfileText $script:P | Should -Be $before
        $r = Invoke-Mig $script:P
        @($r.Items | Where-Object { $_.Status -in 'Conflict', 'Failed' }).Count | Should -Be 0
        Test-Path ($script:crashed + '.migrating') | Should -BeFalse
        (Get-FileHash $script:crashed).Hash | Should -Be (Get-FileHash (Join-Path $script:P.Suite 'site-hygiene\suppressions.json')).Hash
    }

    It 'keeps a destination with different content, reports it, and still copies the rest' {
        $dest = Join-Path $script:P.Data 'sites\AB1\tools\site-hygiene\suppressions.json'
        Write-Seed $script:P.Data 'sites\AB1\tools\site-hygiene\suppressions.json' '{"suppressed":["OTHER"]}'
        $existing = (Get-FileHash $dest).Hash
        $before = Get-ProfileText $script:P
        $r = Invoke-Mig $script:P
        (Get-FileHash $dest).Hash | Should -Be $existing
        Get-ProfileText $script:P | Should -Be $before
        @($r.Items | Where-Object { $_.Status -eq 'Conflict' }).Count | Should -Be 1
        $r.Outcome | Should -Be 'MigratedWithConflicts'
        Test-Path (Join-Path $script:P.Data 'sites\AB1\tools\site-hygiene\lastscan.json') | Should -BeTrue
        (Invoke-Mig $script:P).Outcome | Should -Be 'NothingChangedWithConflicts'
        (Get-FileHash $dest).Hash | Should -Be $existing
    }

    It 'reports a source that changed after the copy and does not overwrite the copy' {
        [void](Invoke-Mig $script:P)
        $dest = Join-Path $script:P.Data 'sites\AB1\tools\site-hygiene\lastscan.json'
        $h = (Get-FileHash $dest).Hash
        Write-Seed $script:P.Suite 'site-hygiene\lastscan.json' '{"scanned":"2026-11-21"}'
        $again = Invoke-Mig $script:P
        @($again.Items | Where-Object { $_.Status -eq 'SourceChanged' -and $_.Destination -eq $dest }).Count | Should -Be 1
        (Get-FileHash $dest).Hash | Should -Be $h
    }

    It 'reports a file that another app copied to the same destination as a conflict, not a changed source' {
        [void](Invoke-Mig $script:P)
        $mp = Join-Path $script:P.Data 'sites\AB1\migration.json'
        $m = Get-Content $mp -Raw | ConvertFrom-Json
        foreach ($i in $m.items) { if ($i.destination -like '*CheckConfigMgrResult.csv') { $i.source = 'C:\other-app\CheckConfigMgrResult.csv' } }
        [IO.File]::WriteAllText($mp, ($m | ConvertTo-Json -Depth 6))
        Write-Seed $script:P.Local 'AppPackager\CheckConfigMgrResult.csv' "App,Version`nother,1`n"
        $r = Invoke-Mig $script:P
        $c = @($r.Items | Where-Object { $_.Destination -like '*results\CheckConfigMgrResult.csv' })
        $c.Count | Should -Be 1
        $c[0].Status | Should -Be 'Conflict'
    }

    It 'stops when a copy does not match its source and the old files stay' {
        $before = Get-ProfileText $script:P
        $r = Invoke-Mig $script:P -Hook { param($stage, $dest) if ($stage -eq 'temp-written' -and $dest -like '*lastscan.json') { [IO.File]::AppendAllText($dest + '.migrating', 'corrupt') } }
        $r.Outcome | Should -Be 'Failed'
        $failed = @($r.Items | Where-Object { $_.Status -eq 'Failed' })
        $failed.Count | Should -Be 1
        Test-Path $failed[0].Destination | Should -BeFalse
        Test-Path ($failed[0].Destination + '.migrating') | Should -BeFalse
        Get-ProfileText $script:P | Should -Be $before
    }

    It 'merges a settings file written by another app and keeps its keys' {
        Write-Seed $script:P.Data 'sites\AB1\settings.json' '{"SiteCode":"AB1","ProviderMachine":"cm01.example.com","FromApd":{"a":1}}'
        $r = Invoke-Mig $script:P
        $r.Outcome | Should -Be 'Migrated'
        $m = Get-Content (Join-Path $script:P.Data 'sites\AB1\settings.json') -Raw | ConvertFrom-Json
        $m.FromApd.a | Should -Be 1
        $m.ProviderMachineName | Should -Be 'cm01.example.com'
        $tree = Get-TreeText $script:P.Data
        (Invoke-Mig $script:P).Outcome | Should -Be 'NothingChanged'
        Get-TreeText $script:P.Data | Should -Be $tree
    }

    It 'reports a settings key with another value as a conflict and does not write the file' {
        Write-Seed $script:P.Data 'sites\AB1\settings.json' '{"FileShareRoot":"other.example.com-share"}'
        $dest = Join-Path $script:P.Data 'sites\AB1\settings.json'
        $h = (Get-FileHash $dest).Hash
        $r = Invoke-Mig $script:P
        (Get-FileHash $dest).Hash | Should -Be $h
        $c = @($r.Items | Where-Object { $_.Status -eq 'Conflict' })
        $c.Count | Should -Be 1
        $c[0].Detail | Should -Match 'FileShareRoot'
    }

    It 'does not copy a source that is configured for another site' {
        Write-Seed $script:P.Suite 'collection-manager\CollectionManager.prefs.json' '{"SiteCode":"CD2","SMSProvider":"cm02.example.com"}'
        $r = Invoke-Mig $script:P
        $b = @($r.Items | Where-Object { $_.Status -eq 'Blocked' -and $_.Id -eq 'suite.collection-manager' })
        $b.Count | Should -Be 1
        $b[0].Detail | Should -Match 'CD2'
        Test-Path (Join-Path $script:P.Data 'sites\AB1\tools\collection-manager\prefs.json') | Should -BeFalse
    }

    It 'notes a Pivots session that names another site' {
        $r = Invoke-Mig $script:P
        $s2 = @($r.Items | Where-Object { $_.Source -like '*s2.json' })
        $s2.Count | Should -Be 1
        $s2[0].Detail | Should -Match 'CD2'
    }

    It 'takes the site code from the parameter, in upper case' {
        $r = Invoke-Mig $script:P -SiteCode 'ab1'
        $r.SiteCode | Should -Be 'AB1'
        Test-Path (Join-Path $script:P.Data 'sites\AB1') | Should -BeTrue
    }

    It 'migrates what exists when the profile has only some stores' {
        $t2 = Join-Path $script:Temp 'small'
        Write-Seed $t2 'AppPackagerSuite\app-packager-suite\suite.settings.json' '{"SiteCode":"CD2","SMSProvider":""}'
        $p2 = [pscustomobject]@{ Suite = (Join-Path $t2 'AppPackagerSuite'); Local = (Join-Path $t2 'Local'); Data = (Join-Path $t2 'Data') }
        $r = Invoke-Mig $p2
        $r.Outcome | Should -Be 'Migrated'
        Test-Path (Join-Path $p2.Data 'sites\CD2\settings.json') | Should -BeTrue
        Test-Path (Join-Path $p2.Data 'sites\CD2\results') | Should -BeFalse
        (Invoke-Mig $p2).Outcome | Should -Be 'NothingChanged'
    }

    It 'every ps and suite entry of the scope manifest is accounted for with the right scope' {
        $ids = @{}
        foreach ($e in $script:Manifest.entries) {
            if ($e.app -eq 'apd') { continue }
            $ids[$e.id] = $e.scope
        }
        # The module lists, read from the migration report of a full profile.
        $r = Invoke-Mig $script:P
        $reported = @{}
        foreach ($i in $r.Items) { if ($i.Scope -ne 'site' -or $i.Id -like 'suite.handoff*') { $reported[$i.Id] = $i.Scope } }
        foreach ($id in $ids.Keys) {
            if ($ids[$id] -eq 'site') { continue }
            $reported.ContainsKey($id) | Should -BeTrue -Because "$id ($($ids[$id])) must be reported as $($ids[$id])"
            $reported[$id] | Should -Be $ids[$id]
        }
        $siteIds = @($ids.Keys | Where-Object { $ids[$_] -eq 'site' })
        $handled = @($r.Items | ForEach-Object { $_.Id }) + @('ps.site-names', 'ps.share-root', 'ps.version-monitor', 'suite.launcher-site')
        foreach ($id in $siteIds) { $handled | Should -Contain $id -Because "$id is a site entry and the migration must handle it" }
    }
}

Describe 'Invoke-SuiteSiteMigration without a site code' {
    BeforeEach { $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('ap-sitemig-' + [guid]::NewGuid().ToString('N')) }
    AfterEach { if (Test-Path $script:Temp) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'migrates nothing and says why (<Case>)' -ForEach @(
        @{ Case = 'no code anywhere' }
        @{ Case = 'invalid code' }
        @{ Case = 'reserved code' }
    ) {
        $p = New-LegacyProfile -Temp $script:Temp -NoCode
        $param = $null
        if ($Case -eq 'invalid code') { $param = 'TOOLONG' }
        if ($Case -eq 'reserved code') { $param = 'PRN' }
        $before = Get-ProfileText $p
        foreach ($dry in $true, $false) {
            $r = Invoke-Mig $p -DryRun:$dry -SiteCode $param
            $r.Outcome | Should -Be 'NothingMigrated'
            $r.Reason | Should -Match 'No site code is configured'
            @($r.Items).Count | Should -Be 0
            $r.SiteCode | Should -BeNullOrEmpty
        }
        Test-Path $p.Data | Should -BeFalse
        Get-ProfileText $p | Should -Be $before
    }
}
