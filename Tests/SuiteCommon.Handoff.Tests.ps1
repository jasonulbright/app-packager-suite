#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }

<#
.SYNOPSIS
    Tests of the handoff routines of SuiteCommon (H-1): the path, the writer, the reader, the age text and the stale limit.

.DESCRIPTION
    Every test uses a data root in the Pester temp drive. Site codes are fictional (AB1, CD2). Nothing touches the real
    profile. The tests cover the atomic write, a malformed file, a file with a newer schema version, a file with no date,
    a stale file, a file for another site and the refusal of a secret.
    Run: Invoke-Pester -Path .\Tests\SuiteCommon.Handoff.Tests.ps1 -Output Detailed
#>

Describe 'Suite handoff routines' {
BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Get-Module SuiteCommon | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-11-23 12:00:00', [DateTimeKind]::Utc)

    function New-PlanJson {
        param([string]$Created = '2026-11-23T10:00:00Z', [int]$Version = 1, [string]$Format = 'SuiteRingPlan', [string]$Site = 'AB1', [switch]$NoCreated, [string]$Extra = '')
        $c = if ($NoCreated) { '' } else { '"CreatedUtc": "' + $Created + '",' }
        return ('{{ "Format": "{0}", "SchemaVersion": {1}, {2} "Producer": {{ "Name": "UpdatePlanner", "Version": "1.2.3" }}, "Site": {{ "SiteCode": "{3}" }}, "Name": "UpdatePlanner-a1", "Rings": [ ] {4} }}' -f $Format, $Version, $c, $Site, $Extra)
    }
}

Context 'Get-SuiteHandoffPath' {
    It 'is the handoff folder of the site folder' {
        $p = Get-SuiteHandoffPath -SiteCode 'AB1' -Kind 'ring-plan' -DataRoot 'C:\data'
        $p | Should -Be 'C:\data\sites\AB1\handoff\ring-plan.json'
    }
    It 'keeps the number of a reused site code' {
        Get-SuiteHandoffPath -SiteCode 'AB1~2' -Kind 'ring-plan' -DataRoot 'C:\data' | Should -Be 'C:\data\sites\AB1~2\handoff\ring-plan.json'
    }
    It 'refuses a bad kind and a bad site' {
        { Get-SuiteHandoffPath -SiteCode 'AB1' -Kind '..\x' -DataRoot 'C:\data' } | Should -Throw
        { Get-SuiteHandoffPath -SiteCode 'AB1' -Kind 'Ring' -DataRoot 'C:\data' } | Should -Throw
        { Get-SuiteHandoffPath -SiteCode 'A B' -Kind 'ring-plan' -DataRoot 'C:\data' } | Should -Throw
    }
    It 'creates nothing' {
        $root = Join-Path $TestDrive 'nothing'
        [void](Get-SuiteHandoffPath -SiteCode 'AB1' -Kind 'ring-plan' -DataRoot $root)
        Test-Path -LiteralPath $root | Should -BeFalse
    }
}

Context 'Write-SuiteHandoff' {
    It 'writes the file in the handoff folder as UTF-8 with no byte order mark' {
        $root = Join-Path $TestDrive 'w1'
        $r = Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json (New-PlanJson) -DataRoot $root
        $r.Ok | Should -BeTrue
        $r.Path | Should -Be (Join-Path $root 'sites\AB1\handoff\ring-plan.json')
        $bytes = [IO.File]::ReadAllBytes($r.Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Be (New-PlanJson)
    }
    It 'overwrites the previous file and leaves no temp file' {
        $root = Join-Path $TestDrive 'w2'
        [void](Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json (New-PlanJson -Created '2026-11-20T10:00:00Z') -DataRoot $root)
        $r = Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json (New-PlanJson -Created '2026-11-23T11:00:00Z') -DataRoot $root
        $r.Ok | Should -BeTrue
        (Get-Content -LiteralPath $r.Path -Raw) | Should -Match '2026-11-23T11:00:00Z'
        @(Get-ChildItem -LiteralPath (Split-Path $r.Path -Parent) -Force).Count | Should -Be 1
    }
    It 'keeps the old file whole when the new text is not valid' {
        $root = Join-Path $TestDrive 'w3'
        $first = Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json (New-PlanJson) -DataRoot $root
        $r = Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json '{ "Format": ' -DataRoot $root
        $r.Ok | Should -BeFalse
        (Get-Content -LiteralPath $first.Path -Raw) | Should -Be (New-PlanJson)
        @(Get-ChildItem -LiteralPath (Split-Path $first.Path -Parent) -Force).Count | Should -Be 1
    }
    It 'refuses text that is not an object' {
        $root = Join-Path $TestDrive 'w4'
        (Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json '[1,2]' -DataRoot $root).Ok | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'sites') | Should -BeFalse
    }
    It 'refuses a property that may hold a secret, at any depth' {
        $root = Join-Path $TestDrive 'w5'
        foreach ($name in 'Password', 'ApiKey', 'clientSecret', 'AuthToken', 'Credential', 'WebhookUrl') {
            $json = '{ "Format": "x", "SchemaVersion": 1, "Rings": [ { "Name": "a", "Inner": { "' + $name + '": "v" } } ] }'
            $r = Write-SuiteHandoff -SiteCode 'AB1' -Kind 'ring-plan' -Json $json -DataRoot $root
            $r.Ok | Should -BeFalse -Because $name
            $r.Message | Should -Match $name
        }
        Test-Path -LiteralPath (Join-Path $root 'sites') | Should -BeFalse
    }
    It 'does not throw for a bad site code' {
        $r = Write-SuiteHandoff -SiteCode 'bad site' -Kind 'ring-plan' -Json (New-PlanJson) -DataRoot (Join-Path $TestDrive 'w6')
        $r.Ok | Should -BeFalse
    }
}

