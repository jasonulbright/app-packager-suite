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
try {
    Invoke-Command $s { param($d) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$d\*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Start-Sleep 1; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $dest
    foreach ($i in Get-ChildItem -LiteralPath $Worktree -Force | Where-Object { $_.Name -ne '.git' }) { Copy-Item -LiteralPath $i.FullName -Destination "$dest\$($i.Name)" -ToSession $s -Recurse -Force }
    Invoke-Command $s {
        param($d, $a, $user, $task)
        $wrap = "Set-Location `"$d`"; `$env:SUITE_ALLOW_WINDOW_TESTS = '1'; `$env:SUITE_VISIBLE_WINDOWS = '1'; New-Item -ItemType File -Force `"$d\.out.txt`" | Out-Null; try { & { $a } *>&1 | ForEach-Object { (`$_ | Out-String -Width 220).TrimEnd() | Add-Content -LiteralPath `"$d\.out.txt`" -Encoding Ascii }; `"EXIT=`$LASTEXITCODE`" | Add-Content `"$d\.out.txt`" } catch { `$_ | Out-String | Add-Content `"$d\.out.txt`" } finally { Set-Content `"$d\.done`" 'done' }"
        # The wrapper is a PowerShell file: plain ASCII, no BOM.
        Set-Content -LiteralPath "$d\.wrap.ps1" -Value $wrap -Encoding Ascii
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File `"$d\.wrap.ps1`""
        $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
        Start-ScheduledTask $task
    } -ArgumentList $dest, $ProbeArgs, $LogonUser, $task
    # Wait for the run. It ends as a failure after $Minutes in total, or after $QuietMinutes without a new line of output.
    $end = (Get-Date).AddMinutes($Minutes)
    $lastLength = -1
    $lastGrowth = Get-Date
    $failure = $null
    do {
        Start-Sleep 5
        $state = Invoke-Command $s { param($d) [pscustomobject]@{ Done = (Test-Path "$d\.done"); Length = $(if (Test-Path "$d\.out.txt") { (Get-Item "$d\.out.txt").Length } else { 0 }) } } -ArgumentList $dest
        $done = $state.Done
        if ($state.Length -ne $lastLength) { $lastLength = $state.Length; $lastGrowth = Get-Date }
        if (-not $done -and ((Get-Date) - $lastGrowth).TotalMinutes -ge $QuietMinutes) { $failure = "FAIL: no output for $QuietMinutes minutes; the run was ended."; break }
    } while (-not $done -and (Get-Date) -lt $end)
    if (-not $done -and -not $failure) { $failure = "FAIL: the run did not finish in $Minutes minutes and was ended." }
    if ($failure) {
        # End only the processes of this copy. The labadmin session itself stays untouched.
        Invoke-Command $s { param($d) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$d\*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } } -ArgumentList $dest
    }
    $text = Invoke-Command $s { param($d) if (Test-Path "$d\.out.txt") { Get-Content "$d\.out.txt" -Raw } } -ArgumentList $dest
    if ($failure) { $text = "$text`n$failure`nEXIT=1" }
    if ($OutFile) { $text | Set-Content -LiteralPath $OutFile -Encoding UTF8 } else { $text }
    if ($failure) { Write-Warning $failure }
}
finally {
    try { Invoke-Command $s { param($d, $task) Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest, $task } catch { $null = $_ }
    Remove-PSSession $s
}
