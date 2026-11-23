<#
.SYNOPSIS
    Runs a command from a copied repo in the interactive labadmin session (session 2) of CLIENT01, so that the windows show on screen.

.DESCRIPTION
    The default way to run a window test, probe, smoke script or capture. It copies the repo to C:\guide\visible-<folder>,
    registers a scheduled task for the logged-on lab user (interactive logon), runs the command with
    SUITE_ALLOW_WINDOW_TESTS=1 and SUITE_VISIBLE_WINDOWS=1 (windows at 80,80 instead of -32000), and returns the output.
    It never signs out, locks, disconnects or reboots the session. Run one visible job at a time.
    The command runs with -NonInteractive, so a missing mandatory parameter fails the test and never waits for input.
    Do not put "exit" in -ProbeArgs: the exit code is not returned.
    Run each window test file in one Pester run only when the files share one STA session (see Tests\WindowHarness.ps1).

.PARAMETER Worktree
    The repo folder to copy (the .git folder is left out).
.PARAMETER ProbeArgs
    The command text, for example: Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path .\Tests -Output Minimal
.PARAMETER OutFile
    A file that receives the output. Without it the output goes to the pipeline.
.PARAMETER Minutes
    The time limit of the run. Default 20.
.PARAMETER QuietMinutes
    A run with no new line of output for this long is ended and reported as a failure. Default 10.
.PARAMETER Target
    The lab computer. Default CLIENT01.
.PARAMETER LogonUser
    The lab account that has the interactive session. Default contoso\labadmin.
.PARAMETER CredentialScript
    A script outside the repo that sets $LabCredential (a PSCredential). The script is never printed.
.PARAMETER CloseStrayWindows
    Preflight: when app windows of another process are open on the labadmin desktop before the run, send them a close request and
    check again. Without the switch the run does not start and fails with the list of windows (Q-118).

.NOTES
    Q-118 hardening (see tools\LabHarness.Common.ps1): the lock decision and the holder text come from the shared library; under the lock
    every ledger left under C:\guide is swept before the run; the run wrapper records a HARNESS snapshot (user, Windows theme, open app
    windows) at the start and at the end, refuses to start on a desktop with stray app windows and closes what the run leaves open;
    the finally block ends the run (scheduled task and process tree) before it releases the lock.
