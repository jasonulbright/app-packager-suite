<#
.SYNOPSIS
    Shared logic of the CLIENT01 real-window harness (Q-118, D-16): lock decisions, ledger stop, stray-window check, run snapshot.

.DESCRIPTION
    Dot-sourced by tools\Run-VisibleProbe.ps1 on the dev PC (lock decisions) and copied to the lab computer, where the run wrapper
    dot-sources it inside the interactive labadmin session (window checks and snapshot). Pure functions take plain records, so Pester
    tests cover them without a window. Nothing here selects a process by command line, signs out, locks or disconnects a session.
    The file is plain ASCII.
#>

# ---- Lock (C:\guide\capture.lock, text owner|pid|start time) ----

# Parses the lock text. Returns $null when the text is not owner|pid|start time.
function ConvertFrom-LockText {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if ($t -notmatch '^(?<owner>[^|\s][^|]*)\|(?<pid>\d+)\|(?<start>\d{4}-\d{2}-\d{2}T.*)$') { return $null }
    [pscustomobject]@{ Owner = $Matches['owner']; ProcessId = [int]$Matches['pid']; Start = $Matches['start']; Text = $t }
}

# Decides what a waiting run does with a lock it found. unknown: another format, never removed. stale: older than StaleMinutes AND
# the owner pid runs neither on the lab computer nor on the dev PC. held: wait.
function Get-LockDecision {
    param([string]$Text, [int]$AgeMinutes, [bool]$AliveLab, [bool]$AliveHere, [int]$StaleMinutes = 30)
    if (-not (ConvertFrom-LockText -Text $Text)) { return 'unknown' }
    if ($AgeMinutes -gt $StaleMinutes -and -not $AliveLab -and -not $AliveHere) { return 'stale' }
    'held'
}

# One line that says who holds the lock and for how long, for the log of a waiting run.
function Format-LockHolder {
    param([string]$Text, [int]$AgeMinutes)
    $l = ConvertFrom-LockText -Text $Text
    if (-not $l) { return ('lock holder unknown (text: ' + ([string]$Text).Trim() + ')') }
    'lock held by {0} (pid {1}, since {2}, last refresh {3} min ago)' -f $l.Owner, $l.ProcessId, $l.Start, $AgeMinutes
}

# ---- Ledger (one line per process of a run: process id|start ticks) ----

function Read-LedgerEntry {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '^\d+\|\d+$' } | ForEach-Object { $a = $_ -split '\|'; [pscustomobject]@{ Id = [int]$a[0]; Ticks = [long]$a[1] } })
}

# Stops the processes that one ledger names, and no other process. A process is stopped only when its id and its start time both match
# the ledger line; the match and the stop use one open handle. Nothing is found through a parent id: Windows uses process ids again, so
# an older, unrelated process can name the id of a recorded process as its parent. What a run starts ends with its job object
# (tools\ProcessJob.ps1). Returns one text line per stopped process.
function Stop-LedgerProcess {
    param([Parameter(Mandatory)][string]$Ledger)
    foreach ($e in @(Read-LedgerEntry -Path $Ledger)) {
        $p = Get-Process -Id $e.Id -ErrorAction SilentlyContinue
        if (-not $p -or $p.Id -eq $PID) { continue }
        try {
            # The handle is opened first: from here on the object names one process, also when the id is used again.
            $null = $p.Handle
            if ($p.StartTime.Ticks -ne $e.Ticks) { continue }
            $name = $p.ProcessName
            $p.Kill()
            'pid {0}: {1}' -f $e.Id, $name
        }
        catch { Write-Verbose ('pid {0} was not stopped: {1}' -f $e.Id, $_.Exception.Message) }
    }
}

# Ends the run of one run folder. The ledger <Dir>\.pids names the launcher, which owns the job of the run. The launcher is asked to
# end the run (file <Dir>\.stop). A launcher that does not answer is stopped by its ledger line; its job then closes and Windows ends
# the members. Returns one text line per process that this function stopped itself.
function Stop-LabRun {
    param([Parameter(Mandatory)][string]$Dir, [int]$WaitSeconds = 30)
    $ledger = Join-Path $Dir '.pids'
    $entries = @(Read-LedgerEntry -Path $ledger)
    if (-not $entries.Count) { return }
    $done = Join-Path $Dir '.done'
    if (-not (Test-Path -LiteralPath $done)) {
        Set-Content -LiteralPath (Join-Path $Dir '.stop') -Value 'stop' -Encoding Ascii
        $until = (Get-Date).AddSeconds($WaitSeconds)
        while (-not (Test-Path -LiteralPath $done) -and (Get-Date) -lt $until) {
            $alive = @($entries | Where-Object { $p = Get-Process -Id $_.Id -ErrorAction SilentlyContinue; $p -and $p.StartTime.Ticks -eq $_.Ticks })
            if (-not $alive.Count) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    Stop-LedgerProcess -Ledger $ledger
}

# Finds every ledger that a run of the harness or of a guide capture left under the root: <root>\*\.pids and <root>\*\ui\run.pids.
function Get-LedgerPath {
    param([string]$Root = 'C:\guide')
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($p in @((Join-Path $_.FullName '.pids'), (Join-Path $_.FullName 'ui\run.pids'))) { if (Test-Path -LiteralPath $p) { $p } }
        })
}

