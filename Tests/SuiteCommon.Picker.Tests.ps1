#Requires -Modules Pester

<#
.SYNOPSIS
    Tests the result contract of Show-CollectionPickerDialog: a collection is
    returned only when the dialog closes through OK.

.DESCRIPTION
    WPF dialogs need an STA thread and a message loop. Each scenario runs in
    a child process started with -STA on the host that runs the tests; the
    child opens the real dialog, drives it from a DispatcherTimer (select a
    row, then click OK, click Cancel, or post the close-button command), and
    prints the name of the returned collection, or NONE.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:HostExe = (Get-Process -Id $PID).Path

    $script:Harness = Join-Path ([IO.Path]::GetTempPath()) ('picker-harness-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $script:Harness -Encoding ASCII -Value @'
param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][ValidateSet('Ok', 'Cancel', 'Close', 'CloseInCode')][string]$Mode)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($dll in 'Microsoft.Xaml.Behaviors.dll', 'ControlzEx.dll', 'MahApps.Metro.dll') {
    [void][System.Reflection.Assembly]::LoadFrom((Join-Path $RepoRoot "Lib\$dll"))
}
Import-Module (Join-Path $RepoRoot 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Add-Type -Namespace PickerHarness -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);'

$owner = New-Object System.Windows.Window
$owner.Width = 300; $owner.Height = 200; $owner.Left = 60; $owner.Top = 60
$owner.WindowStartupLocation = 'Manual'
Initialize-SuiteTheme -Window $owner -IsDarkGetter { $true }
$owner.Show()

$collections = @(
    [pscustomobject]@{ Name = 'Alpha'; CollectionID = 'TST00001'; FolderID = 0; MemberCount = 3; IsBuiltIn = $false }
    [pscustomobject]@{ Name = 'Beta';  CollectionID = 'TST00002'; FolderID = 0; MemberCount = 5; IsBuiltIn = $false }
)

$script:tick = 0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    $dlg = $owner.OwnedWindows | Select-Object -First 1
    if (-not $dlg) { return }
    $script:tick++
    $tree = $dlg.FindName('treePicker')
    if ($script:tick -eq 1) {
        $tree.Items[1].IsSelected = $true
        return
    }
    $timer.Stop()
    $click = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
    switch ($Mode) {
        'Ok'     { $dlg.FindName('btnOk').RaiseEvent($click) }
        'Cancel' { $dlg.FindName('btnCancel').RaiseEvent($click) }
        'Close'  {
            # The close button and Alt+F4 both reach the window as SC_CLOSE.
            $handle = (New-Object System.Windows.Interop.WindowInteropHelper($dlg)).Handle
            [void][PickerHarness.Native]::PostMessage($handle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)
        }
        'CloseInCode' { $dlg.Close() }
    }
})
$guard = New-Object System.Windows.Threading.DispatcherTimer
$guard.Interval = [TimeSpan]::FromSeconds(30)
$guard.Add_Tick({ $guard.Stop(); foreach ($w in @($owner.OwnedWindows)) { $w.Close() } })
$guard.Start()
$timer.Start()

$picked = Show-CollectionPickerDialog -Owner $owner -Collections $collections -Folders @()
$guard.Stop()
$owner.Close()
if ($picked) { 'PICKED:' + $picked.Name } else { 'NONE' }
'@

    function Invoke-PickerScenario {
        param([string]$Mode)
        $stdout = Join-Path ([IO.Path]::GetTempPath()) ('picker-out-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $stderr = $stdout + '.err'
        try {
            $p = Start-Process -FilePath $script:HostExe -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList @(
                '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:Harness + '"'), '-RepoRoot', ('"' + $script:RepoRoot + '"'), '-Mode', $Mode)
            if (-not $p.WaitForExit(90000)) { $p.Kill(); throw 'picker scenario timed out' }
            $lines = @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(PICKED:|NONE$)' })
            if ($lines.Count -eq 0) { throw ('picker scenario printed no result. stderr: ' + ((Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))) }
            $lines[-1]
        }
        finally { Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue }
    }
}

AfterAll {
    if ($script:Harness) { Remove-Item -LiteralPath $script:Harness -Force -ErrorAction SilentlyContinue }
}

Describe 'Show-CollectionPickerDialog result' {
    It 'returns the highlighted collection when OK is clicked' {
        Invoke-PickerScenario -Mode Ok | Should -Be 'PICKED:Beta'
    }

    It 'returns nothing when Cancel is clicked after a row is highlighted' {
        Invoke-PickerScenario -Mode Cancel | Should -Be 'NONE'
    }

    It 'returns nothing when the close button or Alt+F4 closes the dialog after a row is highlighted' {
        Invoke-PickerScenario -Mode Close | Should -Be 'NONE'
    }

    It 'returns nothing when the dialog is closed in code after a row is highlighted' {
        Invoke-PickerScenario -Mode CloseInCode | Should -Be 'NONE'
    }
}
