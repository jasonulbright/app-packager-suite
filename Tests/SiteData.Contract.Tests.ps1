#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }

<#
.SYNOPSIS
    Contract test for the per-site data layout (Q-112b): fixtures, schemas, names and paths.

.DESCRIPTION
    The fixtures in Tests\Fixtures\SiteData and the schemas in docs\schema are shared with
    App Packager Desktop (all in tests\ApplicationPackagerEngine.Tests\Fixtures\SiteData). Both repositories pin the SHA-256 of every file
    (line endings normalized), so a change of one copy fails the test of the other repository
    until both change. The same cases drive the PowerShell functions here and SiteDataPaths in C#.
    No test writes to the real data root.
    Run: Invoke-Pester -Path .\Tests\SiteData.Contract.Tests.ps1 -Output Detailed
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking
    $script:Fx = Join-Path $PSScriptRoot 'Fixtures\SiteData'
    $script:Schema = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\schema'
    $script:Cases = Get-Content -LiteralPath (Join-Path $script:Fx 'site-cases.json') -Raw | ConvertFrom-Json
    $script:Manifest = Get-Content -LiteralPath (Join-Path $script:Fx 'scope-manifest.json') -Raw | ConvertFrom-Json

    function Get-NormalizedHash {
        param([string]$Path)
        $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant()
    }
}

