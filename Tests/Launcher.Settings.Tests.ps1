#Requires -Modules Pester

<#
.SYNOPSIS
    Tests that the launcher reports a failed settings write instead of
    claiming the connection profile or the theme choice was saved.

.DESCRIPTION
    start-suite.ps1 is a window script, so the helper under test is lifted
    out of its AST. Save-SuiteSettings returns $false on a failed write and
    never throws; the helper turns that into a result with a user message.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:LauncherPath = Join-Path $script:RepoRoot 'start-suite.ps1'
    Get-Module SuiteCommon | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking -WarningAction SilentlyContinue

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-LauncherSettings' }, $true) | Select-Object -First 1
    if (-not $fn) { throw 'Save-LauncherSettings is missing from start-suite.ps1' }
    . ([scriptblock]::Create($fn.Extent.Text))
}

AfterAll {
    Get-Module SuiteCommon | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Save-LauncherSettings' {
    BeforeEach {
        $global:Prefs = @{ SiteCode = 'ABC'; SMSProvider = 'cm01.example.test'; DarkMode = $true }
    }

    It 'reports success and writes the file when the path is writable' {
        $script:SettingsPath = Join-Path $TestDrive 'ok\suite.settings.json'
        $result = Save-LauncherSettings -Subject 'Connection profile'
        $result.Saved | Should -BeTrue
        $result.Message | Should -Be ''
        (Get-Content -LiteralPath $script:SettingsPath -Raw) | Should -Match 'cm01\.example\.test'
    }

    It 'reports failure with the path when the settings file is read-only' {
        $script:SettingsPath = Join-Path $TestDrive 'readonly.settings.json'
        Set-Content -LiteralPath $script:SettingsPath -Value '{ "SiteCode": "OLD" }' -Encoding ASCII
        Set-ItemProperty -LiteralPath $script:SettingsPath -Name IsReadOnly -Value $true
        try {
            $result = Save-LauncherSettings -Subject 'Connection profile'
            $result.Saved | Should -BeFalse
            $result.Message | Should -BeLike 'Connection profile not saved: cannot write *readonly.settings.json*'
            (Get-Content -LiteralPath $script:SettingsPath -Raw) | Should -Match 'OLD'
        }
        finally { Set-ItemProperty -LiteralPath $script:SettingsPath -Name IsReadOnly -Value $false }
    }

    It 'reports failure when the folder of the settings file cannot be created' {
        $blocker = Join-Path $TestDrive 'blocker'
        Set-Content -LiteralPath $blocker -Value 'a file, not a folder' -Encoding ASCII
        $script:SettingsPath = Join-Path $blocker 'suite.settings.json'
        $result = Save-LauncherSettings -Subject 'Theme choice'
        $result.Saved | Should -BeFalse
        $result.Message | Should -BeLike 'Theme choice not saved:*'
    }
}

Describe 'start-suite.ps1 settings handlers' {
    BeforeAll {
        $script:Source = Get-Content -LiteralPath $script:LauncherPath -Raw
    }

    It 'never discards the result of a settings write' {
        $script:Source | Should -Not -Match '\$null\s*=\s*Save-SuiteSettings'
        $script:Source | Should -Not -Match '\[void\]\s*\(?Save-SuiteSettings'
    }

    It 'reports the saved message only after a successful write' {
        $script:Source | Should -Match '(?s)if \(\$result\.Saved\) \{\s*Set-SuiteStatus ''Connection profile saved'
    }
}