# ---- Application windows ----

# True for a window that an app of the suite or its test harness opens: a WPF window, a WinForms window, or a dialog box (#32770)
# of a PowerShell process. Console windows, the shell and other programs of the user are never selected.
function Select-AppWindow {
    param([Parameter(ValueFromPipeline)]$Window)
    process {
        if (-not $Window.Visible) { return }
        $c = [string]$Window.Class
        $ps = [string]$Window.Process -in 'powershell', 'pwsh', 'powershell_ise'
        if ($c -like 'HwndWrapper[[]*' -or $c -like 'WindowsForms10.*' -or ($c -eq '#32770' -and $ps)) { $Window }
    }
}

# Lists the visible top-level windows of the current desktop. Run it in the interactive session: a service session has no windows.
function Get-DesktopWindow {
    if (-not ('LabHarness.Win' -as [type])) {
        Add-Type -Namespace LabHarness -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
'@
    }
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [LabHarness.Win+EnumProc] {
        param($h, $l)
        $cls = New-Object System.Text.StringBuilder 256
        $ttl = New-Object System.Text.StringBuilder 512
        [void][LabHarness.Win]::GetClassName($h, $cls, 256)
        [void][LabHarness.Win]::GetWindowText($h, $ttl, 512)
        $winPid = [uint32]0
        [void][LabHarness.Win]::GetWindowThreadProcessId($h, [ref]$winPid)
        $proc = Get-Process -Id ([int]$winPid) -ErrorAction SilentlyContinue
        $list.Add([pscustomobject]@{ Handle = $h; ProcessId = [int]$winPid; Process = $(if ($proc) { $proc.ProcessName } else { '' }); Class = $cls.ToString(); Title = $ttl.ToString(); Visible = [LabHarness.Win]::IsWindowVisible($h) })
        $true
    }
    [void][LabHarness.Win]::EnumWindows($cb, [IntPtr]::Zero)
    $list.ToArray()
}

# The app windows on the desktop right now, except those of the given process ids.
function Get-StrayAppWindow {
    param([int[]]$ExcludeProcessId = @())
    @(Get-DesktopWindow | Select-AppWindow | Where-Object { $ExcludeProcessId -notcontains $_.ProcessId })
}

# Asks windows to close (WM_CLOSE). A window of a process that is gone needs nothing.
function Close-AppWindow {
    param($Window)
    foreach ($w in @($Window)) { if ($w) { [void][LabHarness.Win]::PostMessage($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } }
}

function Format-WindowList {
    param($Window)
    $w = @($Window | Where-Object { $_ })
    if (-not $w.Count) { return 'none' }
    ($w | ForEach-Object { '[pid {0} {1} {2} "{3}"]' -f $_.ProcessId, $_.Process, $_.Class, $_.Title }) -join ' '
}

# ---- Run snapshot: who, which desktop theme, which windows ----

# The Windows theme of the interactive user (1 = light, 0 = dark). An app theme comes from the test; the Windows theme is the other
# source of a dark dialog in a light run, so both ends of a run record it.
function Get-LabThemeInfo {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $apps = (Get-ItemProperty -LiteralPath $k -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    $sys = (Get-ItemProperty -LiteralPath $k -Name SystemUsesLightTheme -ErrorAction SilentlyContinue).SystemUsesLightTheme
    [pscustomobject]@{ AppsUseLightTheme = $apps; SystemUsesLightTheme = $sys }
}

function Format-RunSnapshot {
    param([string]$Phase, [string]$Run, [string]$User, [int]$SessionId, $Theme, $Window)
    'HARNESS {0}: {1} run={2} user={3} session={4} AppsUseLightTheme={5} SystemUsesLightTheme={6} windows={7}' -f
    $Phase, (Get-Date -Format 's'), $Run, $User, $SessionId, $Theme.AppsUseLightTheme, $Theme.SystemUsesLightTheme, (Format-WindowList -Window $Window)
}

# Appends the snapshot line to the run output. Returns the line.
function Write-RunSnapshot {
    param([string]$Phase, [string]$Run, [string]$Path)
    $line = Format-RunSnapshot -Phase $Phase -Run $Run -User ([Environment]::UserName) -SessionId ([Diagnostics.Process]::GetCurrentProcess().SessionId) -Theme (Get-LabThemeInfo) -Window (Get-StrayAppWindow)
    Add-Content -LiteralPath $Path -Value $line -Encoding Ascii
    $line
}

# The preflight of a run, inside the interactive session: no app window of another process may be open. With -Close the windows get
# a close request first and are checked again. Returns the windows that remain (the run must not start when any remain).
function Test-DesktopClean {
    param([switch]$Close, [int[]]$ExcludeProcessId = @($PID), [int]$WaitSeconds = 3)
    $stray = @(Get-StrayAppWindow -ExcludeProcessId $ExcludeProcessId)
    if ($stray.Count -and $Close) { Close-AppWindow -Window $stray; Start-Sleep -Seconds $WaitSeconds; $stray = @(Get-StrayAppWindow -ExcludeProcessId $ExcludeProcessId) }
    $stray
}