Describe 'Site data contract files' {
    It 'keeps the same fixtures as App Packager Desktop' {
        # The hashes pin the files of contract schemaVersion 1.
        $pins = [ordered]@{
            'scope-manifest.json' = 'b6ef8da676de41bdd067f390baa586bdacd2dcf85284d5f05170d13fed8f3307'
            'site-cases.json'     = 'e4084aa3c3da1774046bd75d5cab1dd97157b9dfa4b6f0c2849e12b29d7096ca'
            'site.json'           = '33d8b80f2f64057407b1907efb66cd28f3fded7151397ccf5f35be68150215ca'
            'active-site.json'    = '1a82f657c57f72a8f21ef2445dab9225a3a91e9c2e748d3802dca40ed7e30500'
        }
        foreach ($name in $pins.Keys) {
            Get-NormalizedHash -Path (Join-Path $script:Fx $name) | Should -Be $pins[$name] -Because "$name is shared with App Packager Desktop"
        }
    }

    It 'keeps the same schemas as App Packager Desktop' {
        $pins = [ordered]@{
            'site.schema.json'           = '9a4283e4ee0bd3b0c0dfd4133c78f9765e058adc12d967e0a6a3a8db285f2007'
            'active-site.schema.json'    = 'a26607a3a9e7b32c765e986d9144161c1beb3712a952452ae0f69e78b576b902'
            'scope-manifest.schema.json' = '1d90288bed5aaca55b471c530ea3974803cbdca02edb3041e1592434e5c0788a'
        }
        foreach ($name in $pins.Keys) {
            Get-NormalizedHash -Path (Join-Path $script:Schema $name) | Should -Be $pins[$name] -Because "$name is shared with App Packager Desktop"
        }
    }

    It 'validates each fixture against its schema' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $pairs = @(
            @('site.json', 'site.schema.json'),
            @('active-site.json', 'active-site.schema.json'),
            @('scope-manifest.json', 'scope-manifest.schema.json')
        )
        foreach ($p in $pairs) {
            $schema = Get-Content -LiteralPath (Join-Path $script:Schema $p[1]) -Raw
            { $schema | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw -Because 'a malformed schema must fail, not skip'
            (Get-Content -LiteralPath (Join-Path $script:Fx $p[0]) -Raw) | Test-Json -Schema $schema | Should -BeTrue -Because $p[0]
        }
    }

    It 'rejects a bad site.json' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $schema = Get-Content -LiteralPath (Join-Path $script:Schema 'site.schema.json') -Raw
        '{"schemaVersion":2,"siteCode":"AB1","providers":[],"createdUtc":"2026-11-22T09:00:00Z","lastUsedUtc":"2026-11-22T09:00:00Z"}' | Test-Json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        '{"schemaVersion":1,"siteCode":"ab1","providers":[],"createdUtc":"2026-11-22T09:00:00Z","lastUsedUtc":"2026-11-22T09:00:00Z"}' | Test-Json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'Scope manifest rules' {
    It 'has unique ids' {
        $ids = @($script:Manifest.entries | ForEach-Object { $_.id })
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'never copies a secret and gives it no site target' {
        $secrets = @($script:Manifest.entries | Where-Object { $_.scope -eq 'secret' })
        $secrets.Count | Should -BeGreaterThan 0
        foreach ($e in $secrets) {
            $e.import | Should -Be 'never' -Because $e.id
            $e.target | Should -BeNullOrEmpty -Because $e.id
        }
    }

    It 'gives every site entry a target and every global entry none' {
        foreach ($e in $script:Manifest.entries) {
            if ($e.scope -eq 'site') { $e.target | Should -Not -BeNullOrEmpty -Because $e.id }
            else { $e.target | Should -BeNullOrEmpty -Because $e.id }
        }
    }

    It 'never copies identity, results or run data of a site' {
        foreach ($id in 'apd.site-code', 'apd.provider', 'apd.check-cm-result', 'apd.inventory', 'apd.deployments', 'apd.hygiene-stores', 'suite.pivots-sessions') {
            ($script:Manifest.entries | Where-Object { $_.id -eq $id }).import | Should -Be 'never' -Because $id
        }
    }

    It 'covers every app of the layout' {
        $apps = @($script:Manifest.entries | ForEach-Object { $_.app } | Select-Object -Unique)
        foreach ($a in 'apd', 'powershell', 'suite-launcher', 'deployment-helper', 'update-planner', 'pivots-and-scripts') { $apps | Should -Contain $a }
    }
}

Describe 'Site names' {
    It 'validates the site code <value>' -ForEach @(
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Fixtures\SiteData\site-cases.json') -Raw | ConvertFrom-Json).siteCodes |
            ForEach-Object { @{ value = [string]$_.value; valid = [bool]$_.valid } }
    ) {
        Test-SuiteSiteCode -SiteCode $value | Should -Be $valid
    }

    It 'lists the reserved codes of the fixture' {
        $script:Cases.reservedSiteCodes | Should -Be @('AUX', 'CON', 'ENV', 'NUL', 'PRN', 'SMS')
    }

    It 'validates the folder name <value>' -ForEach @(
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Fixtures\SiteData\site-cases.json') -Raw | ConvertFrom-Json).folderNames |
            ForEach-Object { @{ value = [string]$_.value; valid = [bool]$_.valid; siteCode = [string]$_.siteCode; ordinal = $_.ordinal } }
    ) {
        Test-SuiteSiteName -Name $value | Should -Be $valid
        $parsed = ConvertFrom-SuiteSiteFolderName -Name $value
        if ($valid) {
            $parsed.SiteCode | Should -Be $siteCode
            $parsed.Ordinal | Should -Be $ordinal
        }
        else { $parsed | Should -BeNullOrEmpty }
    }

    It 'picks the next free folder name for <siteCode> with <existing>' -ForEach @(
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Fixtures\SiteData\site-cases.json') -Raw | ConvertFrom-Json).nextFolderName |
            ForEach-Object { @{ siteCode = [string]$_.siteCode; existing = @($_.existing); expected = [string]$_.expected } }
    ) {
        Get-SuiteFreeSiteFolderName -SiteCode $siteCode -ExistingNames $existing | Should -Be $expected
    }

    It 'refuses an invalid site code for a free folder name' {
        { Get-SuiteFreeSiteFolderName -SiteCode 'AUX' } | Should -Throw
    }
}

Describe 'Site folder paths' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'AppPackagerData'
    }

    It 'builds the relative path <expected> (null means refused)' -ForEach @(
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Fixtures\SiteData\site-cases.json') -Raw | ConvertFrom-Json).relativePaths |
            ForEach-Object { @{ siteCode = [string]$_.siteCode; tool = [string]$_.tool; area = [string]$_.area; expected = $_.expected } }
    ) {
        $args2 = @{ SiteCode = $siteCode; DataRoot = $script:Root }
        if ($tool) { $args2.Tool = $tool }
        if ($area) { $args2.Area = $area }
        if ($null -eq $expected) {
            { Get-SuiteSiteFolder @args2 } | Should -Throw
        }
        else {
            Get-SuiteSiteFolder @args2 | Should -Be (Join-Path $script:Root $expected)
        }
    }

    It 'creates no folder' {
        $null = Get-SuiteSiteFolder -SiteCode 'AB1' -Tool 'update-planner' -DataRoot $script:Root
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'uses -Tool or -Area, not both' {
        { Get-SuiteSiteFolder -SiteCode 'AB1' -Tool 'a' -Area 'b' -DataRoot $script:Root } | Should -Throw
    }
}

Describe 'Data root' {
    BeforeEach {
        $script:SavedRoot = [Environment]::GetEnvironmentVariable('APP_PACKAGER_DATA_ROOT')
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', $script:SavedRoot)
    }

    It 'defaults to %LOCALAPPDATA%\AppPackagerData' {
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', $null)
        Get-SuiteDataRoot | Should -Be (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AppPackagerData')
    }

    It 'scopes an override beneath Users\<SID>' {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', (Join-Path $TestDrive 'shared'))
        Get-SuiteDataRoot | Should -Be (Join-Path (Join-Path (Join-Path $TestDrive 'shared') 'Users') $sid)
    }

    It 'keeps an already scoped override' {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $scoped = Join-Path (Join-Path (Join-Path $TestDrive 'shared') 'Users') $sid
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', $scoped)
        Get-SuiteDataRoot | Should -Be $scoped
    }

    It 'refuses a root under Program Files' {
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'x'))
        # The override is scoped beneath Users\<SID>, which is still under Program Files.
        { Get-SuiteDataRoot } | Should -Throw
    }
}

