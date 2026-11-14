#Requires -Modules Pester

<#
.SYNOPSIS
    Guard for the contrast of the SuiteCommon palette: every text and border pair of the shared brushes
    reaches WCAG AA. Text needs 4.5:1, a control border or a boundary needs 3:1.

.DESCRIPTION
    The test reads the hex colors of Initialize-SuiteTheme from the module text and does the math. It
    creates no window. The backdrops are the MahApps window backgrounds: #252525 in the dark theme and
    #FFFFFF in the light theme.
#>

BeforeAll {
    $script:Text = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'SuiteCommon\SuiteCommon.psm1'))

    function Get-Palette {
        param([string]$Source)
        $m = [regex]::Match($Source, '(?s)function Initialize-SuiteTheme.*?\$b = @\{(.*?)\}')
        $pal = @{}
        if (-not $m.Success) { return $pal }
        foreach ($l in [regex]::Matches($m.Groups[1].Value, "(\w+)\s*=\s*\`$bc\.ConvertFrom\('(#[0-9A-Fa-f]{6})'\)")) { $pal[$l.Groups[1].Value] = $l.Groups[2].Value }
        $pal
    }
    function ConvertTo-Luminance {
        param([string]$Hex)
        $c = foreach ($i in 1, 3, 5) { $v = [Convert]::ToInt32($Hex.Substring($i, 2), 16) / 255.0; if ($v -le 0.03928) { $v / 12.92 } else { [math]::Pow(($v + 0.055) / 1.055, 2.4) } }
        0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
    }
    function Get-Ratio {
        param([string]$A, [string]$B)
        $la = ConvertTo-Luminance $A; $lb = ConvertTo-Luminance $B
        (([math]::Max($la, $lb)) + 0.05) / (([math]::Min($la, $lb)) + 0.05)
    }
    $script:Pal = Get-Palette -Source $script:Text
    $script:DarkBack = '#252525'
    $script:LightBack = '#FFFFFF'
}

Describe 'SuiteCommon palette contrast' {
    It 'reads the palette (non-empty scan)' {
        $script:Pal.Count | Should -BeGreaterOrEqual 15
        $script:Pal['OnBlue'] | Should -Be '#FFFFFF'
    }

    It 'computes known ratios (the check itself)' {
        [math]::Round((Get-Ratio '#000000' '#FFFFFF'), 1) | Should -Be 21.0
        [math]::Round((Get-Ratio '#FFFFFF' '#4BA3E0'), 2) | Should -BeLessThan 4.5
    }

    It 'gives white text 4.5:1 on <Name>' -ForEach @(
        @{ Name = 'TitleBarActive' }, @{ Name = 'TitleBarInactive' }, @{ Name = 'DarkTitleBarInactive' },
        @{ Name = 'LightWfBg' }, @{ Name = 'LightActiveBg' }, @{ Name = 'LightOptBg' }
    ) {
        $script:Pal.ContainsKey($Name) | Should -BeTrue
        (Get-Ratio $script:Pal['OnBlue'] $script:Pal[$Name]) | Should -BeGreaterOrEqual 4.5
    }

    It 'shows the log label with 4.5:1 on its backdrop' {
        (Get-Ratio $script:Pal['LogLabelDark'] $script:DarkBack) | Should -BeGreaterOrEqual 4.5
        (Get-Ratio $script:Pal['LogLabelLight'] $script:LightBack) | Should -BeGreaterOrEqual 4.5
    }

    It 'shows a button border with 3:1 on <Pair>' -ForEach @(
        @{ Pair = 'DarkButtonBorder on the dark window'; A = 'DarkButtonBorder'; Back = '#252525' }
        @{ Pair = 'DarkButtonBorder on the dark button'; A = 'DarkButtonBorder'; Back = 'DarkButtonBg' }
        @{ Pair = 'DarkActiveBorder on the dark active button'; A = 'DarkActiveBorder'; Back = 'DarkActiveBg' }
    ) {
        $back = $(if ($Back.StartsWith('#')) { $Back } else { $script:Pal[$Back] })
        (Get-Ratio $script:Pal[$A] $back) | Should -BeGreaterOrEqual 3.0
    }

    It 'flags a palette entry under the limit (bad sample)' {
        $bad = Get-Palette -Source ('function Initialize-SuiteTheme { $b = @{ X = $bc.ConvertFrom(''#4BA3E0'') } }')
        (Get-Ratio '#FFFFFF' $bad['X']) | Should -BeLessThan 4.5
    }
}
