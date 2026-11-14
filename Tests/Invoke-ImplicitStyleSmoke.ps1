<#
.SYNOPSIS
    STA smoke test for Add-SuiteImplicitStyle: a text box and a combo box of a themed window show the Gray2
    border, a column header of a disabled grid shows the gray text, and a window with its own style keeps it.

.DESCRIPTION
    Shows MetroWindows off screen. The window tests run only on the lab or in CI (SUITE_ALLOW_WINDOW_TESTS=1).
    SUITE_VISIBLE_WINDOWS=1 puts the windows at 80,80 and keeps each one on screen for about two seconds, for the visible run
    of the lab (Run-VisibleProbe.ps1, labadmin session of CLIENT01). Without it the windows sit at -32000.
    Exit code 0 when every expectation holds.

    Run under Windows PowerShell 5.1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File Tests\Invoke-ImplicitStyleSmoke.ps1
#>
[CmdletBinding()]
param([string]$LibPath)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if ($env:SUITE_ALLOW_WINDOW_TESTS -ne '1') { Write-Host 'SKIP: SUITE_ALLOW_WINDOW_TESTS is not 1.'; exit 0 }
if (-not $LibPath) { $LibPath = Join-Path $repoRoot 'Lib' }
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Run this script with -STA.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
foreach ($dll in 'ControlzEx.dll', 'Microsoft.Xaml.Behaviors.dll', 'MahApps.Metro.dll') { Add-Type -Path (Join-Path $LibPath $dll) }
Import-Module (Join-Path $repoRoot 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking -WarningAction SilentlyContinue

$script:Checks = 0
function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    $script:Checks++
    Write-Host ('  ok  ' + $Message)
}

function New-ProbeWindow {
    param([string]$OwnTextBoxStyle = '')
    $xaml = @"
<Controls:MetroWindow xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Probe" Width="500" Height="400" WindowStartupLocation="Manual">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            $OwnTextBoxStyle
        </ResourceDictionary>
    </Window.Resources>
    <StackPanel>
        <TextBox x:Name="box" Text="a"/>
        <ComboBox x:Name="combo"/>
        <DataGrid x:Name="grid" AutoGenerateColumns="False"><DataGrid.Columns><DataGridTextColumn Header="Name"/></DataGrid.Columns></DataGrid>
    </StackPanel>
</Controls:MetroWindow>
"@
    [xml]$x = $xaml
    [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
}

function Show-Offscreen {
    param($Window)
    # SUITE_VISIBLE_WINDOWS=1 (the visible lab run) puts the window on the desktop and keeps it there for a moment.
    if ($env:SUITE_VISIBLE_WINDOWS -eq '1') { $Window.Left = 80; $Window.Top = 80; $Window.WindowStartupLocation = 'Manual' } else { $Window.Left = -32000; $Window.Top = -32000; $Window.ShowInTaskbar = $false }
    $Window.Show()
    $passes = $(if ($env:SUITE_VISIBLE_WINDOWS -eq '1') { 40 } else { 4 })
    for ($i = 0; $i -lt $passes; $i++) { $Window.UpdateLayout(); $Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle); Start-Sleep -Milliseconds 50 }
}

function Get-Hex { param($Brush) if ($Brush -is [System.Windows.Media.SolidColorBrush]) { return $Brush.Color.ToString() } return '' }

foreach ($theme in 'Dark.Steel', 'Light.Blue') {
    Write-Host $theme
    $w = New-ProbeWindow
    $global:ImplicitProbeDark = ($theme -eq 'Dark.Steel')
    Initialize-SuiteTheme -Window $w -IsDarkGetter { [bool]$global:ImplicitProbeDark }
    Set-DialogTheme -Dialog $w -IsDark $global:ImplicitProbeDark
    Show-Offscreen $w
    try {
        $gray2 = Get-Hex ($w.TryFindResource('MahApps.Brushes.Gray2'))
        Assert-That ((Get-Hex $w.FindName('box').BorderBrush) -eq $gray2) "$theme text box border is Gray2 ($gray2)"
        Assert-That ((Get-Hex $w.FindName('combo').BorderBrush) -eq $gray2) "$theme combo box border is Gray2"
        $grid = $w.FindName('grid')
        $grid.IsEnabled = $false
        for ($i = 0; $i -lt 3; $i++) { $w.UpdateLayout(); $w.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) }
        $header = $null
        $stack = New-Object System.Collections.Generic.Stack[System.Windows.DependencyObject]; $stack.Push($grid)
        while ($stack.Count -gt 0 -and -not $header) {
            $n = $stack.Pop()
            if ($n -is [System.Windows.Controls.Primitives.DataGridColumnHeader]) { $header = $n; break }
            for ($i = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n) - 1; $i -ge 0; $i--) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) }
        }
        Assert-That ($null -ne $header) "$theme the grid has a column header"
        $muted = Get-Hex ($w.TryFindResource('MahApps.Brushes.Gray.MouseOver'))
        Assert-That ((Get-Hex $header.Foreground) -eq $muted) "$theme disabled column header text is Gray.MouseOver ($muted)"
    }
    finally { $w.Close() }
}

Write-Host 'Own style'
$own = '<Style TargetType="TextBox" BasedOn="{StaticResource MahApps.Styles.TextBox}"><Setter Property="BorderBrush" Value="Red"/></Style>'
$w = New-ProbeWindow -OwnTextBoxStyle $own
$global:ImplicitProbeDark = $false
Initialize-SuiteTheme -Window $w -IsDarkGetter { [bool]$global:ImplicitProbeDark }
Set-DialogTheme -Dialog $w -IsDark $false
Show-Offscreen $w
try {
    Assert-That ((Get-Hex $w.FindName('box').BorderBrush) -eq '#FFFF0000') 'a window with its own TextBox style keeps it'
    Assert-That ((Get-Hex $w.FindName('combo').BorderBrush) -ne '#FFFF0000') 'the combo box still takes the shared style'
}
finally { $w.Close() }

Write-Host ''
Write-Host ('PASS: implicit style smoke, {0} checks' -f $script:Checks)