Context 'Read-SuiteHandoff' {
    BeforeEach { $script:Path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json') }
    It 'reads the header and the age' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson), (New-Object Text.UTF8Encoding($false)))
        $r = Read-SuiteHandoff -Path $script:Path -ExpectedKind 'SuiteRingPlan' -NowUtc $script:Now
        $r.Status | Should -Be 'Ok'
        $r.Kind | Should -Be 'SuiteRingPlan'
        $r.SchemaVersion | Should -Be 1
        $r.ProducerName | Should -Be 'UpdatePlanner'
        $r.ProducerVersion | Should -Be '1.2.3'
        $r.SiteCode | Should -Be 'AB1'
        $r.CreatedUtc | Should -Be $script:Now.AddHours(-2)
        $r.AgeText | Should -Be '2 hours old'
        $r.IsStale | Should -BeFalse
        $r.Data.Name | Should -Be 'UpdatePlanner-a1'
    }
    It 'reads the header with the lower case names of the contract' {
        $json = '{ "kind": "ring-plan", "schemaVersion": 1, "producer": { "name": "UpdatePlanner", "version": "9" }, "createdUtc": "2026-11-23T11:30:00Z", "site": { "siteCode": "cd2" }, "items": [] }'
        [IO.File]::WriteAllText($script:Path, $json)
        $r = Read-SuiteHandoff -Path $script:Path -ExpectedKind 'ring-plan' -NowUtc $script:Now
        $r.Status | Should -Be 'Ok'
        $r.SiteCode | Should -Be 'CD2'
        $r.ProducerVersion | Should -Be '9'
        $r.AgeText | Should -Be '30 minutes old'
    }
    It 'reads the site of an old plan from the UpdatePlanner block' {
        $json = '{ "Format": "SuiteRingPlan", "SchemaVersion": 1, "CreatedUtc": "2026-11-23T11:59:30Z", "UpdatePlanner": { "SiteCode": "AB1" } }'
        [IO.File]::WriteAllText($script:Path, $json)
        $r = Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now
        $r.SiteCode | Should -Be 'AB1'
        $r.AgeText | Should -Be 'under 1 minute old'
    }
    It 'reports a missing file' {
        $r = Read-SuiteHandoff -Path (Join-Path $TestDrive 'nope.json')
        $r.Status | Should -Be 'Missing'
        $r.Data | Should -BeNullOrEmpty
    }
    It 'refuses a malformed file and says why' {
        foreach ($text in '{ "Format": ', '', 'not json', '[1,2,3]', '"text"', '42') {
            [IO.File]::WriteAllText($script:Path, $text)
            $r = Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now
            $r.Status | Should -Be 'Malformed' -Because "text: $text"
            $r.Message | Should -Match 'JSON'
            $r.Data | Should -BeNullOrEmpty
        }
    }
    It 'refuses a file of another kind' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Format 'Other'))
        $r = Read-SuiteHandoff -Path $script:Path -ExpectedKind 'SuiteRingPlan' -NowUtc $script:Now
        $r.Status | Should -Be 'WrongKind'
        $r.Data | Should -BeNullOrEmpty
    }
    It 'refuses a schema version above the known one and names the file and both versions' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Version 2))
        $r = Read-SuiteHandoff -Path $script:Path -ExpectedKind 'SuiteRingPlan' -KnownSchemaVersion 1 -NowUtc $script:Now
        $r.Status | Should -Be 'TooNew'
        $r.Message | Should -Match ([regex]::Escape((Split-Path $script:Path -Leaf)))
        $r.Message | Should -Match 'version 2'
        $r.Message | Should -Match 'version 1'
        $r.Data | Should -BeNullOrEmpty
    }
    It 'refuses a file with no schema version' {
        [IO.File]::WriteAllText($script:Path, '{ "Format": "SuiteRingPlan", "CreatedUtc": "2026-11-23T10:00:00Z" }')
        (Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now).Status | Should -Be 'Malformed'
    }
    It 'refuses a file with no valid creation time' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -NoCreated))
        (Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now).Status | Should -Be 'NoDate'
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Created 'yesterday'))
        (Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now).Status | Should -Be 'NoDate'
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Created '2026-11-23 10:00:00'))
        (Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now).Status | Should -Be 'NoDate'
    }
    It 'flags a stale file and does not refuse it' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Created '2026-11-18T12:00:00Z'))
        $r = Read-SuiteHandoff -Path $script:Path -ExpectedKind 'SuiteRingPlan' -StaleAfterHours 72 -NowUtc $script:Now
        $r.Status | Should -Be 'Ok'
        $r.IsStale | Should -BeTrue
        $r.AgeText | Should -Be '5 days old'
        $r.Data | Should -Not -BeNullOrEmpty
    }
    It 'applies the limit exactly: at the limit is fresh, one minute past it is stale' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Created '2026-11-20T12:00:00Z'))
        (Read-SuiteHandoff -Path $script:Path -StaleAfterHours 72 -NowUtc $script:Now).IsStale | Should -BeFalse
        (Read-SuiteHandoff -Path $script:Path -StaleAfterHours 72 -NowUtc $script:Now.AddMinutes(1)).IsStale | Should -BeTrue
    }
    It 'flags a file dated in the future as stale' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Created '2026-11-24T12:00:00Z'))
        $r = Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now
        $r.Status | Should -Be 'Ok'
        $r.IsStale | Should -BeTrue
        $r.AgeText | Should -Be 'dated in the future'
    }
    It 'flags a file for another site' {
        [IO.File]::WriteAllText($script:Path, (New-PlanJson -Site 'AB1'))
        (Read-SuiteHandoff -Path $script:Path -ActiveSite 'CD2' -NowUtc $script:Now).SiteMismatch | Should -BeTrue
        (Read-SuiteHandoff -Path $script:Path -ActiveSite 'AB1' -NowUtc $script:Now).SiteMismatch | Should -BeFalse
        (Read-SuiteHandoff -Path $script:Path -ActiveSite 'AB1~2' -NowUtc $script:Now).SiteMismatch | Should -BeFalse
        (Read-SuiteHandoff -Path $script:Path -NowUtc $script:Now).SiteMismatch | Should -BeFalse
    }
    It 'reads what the writer wrote' {
        $root = Join-Path $TestDrive 'rt'
        $w = Write-SuiteHandoff -SiteCode 'CD2' -Kind 'ring-plan' -Json (New-PlanJson -Site 'CD2') -DataRoot $root
        $r = Read-SuiteHandoff -Path $w.Path -ExpectedKind 'SuiteRingPlan' -ActiveSite 'CD2' -NowUtc $script:Now
        $r.Status | Should -Be 'Ok'
        $r.SiteMismatch | Should -BeFalse
    }
}

