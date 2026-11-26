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
    every ledger left under C:\guide is swept before the run (exact process id and start time only); the run wrapper records a HARNESS snapshot (user, Windows theme, open app
    windows) at the start and at the end, refuses to start on a desktop with stray app windows and closes what the run leaves open;
    the finally block ends the run (its job object and its scheduled task) before it releases the lock.
    A run is stopped only through its job object (tools\ProcessJob.ps1). No process is found through a parent id, a name or a command
    line, so the harness cannot stop a process that it did not start.
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
# Ends the run of a run folder on the lab computer (Stop-LabRun of the library): through the job of the run, never through parent ids.
$endRun = { param($lib, $d) . ([scriptblock]::Create($lib)); Stop-LabRun -Dir $d }
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
            # The text is written to a temp file and the file is moved to the lock name: the move fails when the lock exists and the lock never shows empty.
            $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            try { [IO.File]::WriteAllText($tmp, $token); [IO.File]::Move($tmp, $path); 'taken' }
            catch {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
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
    $null = Invoke-Command $s -ScriptBlock $endRun -ArgumentList $harnessText, $dest
    Invoke-Command $s { param($d) Start-Sleep 1; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $dest
    foreach ($i in Get-ChildItem -LiteralPath $Worktree -Force | Where-Object { $_.Name -ne '.git' }) { Copy-Item -LiteralPath $i.FullName -Destination "$dest\$($i.Name)" -ToSession $s -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LabHarness.Common.ps1') -Destination "$dest\.harness.ps1" -ToSession $s -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ProcessJob.ps1') -Destination "$dest\.job.ps1" -ToSession $s -Force
    # The wrapper runs in the interactive session. Order: lock is held, snapshot, preflight (no stray app window), command, snapshot, close what is left.
    $wrapTemplate = @'
$d = '{DIR}'
. "$d\.harness.ps1"
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
catch {
    $_ | Out-String | Add-Content -LiteralPath $out
    Add-Content -LiteralPath $out -Value 'EXIT=1' -Encoding Ascii
}
finally {
    try {
        $left = @(Get-StrayAppWindow | Where-Object { $_.ProcessId -eq $PID })
        $null = Write-RunSnapshot -Phase 'end' -Run '{RUN}' -Path $out
        if ($left.Count) { Add-Content -LiteralPath $out -Value ('WARN: leak: the run left {0} app window(s) of its own process open (closed now): {1}' -f $left.Count, (Format-WindowList -Window $left)) -Encoding Ascii; Close-AppWindow -Window $left }
    } catch { $_ | Out-String | Add-Content -LiteralPath $out }
}
'@
    $wrapText = $wrapTemplate.Replace('{DIR}', $dest).Replace('{RUN}', $leaf).Replace('{CLOSE}', $(if ($CloseStrayWindows) { '$true' } else { '$false' })).Replace('{CMD}', $ProbeArgs)
    # The launcher is what the scheduled task starts. It owns the job object of the run: the wrapper starts suspended, joins the job and
    # then runs, so everything the run starts is a member. The launcher is also the remote watchdog: it runs on the lab computer, so a dead
    # or hung runner on the dev PC cannot leave the run unwatched. It ends a run through the job only. When the launcher itself ends in any
    # way (also by Stop-ScheduledTask), its job closes and Windows ends the members.
    $launchTemplate = @'
$d = '{DIR}'
$out = "$d\.out.txt"
$run = $null
$result = $null
$problem = $null
try {
    . "$d\.job.ps1"
    Add-Content -LiteralPath "$d\.pids" ('{0}|{1}' -f $PID, (Get-Process -Id $PID).StartTime.Ticks)
    Set-Location $d
    $run = Start-JobProcess -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$d\.wrap.ps1`"" -StandardOutput "$d\.wrap.log" -StandardError "$d\.wrap.log"
    $result = Wait-JobRun -Run $run -Minutes {MIN} -QuietMinutes {QUIET} -OutputFile $out -StopFile "$d\.stop"
}
catch { $problem = $_ | Out-String }
finally {
    if ($run) { Stop-JobProcess -Run $run }
    # The members are ended, so the output file has one writer now.
    $line = $null
    if ($problem) { $line = 'FAIL: remote watchdog: the launcher failed: ' + $problem }
    elseif ($result.Reason -eq 'time') { $line = 'FAIL: remote watchdog: the run did not finish in {MIN} minutes; the run was ended.' }
    elseif ($result.Reason -eq 'quiet') { $line = 'FAIL: remote watchdog: no output for {QUIET} minutes; the run was ended.' }
    elseif ($result.Reason -eq 'exit' -and -not (Select-String -LiteralPath $out -Pattern '^EXIT=' -Quiet -ErrorAction SilentlyContinue)) { $line = 'FAIL: remote watchdog: the wrapper ended without a result. ' + (Get-Content -LiteralPath "$d\.wrap.log" -Raw -ErrorAction SilentlyContinue) }
    if ($line) { Add-Content -LiteralPath $out -Value $line -Encoding Ascii }
    if ($result -and $result.Stray.Count) { Set-Content -LiteralPath "$d\.stray" -Value $result.Stray -Encoding Ascii }
    Set-Content -LiteralPath "$d\.done" -Value 'done' -Encoding Ascii
}
'@
    $launchText = $launchTemplate.Replace('{DIR}', $dest).Replace('{MIN}', [string]$Minutes).Replace('{QUIET}', [string]$QuietMinutes)
    Invoke-Command $s {
        param($d, $wrap, $user, $task, $launch)
        # Both scripts are PowerShell files: plain ASCII, no BOM.
        Set-Content -LiteralPath "$d\.launch.ps1" -Value $launch -Encoding Ascii
        Set-Content -LiteralPath "$d\.wrap.ps1" -Value $wrap -Encoding Ascii
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$d\.launch.ps1`""
        $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
        Start-ScheduledTask $task
    } -ArgumentList $dest, $wrapText, $LogonUser, $task, $launchText
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
        # End only the run of this copy, through its job. The labadmin session itself stays untouched.
        $null = Invoke-Command $s -ScriptBlock $endRun -ArgumentList $harnessText, $dest
    }
    $text = Invoke-Command $s { param($d) if (Test-Path "$d\.out.txt") { Get-Content "$d\.out.txt" -Raw } } -ArgumentList $dest
    # A run that leaves a window or process behind fails: a member of the job that still ran after the wrapper ended is stray. The
    # launcher listed it and ended it with the job.
    $stray = @(Invoke-Command $s { param($d) if (Test-Path "$d\.stray") { Get-Content "$d\.stray" } } -ArgumentList $dest)
    if ($stray.Count -and -not $failure) { $failure = "FAIL: the run left $($stray.Count) stray process(es) with windows on $Target (ended): " + ($stray -join ' ; ') }
    # The preflight refused to start the run: a stray app window was open. The run output holds the list.
    if (-not $failure -and $text -match '(?m)^FAIL: (preflight|remote watchdog)') { $failure = ($text -split "`r?`n" | Where-Object { $_ -like 'FAIL: preflight*' -or $_ -like 'FAIL: remote watchdog*' } | Select-Object -First 1) }
    # A run with no result line did not finish its command: it never counts as a success.
    if (-not $failure -and $text -notmatch '(?m)^EXIT=') { $failure = 'FAIL: the run ended without a result line.' }
    if ($lockNotes.Count) { $text = ($lockNotes -join "`n") + "`n" + $text }
    if ($failure) { $text = "$text`n$failure`nEXIT=1" }
    if ($OutFile) { $text | Set-Content -LiteralPath $OutFile -Encoding UTF8 } else { $text }
    if ($failure) { Write-Warning $failure }
}
finally {
    # Cleanup runs only for a run that took the lock. A run that gave up waiting owns nothing on the lab computer: the folder and the task
    # of the same name may belong to the run that holds the lock (two runs from folders of one name share the name).
    # Order: end the run through its job (also when the runner was interrupted), stop the task, remove task and folder, release the lock.
    if ($haveLock) {
        try { $null = Invoke-Command $s -ScriptBlock $endRun -ArgumentList $harnessText, $dest } catch { Write-Warning "Ending the run failed: $($_.Exception.Message)" }
        try { Invoke-Command $s { param($task) Stop-ScheduledTask $task -ErrorAction SilentlyContinue } -ArgumentList $task } catch { Write-Warning "Stopping the task failed: $($_.Exception.Message)" }
        try { Invoke-Command $s { param($d, $task) Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest, $task } catch { Write-Warning "Cleanup of $dest failed: $($_.Exception.Message)" }
        # The lock goes only when this run took it and the file still holds this run's text.
        try { Invoke-Command $s { param($path, $token) if ((Test-Path -LiteralPath $path) -and (([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -eq $token)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } -ArgumentList $lockPath, $lockToken } catch { Write-Warning "Releasing the lab lock failed: $($_.Exception.Message)" }
    }
    Remove-PSSession $s
}
