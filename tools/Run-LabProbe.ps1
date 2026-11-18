<#
.SYNOPSIS
    Copies a repo folder to a lab computer and runs one command there over WinRM, for lint and tests that open no window.

.DESCRIPTION
    Runs on CM01 by default. The command runs in Windows PowerShell 5.1 in session 0, where no window shows,
    so window tests stay skipped (SUITE_ALLOW_WINDOW_TESTS is not set). Run a window test with
    tools\Run-VisibleProbe.ps1 instead: it shows the windows in the labadmin session of CLIENT01.
    The copy is removed when the command ends.

.PARAMETER Worktree
    The repo folder to copy (the .git folder is left out).
.PARAMETER ProbeArgs
    The command text, for example: Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path .\Tests -Output Minimal
.PARAMETER Target
    The lab computer. Default CM01.
.PARAMETER Minutes
    The time limit of the run. A run that is not finished by then is ended and reported as a failure. Default 20.
.PARAMETER OutFile
    A file that receives the output. Without it the output goes to the pipeline.
.PARAMETER CredentialScript
    A script outside the repo that sets $LabCredential (a PSCredential). The script is never printed.
#>
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$ProbeArgs,
    [string]$Target = 'CM01',
    [string]$OutFile,
    [int]$Minutes = 20,
    [string]$CredentialScript = 'C:\projects\app-packager\docs\lab-credentials.local.ps1'
)
$ErrorActionPreference = 'Stop'
. $CredentialScript
$dest = 'C:\Temp\fc-' + (Split-Path $Worktree -Leaf)
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
try {
    Invoke-Command $s { param($d) Set-Location C:\; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $dest
    foreach ($i in Get-ChildItem -LiteralPath $Worktree -Force | Where-Object { $_.Name -ne '.git' }) { Copy-Item -LiteralPath $i.FullName -Destination "$dest\$($i.Name)" -ToSession $s -Recurse -Force }
    # -NonInteractive: a missing mandatory parameter fails the test instead of waiting for input.
    $job = Invoke-Command $s { param($d, $a) Set-Content -LiteralPath (Join-Path $d '.pids') ('{0}|{1}' -f $PID, (Get-Process -Id $PID).StartTime.Ticks); Set-Location $d; $o = & powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -Command $a 2>&1 | Out-String; $o; "EXIT=$LASTEXITCODE"; Set-Location C:\ } -ArgumentList $dest, $ProbeArgs -AsJob
    if (Wait-Job $job -Timeout ($Minutes * 60)) {
        $out = Receive-Job $job
    }
    else {
        # The run took longer than the limit: end only the processes below the job of this copy (by its ledger), report a failure.
        # The session $s is busy with the job: use a second session for the stop.
        $s2 = New-PSSession -ComputerName $Target -Credential $LabCredential
        try { Invoke-Command $s2 { param($d) $null = & ([scriptblock]::Create($using:stopTree)) $d 'Stray' } -ArgumentList $dest } finally { Remove-PSSession $s2 }
        Stop-Job $job
        $out = "FAIL: the run did not finish in $Minutes minutes and was ended.`nEXIT=1"
    }
    Remove-Job $job -Force
    if ($OutFile) { $out | Set-Content -LiteralPath $OutFile -Encoding Ascii } else { $out }
}
finally {
    try { Invoke-Command $s { param($d) Set-Location C:\; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest } catch { $null = $_ }
    Remove-PSSession $s
}
