#requires -Module Pester
<#
.SYNOPSIS
    Headless tests for the SuiteCommon window test helpers: the contrast math and the
    export list. The state and chrome reports need a shown window and run in the
    window tests of each app.
#>

BeforeAll {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking
}

Describe 'Window test helpers' {
    It 'exports every helper' {
        foreach ($n in 'Get-SuiteContrastRatio', 'Get-SuiteVisualDescendant', 'Test-SuiteVisibleInTree', 'Get-SuiteButtonRow', 'Get-SuiteWindowChrome', 'Get-SuiteButtonStateReport', 'Get-SuiteWindowBody', 'Get-SuiteRelativeLuminance', 'Close-SuiteOpenWindow') {
            Get-Command -Module SuiteCommon -Name $n -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $n
        }
    }

    It 'gives 21:1 for black on white and 1:1 for equal colors' {
        $black = [System.Windows.Media.Colors]::Black
        $white = [System.Windows.Media.Colors]::White
        [math]::Round((Get-SuiteContrastRatio -Foreground $black -Background $white), 1) | Should -Be 21
        [math]::Round((Get-SuiteContrastRatio -Foreground $white -Background $black), 1) | Should -Be 21
        [math]::Round((Get-SuiteContrastRatio -Foreground $white -Background $white), 1) | Should -Be 1
    }

    It 'measures the gray border color of the suite buttons against white' {
        $gray = [System.Windows.Media.Color]::FromRgb(0x7F, 0x7F, 0x7F)
        (Get-SuiteContrastRatio -Foreground $gray -Background ([System.Windows.Media.Colors]::White)) | Should -BeGreaterThan 3
    }
}
