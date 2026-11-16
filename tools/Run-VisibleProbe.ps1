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
#>
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$ProbeArgs,
    [string]$OutFile,
    [int]$Minutes = 20,
    [int]$QuietMinutes = 10,
    [string]$Target = 'CLIENT01',
    [string]$LogonUser = 'contoso\labadmin',
    [string]$CredentialScript = 'C:\projects\app-packager\docs\lab-credentials.local.ps1'
)
$ErrorActionPreference = 'Stop'
. $CredentialScript
$leaf = Split-Path $Worktree -Leaf
$dest = "C:\guide\visible-$leaf"
$task = "VisibleProbe-$leaf"
$s = New-PSSession -ComputerName $Target -Credential $LabCredential
# One window run at a time on the lab computer: the exclusive lock file C:\guide\capture.lock (the file the guide captures use).
# Its text is owner|pid|start time. A lock is stale only when its last write is older than 30 minutes AND its pid is not running (on the lab computer and on this computer);
# a lock whose owner process is alive is never removed. A holder refreshes the lock itself. A removed lock is reported in the output.
$lockPath = 'C:\guide\capture.lock'
$lockToken = '{0}|{1}|{2}' -f $leaf, $PID, (Get-Date -Format s)
$haveLock = $false
try {
    $lockWaitEnd = (Get-Date).AddMinutes(90)
    $unknownReported = $false
    $lockNotes = @()
    while (-not $haveLock) {
        $got = Invoke-Command $s {
            param($path, $token)
            New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
            try { New-Item -ItemType File -Path $path -ErrorAction Stop | Out-Null; Set-Content -LiteralPath $path -Value $token -Encoding Ascii; 'taken' }
            catch {
                $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                $text = ((Get-Content -LiteralPath $path -ErrorAction SilentlyContinue) -join ' ').Trim()
                # A lock in a format this runner does not know (not owner|pid|start time) is never free and never removed here: it blocks and is reported.
                if ($text -notmatch '^[^|\s][^|]*\|\d+\|\d{4}-\d{2}-\d{2}T') { 'unknown: ' + $text }
                elseif ($item) {
                    $age = [int]((Get-Date) - $item.LastWriteTime).TotalMinutes
                    $alive = [bool](Get-Process -Id ([int]($text -split '\|')[1]) -ErrorAction SilentlyContinue)
                    'held: ' + $age + '|' + $alive + '|' + $text
                }
                else { 'busy: ' + $text }
            }
        } -ArgumentList $lockPath, $lockToken
        if ($got -eq 'taken') { $haveLock = $true }
        elseif ($got -like 'unknown:*') {
            # Blocking, never free: report it once, keep waiting, never remove it. At the end of the wait the run fails and nothing was started.
            if (-not $unknownReported) { Write-Warning "The lab lock $lockPath has a format this runner does not know and blocks the run ($got). Waiting; the lock is not removed. Remove it only after its owner is known to be gone."; $unknownReported = $true }
            if ((Get-Date) -gt $lockWaitEnd) { throw "The lab lock $lockPath stayed taken in an unknown format for 90 minutes ($got). Nothing was started." }
            Start-Sleep -Seconds 20
        }
        elseif ($got -like 'held:*') {
            # Stale only after 30 minutes AND with no running owner process (checked on the lab computer and here). Never remove the lock of a live owner.
            $age, $aliveLab, $heldText = $got.Substring(6) -split '\|', 3
            $ownerPid = [int]($heldText -split '\|')[1]
            $aliveHere = [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
            if ([int]$age -gt 30 -and $aliveLab -ne 'True' -and -not $aliveHere) {
                $removed = Invoke-Command $s { param($path, $text) if ((([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim()) -eq $text) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; $true } else { $false } } -ArgumentList $lockPath, $heldText
                if ($removed) {
                    $note = "WARNING: the stale lab lock $lockPath was removed ($heldText; last write $age minutes ago; owner pid $ownerPid not running)."
                    $lockNotes += $note; Write-Warning $note
                    continue
                }
            }
            if ((Get-Date) -gt $lockWaitEnd) { throw "The lab lock $lockPath stayed taken for 90 minutes ($heldText)." }
            Start-Sleep -Seconds 20
        }
        elseif ((Get-Date) -gt $lockWaitEnd) { throw "The lab lock $lockPath stayed taken for 90 minutes ($got)." }
        else { Start-Sleep -Seconds 20 }
    }
    # Under the lock no other run is active: end the left-over PowerShell processes of earlier runs and captures (their windows go with them).
    Invoke-Command $s { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*C:\guide\*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Invoke-Command $s { param($d) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$d\*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Start-Sleep 1; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $dest
    foreach ($i in Get-ChildItem -LiteralPath $Worktree -Force | Where-Object { $_.Name -ne '.git' }) { Copy-Item -LiteralPath $i.FullName -Destination "$dest\$($i.Name)" -ToSession $s -Recurse -Force }
    Invoke-Command $s {
        param($d, $a, $user, $task, $minutes, $quiet, $watchText)
        # The remote watchdog (a hidden PowerShell process on the lab computer) ends a run that hangs or goes quiet, also when the runner on the dev PC is gone.
        Set-Content -LiteralPath "$d\.watch.ps1" -Value $watchText -Encoding Ascii
        $wrap = "`$null = Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$d\.watch.ps1','-WrapPid',`$PID,'-Dir','$d','-Minutes','$minutes','-Quiet','$quiet'; Set-Location `"$d`"; `$env:SUITE_ALLOW_WINDOW_TESTS = '1'; `$env:SUITE_VISIBLE_WINDOWS = '1'; New-Item -ItemType File -Force `"$d\.out.txt`" | Out-Null; try { & { $a } *>&1 | ForEach-Object { (`$_ | Out-String -Width 220).TrimEnd() | Add-Content -LiteralPath `"$d\.out.txt`" -Encoding Ascii }; `"EXIT=`$LASTEXITCODE`" | Add-Content `"$d\.out.txt`" } catch { `$_ | Out-String | Add-Content `"$d\.out.txt`" } finally { Set-Content `"$d\.done`" 'done' }"
        # The wrapper is a PowerShell file: plain ASCII, no BOM.
        Set-Content -LiteralPath "$d\.wrap.ps1" -Value $wrap -Encoding Ascii
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File `"$d\.wrap.ps1`""
        $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
        Start-ScheduledTask $task
    } -ArgumentList $dest, $ProbeArgs, $LogonUser, $task, $Minutes, $QuietMinutes, @'
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
        Invoke-Command $s { param($d) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$d\*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } } -ArgumentList $dest
    }
    $text = Invoke-Command $s { param($d) if (Test-Path "$d\.out.txt") { Get-Content "$d\.out.txt" -Raw } } -ArgumentList $dest
    # A run that leaves a window or process behind fails: any PowerShell process of C:\guide that is not the check itself is stray.
    $stray = @(Invoke-Command $s { param($d) Start-Sleep -Seconds 3; Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*C:\guide\*' -and $_.CommandLine -notlike '*.watch.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { $c = $_.CommandLine; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; 'pid {0}: {1}' -f $_.ProcessId, $c.Substring(0, [Math]::Min(160, $c.Length)) } } -ArgumentList $dest)
    if ($stray.Count -and -not $failure) { $failure = "FAIL: the run left $($stray.Count) stray process(es) with windows on $Target (ended): " + ($stray -join ' ; ') }
    if ($lockNotes.Count) { $text = ($lockNotes -join "`n") + "`n" + $text }
    if ($failure) { $text = "$text`n$failure`nEXIT=1" }
    if ($OutFile) { $text | Set-Content -LiteralPath $OutFile -Encoding UTF8 } else { $text }
    if ($failure) { Write-Warning $failure }
}
finally {
    try { Invoke-Command $s { param($d, $task) Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest, $task } catch { $null = $_ }
    # The lock goes only when this run took it and the file still holds this run's text.
    if ($haveLock) { try { Invoke-Command $s { param($path, $token) if ((Test-Path -LiteralPath $path) -and (([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -eq $token)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } -ArgumentList $lockPath, $lockToken } catch { Write-Warning "Releasing the lab lock failed: $($_.Exception.Message)" } }
    Remove-PSSession $s
}
