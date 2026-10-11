<#
.SYNOPSIS
    STA smoke test for the shared title-bar handlers: a real double-click on
    the title bar of a resizable MetroWindow toggles Maximized and back; the
    same double-click on a NoResize window leaves it Normal.

.DESCRIPTION
    Shows two MetroWindows with Install-TitleBarDragFallback applied and
    drives them with real mouse input (SetCursorPos + mouse_event), so both
    the native hit-test hook path and the WPF preview path are exercised the
    way a user does it. Exit code 0 when every expectation holds.

    Run under Windows PowerShell 5.1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File Tests\Invoke-TitleBarSmoke.ps1
#>
[CmdletBinding()]
param(
    [string]$LibPath
)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside a param default under 5.1 with -File.
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $LibPath) { $LibPath = Join-Path $repoRoot 'Lib' }
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this script with -STA.'
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
foreach ($dll in 'ControlzEx.dll', 'Microsoft.Xaml.Behaviors.dll', 'MahApps.Metro.dll') {
    Add-Type -Path (Join-Path $LibPath $dll)
}
Import-Module (Join-Path $repoRoot 'SuiteCommon\SuiteCommon.psd1') -Force -DisableNameChecking -WarningAction SilentlyContinue

Add-Type -Namespace TitleBarSmoke -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
[DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
'@

function Send-DoubleClick {
    param([System.Windows.Window]$Window)
    # 15 px below the top edge, centred: inside the drag band (4..TitleBarHeight)
    # and away from the caption buttons.
    $pt = $Window.PointToScreen([System.Windows.Point]::new($Window.ActualWidth / 2, 15))
    [void][TitleBarSmoke.Native]::SetCursorPos([int]$pt.X, [int]$pt.Y)
    $gap = [Math]::Min(80, [int]([TitleBarSmoke.Native]::GetDoubleClickTime() / 4))
    foreach ($i in 1, 2) {
        [TitleBarSmoke.Native]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 20
        [TitleBarSmoke.Native]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds $gap
    }
}

function Send-Drag {
    param([System.Windows.Window]$Window)
    $pt = $Window.PointToScreen([System.Windows.Point]::new($Window.ActualWidth / 2, 15))
    [void][TitleBarSmoke.Native]::SetCursorPos([int]$pt.X, [int]$pt.Y)
    [TitleBarSmoke.Native]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    foreach ($i in 1..6) {
        Start-Sleep -Milliseconds 30
        [void][TitleBarSmoke.Native]::SetCursorPos([int]$pt.X + 10 * $i, [int]$pt.Y + 5 * $i)
        [TitleBarSmoke.Native]::mouse_event(0x0001, 10, 5, 0, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 30
    [TitleBarSmoke.Native]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function New-SmokeWindow {
    param([string]$Title, [System.Windows.ResizeMode]$ResizeMode)
    $w = New-Object MahApps.Metro.Controls.MetroWindow
    $w.Title = $Title
    $w.Width = 640; $w.Height = 400
    $w.Left = 200; $w.Top = 200
    $w.ResizeMode = $ResizeMode
    $w.WindowStartupLocation = 'Manual'
    $w.Topmost = $true
    # The same MahApps dictionaries every suite window merges; without them
    # the title bar has no template to hit.
    foreach ($src in 'Controls.xaml', 'Fonts.xaml', 'Themes/Dark.Steel.xaml') {
        $rd = New-Object System.Windows.ResourceDictionary
        $rd.Source = [Uri]('pack://application:,,,/MahApps.Metro;component/Styles/' + $src)
        $w.Resources.MergedDictionaries.Add($rd)
    }
    $w.Content = New-Object System.Windows.Controls.Grid
    if ($env:TITLEBAR_SMOKE_TRACE) {
        $w.Add_PreviewMouseLeftButtonDown({ param($s, $e) Write-Host ('    preview down ClickCount={0} at {1}' -f $e.ClickCount, $e.GetPosition($s)) })
        $w.Add_SourceInitialized({
            param($s, $e)
            $src = [System.Windows.Interop.HwndSource]::FromHwnd(([System.Windows.Interop.WindowInteropHelper]::new($s)).Handle)
            $src.AddHook([System.Windows.Interop.HwndSourceHook]{
                param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
                if ($msg -in 0x00A1, 0x00A3, 0x0201, 0x0203) { Write-Host ('    msg 0x{0:X4} wParam={1}' -f $msg, $wParam.ToInt64()) }
                return [IntPtr]::Zero
            })
        })
    }
    Install-TitleBarDragFallback -Window $w
    return $w
}

function Invoke-WindowCase {
    param([string]$Name, [System.Windows.ResizeMode]$ResizeMode, [string[]]$Expected, [switch]$DragFirst)
    $w = New-SmokeWindow -Title $Name -ResizeMode $ResizeMode
    $seen = New-Object System.Collections.Generic.List[string]
    # A closure copies captured scalars, so the counter lives in a hashtable.
    $ctx = @{ Step = 0 }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(700)
    $timer.Add_Tick({
        $ctx.Step++
        # Synthetic input is pumped only after this tick returns, so every
        # action gets its own tick and is measured on the next one.
        if ($DragFirst -and $ctx.Step -eq 1) {
            $ctx.Before = [System.Windows.Point]::new($w.Left, $w.Top)
            Send-Drag -Window $w
            return
        }
        if ($ctx.Step -le 2 + [int][bool]$DragFirst) {
            if ($DragFirst -and $ctx.Step -eq 2) {
                $ctx.Moved = ($w.Left -ne $ctx.Before.X -or $w.Top -ne $ctx.Before.Y)
                Write-Host ('  dragged [{0}]: moved={1}' -f $w.Title, $ctx.Moved)
            }
            Send-DoubleClick -Window $w
            Write-Host ('  sent double-click {0} to [{1}]; state now {2}' -f $ctx.Step, $w.Title, $w.WindowState)
            return
        }
        $timer.Stop()
        $w.Close()
    }.GetNewClosure())
    # WindowState is read on the tick after each double-click, once the
    # input has been pumped.
    $w.Add_StateChanged({ $seen.Add([string]$w.WindowState) }.GetNewClosure())
    # ContentRendered does not fire for an empty window; the timer ticks
    # once ShowDialog pumps the dispatcher.
    $timer.Start()
    # Watchdog: the case must end even when no tick runs.
    $guard = New-Object System.Windows.Threading.DispatcherTimer
    $guard.Interval = [TimeSpan]::FromSeconds(8)
    $guard.Add_Tick({ $guard.Stop(); $timer.Stop(); try { $w.Close() } catch { $null = $_ } }.GetNewClosure())
    $guard.Start()
    [void]$w.ShowDialog()
    $got = @($seen)
    $ok = (($got -join ',') -eq ($Expected -join ',')) -and (-not $DragFirst -or $ctx.Moved)
    Write-Host ('{0} [{1}]: states after two double-clicks = [{2}] expected [{3}]' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Name, ($got -join ','), ($Expected -join ','))
    return $ok
}

$results = @(
    (Invoke-WindowCase -Name 'Resizable window' -ResizeMode CanResize -Expected @('Maximized', 'Normal'))
    (Invoke-WindowCase -Name 'NoResize dialog' -ResizeMode NoResize -Expected @())
    (Invoke-WindowCase -Name 'Drag then double-click' -ResizeMode CanResize -Expected @('Maximized', 'Normal') -DragFirst)
)
if ($results -contains $false) { exit 1 }
exit 0