Describe 'Active site' {
    BeforeEach {
        $script:SavedSuite = [Environment]::GetEnvironmentVariable('SUITE_CM_SITECODE')
        $script:SavedApp = [Environment]::GetEnvironmentVariable('APP_PACKAGER_SITE')
        [Environment]::SetEnvironmentVariable('SUITE_CM_SITECODE', $null)
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_SITE', $null)
        $script:Dr = Join-Path $TestDrive ('root-' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('SUITE_CM_SITECODE', $script:SavedSuite)
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_SITE', $script:SavedApp)
    }

    It 'returns null when nothing is set and no file exists' {
        Get-SuiteActiveSite -DataRoot $script:Dr | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:Dr | Should -BeFalse
    }

    It 'reads the shared fixture as active-site.json' {
        New-Item -ItemType Directory -Path $script:Dr -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fx 'active-site.json') -Destination (Join-Path $script:Dr 'active-site.json')
        $a = Get-SuiteActiveSite -DataRoot $script:Dr
        $a.SiteCode | Should -Be 'AB1'
        $a.Source | Should -Be 'active-site.json'
    }

    It 'prefers SUITE_CM_SITECODE, then APP_PACKAGER_SITE, then the file' {
        New-Item -ItemType Directory -Path $script:Dr -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fx 'active-site.json') -Destination (Join-Path $script:Dr 'active-site.json')
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_SITE', 'cd2')
        (Get-SuiteActiveSite -DataRoot $script:Dr).SiteCode | Should -Be 'CD2'
        [Environment]::SetEnvironmentVariable('SUITE_CM_SITECODE', 'EF3~2')
        $a = Get-SuiteActiveSite -DataRoot $script:Dr
        $a.SiteCode | Should -Be 'EF3~2'
        $a.Source | Should -Be 'SUITE_CM_SITECODE'
    }

    It 'skips an invalid environment value' {
        [Environment]::SetEnvironmentVariable('SUITE_CM_SITECODE', '..\x')
        Get-SuiteActiveSite -DataRoot $script:Dr | Should -BeNullOrEmpty
    }

    It 'ignores a file with a wrong schemaVersion, a bad code or bad JSON' {
        New-Item -ItemType Directory -Path $script:Dr -Force | Out-Null
        $f = Join-Path $script:Dr 'active-site.json'
        Set-Content -LiteralPath $f -Value '{"schemaVersion":2,"siteCode":"AB1","changedUtc":"2026-11-22T10:30:00Z"}'
        Get-SuiteActiveSite -DataRoot $script:Dr | Should -BeNullOrEmpty
        Set-Content -LiteralPath $f -Value '{"schemaVersion":1,"siteCode":"AUX","changedUtc":"2026-11-22T10:30:00Z"}'
        Get-SuiteActiveSite -DataRoot $script:Dr | Should -BeNullOrEmpty
        Set-Content -LiteralPath $f -Value '{not json'
        Get-SuiteActiveSite -DataRoot $script:Dr | Should -BeNullOrEmpty
    }
}