Context 'Age text and stale limit' {
    It 'formats the age' {
        Format-SuiteAge -Age ([timespan]::FromSeconds(10)) | Should -Be 'under 1 minute old'
        Format-SuiteAge -Age ([timespan]::FromMinutes(1)) | Should -Be '1 minute old'
        Format-SuiteAge -Age ([timespan]::FromMinutes(59)) | Should -Be '59 minutes old'
        Format-SuiteAge -Age ([timespan]::FromMinutes(60)) | Should -Be '1 hour old'
        Format-SuiteAge -Age ([timespan]::FromHours(47)) | Should -Be '47 hours old'
        Format-SuiteAge -Age ([timespan]::FromHours(48)) | Should -Be '2 days old'
        Format-SuiteAge -Age ([timespan]::FromDays(30)) | Should -Be '30 days old'
        Format-SuiteAge -Age ([timespan]::FromHours(-3)) | Should -Be 'dated in the future'
    }
    It 'turns the setting of the user into hours' {
        ConvertTo-SuiteStaleHours -Value 3 -Unit 'days' | Should -Be 72
        ConvertTo-SuiteStaleHours -Value 12 -Unit 'hours' | Should -Be 12
        ConvertTo-SuiteStaleHours -Value '2' -Unit 'Days' | Should -Be 48
        ConvertTo-SuiteStaleHours -Value 1 -Unit 'hours' | Should -Be 1
    }
    It 'gives the default for a value that is not valid' {
        foreach ($v in 0, -1, 10000, 'abc', '', $null, 1.5) { ConvertTo-SuiteStaleHours -Value $v -Unit 'days' | Should -Be 72 -Because "value: $v" }
        ConvertTo-SuiteStaleHours -Value 5 -Unit 'weeks' | Should -Be 72
        ConvertTo-SuiteStaleHours -Value 0 -Unit 'days' -Default 24 | Should -Be 24
    }
    It 'gives the age of a UTC time' {
        $a = Get-SuiteDataAge -CreatedUtc $script:Now.AddHours(-100) -StaleAfterHours 72 -NowUtc $script:Now
        $a.IsStale | Should -BeTrue
        $a.AgeText | Should -Be '4 days old'
        (Get-SuiteDataAge -CreatedUtc $script:Now.AddHours(-1) -StaleAfterHours 72 -NowUtc $script:Now).IsStale | Should -BeFalse
    }
}
}