#>
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$ProbeArgs,
    [string]$OutFile,
    [int]$Minutes = 20,
    [int]$QuietMinutes = 10,
    [string]$Target = 'CLIENT01',
    [string]$LogonUser = 'contoso\labadmin',
    [string]$CredentialScript = 'C:\projects\app-packager\docs\lab-credentials.local.ps1',
    [switch]$CloseStrayWindows
)
$ErrorActionPreference = 'Stop'
. $CredentialScript
. (Join-Path $PSScriptRoot 'LabHarness.Common.ps1')
$harnessText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LabHarness.Common.ps1') -Raw
$leaf = Split-Path $Worktree -Leaf
$dest = "C:\guide\visible-$leaf"
$task = "VisibleProbe-$leaf"
# Stops the processes of a run on the lab computer by the ledger of that run and by process id (vault: testing-policy, 'Process rules on a lab VM').
# No process is stopped by a command-line pattern: another session may own a process that matches.
$stopTree = @'
param([string]$Dest, [string]$Mode)
# Mode Stray: stop the descendants of the run that are not in the ledger. Mode All: stop the whole run (descendants, then the run itself).
# The ledger $Dest\.pids holds one line per process of the run: process id|start ticks. The first line is the process that started the run.
# A process is found only through the ledger and through ParentProcessId. Nothing is selected by a command line.
$ledger = Join-Path $Dest '.pids'
if (-not (Test-Path -LiteralPath $ledger)) { return }
$entries = @(Get-Content -LiteralPath $ledger | ForEach-Object { $a = $_ -split '\|'; [pscustomobject]@{ Id = [int]$a[0]; Ticks = [long]$a[1] } })
# A live process with this id but another start time is a different process (the id was reused): stop nothing.
$live = Get-Process -Id $entries[0].Id -ErrorAction SilentlyContinue
if ($live -and $live.StartTime.Ticks -ne $entries[0].Ticks) { return }
function Stop-Below([int]$Id, [datetime]$Since, [int[]]$Skip) {
    foreach ($c in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $Id))) {
        if ($c.CreationDate -lt $Since.AddSeconds(-2) -or $Skip -contains [int]$c.ProcessId) { continue }
        Stop-Below ([int]$c.ProcessId) $c.CreationDate $Skip
        Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue
        'pid {0}: {1}' -f $c.ProcessId, $c.Name
    }
}
$skip = if ($Mode -eq 'Stray') { @($entries | Select-Object -Skip 1 | ForEach-Object { $_.Id }) } else { @() }
Stop-Below $entries[0].Id (New-Object DateTime $entries[0].Ticks) $skip
if ($Mode -eq 'All') {
    foreach ($e in $entries) {
        $p = Get-Process -Id $e.Id -ErrorAction SilentlyContinue
        if ($p -and $p.Id -ne $PID -and $p.StartTime.Ticks -eq $e.Ticks) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}
'@
$s = New-PSSession -ComputerName $Target -Credential $LabCredential
# One window run at a time on the lab computer: the exclusive lock file C:\guide\capture.lock (the file the guide captures use).
# Its text is owner|pid|start time. A lock is stale only when its last write is older than 30 minutes AND its pid is not running (on the lab computer and on this computer);
# a lock whose owner process is alive is never removed. A holder refreshes the lock itself. A removed lock is reported in the output.
$lockPath = 'C:\guide\capture.lock'
$lockToken = '{0}|{1}|{2}' -f $leaf, $PID, (Get-Date -Format s)
$haveLock = $false
$lockNotes = @()
try {
    $lockWaitEnd = (Get-Date).AddMinutes(90)
    $lastHolder = $null
    $unknownReported = $false
    $waitStart = Get-Date
    while (-not $haveLock) {
        # The lock file is created with its text in one step, so a waiting run never reads an empty lock of a run that is starting.
        $got = Invoke-Command $s {
            param($path, $token)
            New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
            try { New-Item -ItemType File -Path $path -Value $token -ErrorAction Stop | Out-Null; 'taken' }
            catch {
                $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                $text = ((Get-Content -LiteralPath $path -ErrorAction SilentlyContinue) -join ' ').Trim()
                if ($item) {
                    $age = [int]((Get-Date) - $item.LastWriteTime).TotalMinutes
                    $alive = $false
                    if ($text -match '^[^|\s][^|]*\|(\d+)\|') { $alive = [bool](Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) }
                    'held: ' + $age + '|' + $alive + '|' + $text
                }
                else { 'busy: ' + $text }
            }
        } -ArgumentList $lockPath, $lockToken
        if ($got -eq 'taken') { $haveLock = $true; break }
        if ($got -like 'held:*') {
            $age, $aliveLab, $heldText = $got.Substring(6) -split '\|', 3
            $ownerPid = if ($heldText -match '^[^|\s][^|]*\|(\d+)\|') { [int]$Matches[1] } else { 0 }
            $aliveHere = [bool]($ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue))
            # Who holds the lock is written to the output once per holder, so a run that waited can be attributed.
            if ($heldText -ne $lastHolder) {
                $lastHolder = $heldText
                $note = 'LOCK: waiting. ' + (Format-LockHolder -Text $heldText -AgeMinutes ([int]$age))
                $lockNotes += $note; Write-Warning $note
            }
            # unknown: another format, never free, never removed. stale: 30 minutes without refresh AND no running owner (lab and here).
            $decision = Get-LockDecision -Text $heldText -AgeMinutes ([int]$age) -AliveLab ($aliveLab -eq 'True') -AliveHere $aliveHere
            if ($decision -eq 'stale') {
                $removed = Invoke-Command $s { param($path, $text) if ((([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim()) -eq $text) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; $true } else { $false } } -ArgumentList $lockPath, $heldText
                if ($removed) {
                    $note = "WARNING: the stale lab lock $lockPath was removed ($heldText; last write $age minutes ago; owner pid $ownerPid not running)."
                    $lockNotes += $note; Write-Warning $note
                    continue
                }
            }
            elseif ($decision -eq 'unknown' -and -not $unknownReported) {
                $unknownReported = $true
                $note = "LOCK: the lab lock $lockPath has a format this runner does not know and blocks the run ($heldText). Waiting; the lock is not removed. Remove it only after its owner is known to be gone."
                $lockNotes += $note; Write-Warning $note
            }
        }
        if ((Get-Date) -gt $lockWaitEnd) { throw "The lab lock $lockPath stayed taken for 90 minutes ($got). Nothing was started." }
        Start-Sleep -Seconds 20
    }
    if ($lockNotes.Count) { $lockNotes += ('LOCK: taken after {0} minutes of waiting.' -f [int]((Get-Date) - $waitStart).TotalMinutes) }
    # Under the lock no other run is active. Sweep every ledger that an earlier run left under C:\guide (this harness and the guide
    # captures), by process id and start time, then end the leftovers of this copy. Nothing is selected by a command line.
    $swept = @(Invoke-Command $s {
            param($lib)
            . ([scriptblock]::Create($lib))
            foreach ($l in @(Get-LedgerPath -Root 'C:\guide')) { Stop-LedgerProcess -Ledger $l | ForEach-Object { $l + ' -> ' + $_ } }
        } -ArgumentList $harnessText)
    if ($swept.Count) { $note = 'SWEEP: ended processes of earlier runs by ledger: ' + ($swept -join '; '); $lockNotes += $note; Write-Warning $note }
    Invoke-Command $s { param($d) $null = & ([scriptblock]::Create($using:stopTree)) $d 'All'; Start-Sleep 1; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $dest
    foreach ($i in Get-ChildItem -LiteralPath $Worktree -Force | Where-Object { $_.Name -ne '.git' }) { Copy-Item -LiteralPath $i.FullName -Destination "$dest\$($i.Name)" -ToSession $s -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LabHarness.Common.ps1') -Destination "$dest\.harness.ps1" -ToSession $s -Force
    # The wrapper runs in the interactive session. Order: lock is held, snapshot, preflight (no stray app window), command, snapshot, close what is left.
    $wrapTemplate = @'
$d = '{DIR}'
. "$d\.harness.ps1"
Add-Content -LiteralPath "$d\.pids" ('{0}|{1}' -f $PID, (Get-Process -Id $PID).StartTime.Ticks)
$w = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$d\.watch.ps1",'-WrapPid',$PID,'-Dir',$d,'-Minutes','{MIN}','-Quiet','{QUIET}'
Add-Content -LiteralPath "$d\.pids" ('{0}|{1}' -f $w.Id, $w.StartTime.Ticks)
Set-Location $d
$env:SUITE_ALLOW_WINDOW_TESTS = '1'
$env:SUITE_VISIBLE_WINDOWS = '1'
$out = "$d\.out.txt"
New-Item -ItemType File -Force $out | Out-Null
try {
    $null = Write-RunSnapshot -Phase 'start' -Run '{RUN}' -Path $out
    $stray = @(Test-DesktopClean -Close:{CLOSE})
    if ($stray.Count) {
        Add-Content -LiteralPath $out -Value ('FAIL: preflight: {0} app window(s) of another process are open on the desktop; the run did not start: {1}' -f $stray.Count, (Format-WindowList -Window $stray)) -Encoding Ascii
        Add-Content -LiteralPath $out -Value 'EXIT=1' -Encoding Ascii
    }
    else {
        & { {CMD} } *>&1 | ForEach-Object { ($_ | Out-String -Width 220).TrimEnd() | Add-Content -LiteralPath $out -Encoding Ascii }
        "EXIT=$LASTEXITCODE" | Add-Content -LiteralPath $out
    }
}
catch { $_ | Out-String | Add-Content -LiteralPath $out }
finally {
    try {
        $left = @(Get-StrayAppWindow | Where-Object { $_.ProcessId -eq $PID })
        $null = Write-RunSnapshot -Phase 'end' -Run '{RUN}' -Path $out
        if ($left.Count) { Add-Content -LiteralPath $out -Value ('WARN: leak: the run left {0} app window(s) of its own process open (closed now): {1}' -f $left.Count, (Format-WindowList -Window $left)) -Encoding Ascii; Close-AppWindow -Window $left }
    } catch { $_ | Out-String | Add-Content -LiteralPath $out }
    Set-Content "$d\.done" 'done'
}
'@
    $wrapText = $wrapTemplate.Replace('{DIR}', $dest).Replace('{MIN}', [string]$Minutes).Replace('{QUIET}', [string]$QuietMinutes).Replace('{RUN}', $leaf).Replace('{CLOSE}', $(if ($CloseStrayWindows) { '$true' } else { '$false' })).Replace('{CMD}', $ProbeArgs)
    Invoke-Command $s {
        param($d, $wrap, $user, $task, $watchText)
        # The remote watchdog (a hidden PowerShell process on the lab computer) ends a run that hangs or goes quiet, also when the runner on the dev PC is gone.
        Set-Content -LiteralPath "$d\.watch.ps1" -Value $watchText -Encoding Ascii
        # The wrapper is a PowerShell file: plain ASCII, no BOM.
        Set-Content -LiteralPath "$d\.wrap.ps1" -Value $wrap -Encoding Ascii
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File `"$d\.wrap.ps1`""
        $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
        Start-ScheduledTask $task
    } -ArgumentList $dest, $wrapText, $LogonUser, $task, @'
param([int]$WrapPid, [string]$Dir, [int]$Minutes, [int]$Quiet)
# Remote watchdog of one visible run. It lives on the lab computer, so a dead or hung runner on the dev PC cannot leave the run unwatched.
$start = Get-Date; $last = Get-Date; $len = -1
$kill = { param($id) foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id")) { & $kill $c.ProcessId }; Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
while ($true) {
    Start-Sleep -Seconds 10
    if (Test-Path "$Dir\.done") { break }
    if (-not (Get-Process -Id $WrapPid -ErrorAction SilentlyContinue)) { break }
    $n = if (Test-Path "$Dir\.out.txt") { (Get-Item "$Dir\.out.txt").Length } else { 0 }
    if ($n -ne $len) { $len = $n; $last = Get-Date }
    $why = $null
    if (((Get-Date) - $start).TotalMinutes -ge $Minutes) { $why = "the run did not finish in $Minutes minutes" }
    elseif (((Get-Date) - $last).TotalMinutes -ge $Quiet) { $why = "no output for $Quiet minutes" }
    if ($why) {
        & $kill $WrapPid
        Add-Content -LiteralPath "$Dir\.out.txt" "FAIL: remote watchdog: $why; the run was ended."
        Set-Content -LiteralPath "$Dir\.done" 'done'
        break
    }
}
'@
    # Wait for the run. It ends as a failure after $Minutes in total, or after $QuietMinutes without a new line of output.
    $end = (Get-Date).AddMinutes($Minutes)
    $lastLength = -1
    $lastGrowth = Get-Date
    $failure = $null
    do {
        Start-Sleep 5
        $state = Invoke-Command $s { param($d) [pscustomobject]@{ Done = (Test-Path "$d\.done"); Length = $(if (Test-Path "$d\.out.txt") { (Get-Item "$d\.out.txt").Length } else { 0 }) } } -ArgumentList $dest
        $done = $state.Done
        Invoke-Command $s { param($path) $i = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue; if ($i) { $i.LastWriteTime = Get-Date } } -ArgumentList $lockPath
        if ($state.Length -ne $lastLength) { $lastLength = $state.Length; $lastGrowth = Get-Date }
        if (-not $done -and ((Get-Date) - $lastGrowth).TotalMinutes -ge $QuietMinutes) { $failure = "FAIL: no output for $QuietMinutes minutes; the run was ended."; break }
    } while (-not $done -and (Get-Date) -lt $end)
    if (-not $done -and -not $failure) { $failure = "FAIL: the run did not finish in $Minutes minutes and was ended." }
    if ($failure) {
        # End only the processes of this copy. The labadmin session itself stays untouched.
        Invoke-Command $s { param($d) $null = & ([scriptblock]::Create($using:stopTree)) $d 'All' } -ArgumentList $dest
    }
    $text = Invoke-Command $s { param($d) if (Test-Path "$d\.out.txt") { Get-Content "$d\.out.txt" -Raw } } -ArgumentList $dest
    # A run that leaves a window or process behind fails: any process below the run (found through the ledger) that is still alive after the check is stray.
    $stray = @(Invoke-Command $s { param($d) Start-Sleep -Seconds 3; & ([scriptblock]::Create($using:stopTree)) $d 'Stray' } -ArgumentList $dest)
    if ($stray.Count -and -not $failure) { $failure = "FAIL: the run left $($stray.Count) stray process(es) with windows on $Target (ended): " + ($stray -join ' ; ') }
    # The preflight refused to start the run: a stray app window was open. The run output holds the list.
    if (-not $failure -and $text -match '(?m)^FAIL: preflight') { $failure = ($text -split "`r?`n" | Where-Object { $_ -like 'FAIL: preflight*' } | Select-Object -First 1) }
    if ($lockNotes.Count) { $text = ($lockNotes -join "`n") + "`n" + $text }
    if ($failure) { $text = "$text`n$failure`nEXIT=1" }
    if ($OutFile) { $text | Set-Content -LiteralPath $OutFile -Encoding UTF8 } else { $text }
    if ($failure) { Write-Warning $failure }
}
finally {
    # Cleanup runs only for a run that took the lock. A run that gave up waiting owns nothing on the lab computer: the folder and the task
    # of the same name may belong to the run that holds the lock (two runs from folders of one name share the name).
    # Order: stop the task, end the processes of the run by ledger (also when the runner was interrupted), remove task and folder, release the lock.
    if ($haveLock) {
        try { Invoke-Command $s { param($d, $task) Stop-ScheduledTask $task -ErrorAction SilentlyContinue; $null = & ([scriptblock]::Create($using:stopTree)) $d 'All' } -ArgumentList $dest, $task } catch { Write-Warning "Ending the run failed: $($_.Exception.Message)" }
        try { Invoke-Command $s { param($d, $task) Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest, $task } catch { Write-Warning "Cleanup of $dest failed: $($_.Exception.Message)" }
        # The lock goes only when this run took it and the file still holds this run's text.
        try { Invoke-Command $s { param($path, $token) if ((Test-Path -LiteralPath $path) -and (([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -eq $token)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } -ArgumentList $lockPath, $lockToken } catch { Write-Warning "Releasing the lab lock failed: $($_.Exception.Message)" }
    }
    Remove-PSSession $s
}
