<#
.SYNOPSIS
    Runs a command from a copied repo in the interactive labadmin session (session 2) of CLIENT01, so that the windows show on screen.

.DESCRIPTION
    The default way to run a window test, probe, smoke script or capture. It copies the repo to C:\guide\visible-<folder>,
    registers a scheduled task for the logged-on lab user (interactive logon), runs the command with
    SUITE_ALLOW_WINDOW_TESTS=1 and SUITE_VISIBLE_WINDOWS=1 (windows at 80,80 instead of -32000), and returns the output.
    It never signs out, locks, disconnects or reboots the session. Run one visible job at a time.
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
        $wrap = "Set-Location `"$d`"; `$env:SUITE_ALLOW_WINDOW_TESTS = '1'; `$env:SUITE_VISIBLE_WINDOWS = '1'; try { & { $a } *>&1 | Out-String -Width 220 | Set-Content -LiteralPath `"$d\.out.txt`" -Encoding UTF8; `"EXIT=`$LASTEXITCODE`" | Add-Content `"$d\.out.txt`" } catch { `$_ | Out-String | Add-Content `"$d\.out.txt`" } finally { Set-Content `"$d\.done`" 'done' }"
        # The wrapper is a PowerShell file: plain ASCII, no BOM.
        Set-Content -LiteralPath "$d\.wrap.ps1" -Value $wrap -Encoding Ascii
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -STA -File `"$d\.wrap.ps1`""
        $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
        Start-ScheduledTask $task
    } -ArgumentList $dest, $ProbeArgs, $LogonUser, $task
    $end = (Get-Date).AddMinutes($Minutes)
    do { Start-Sleep 5; $done = Invoke-Command $s { param($d) Test-Path "$d\.done" } -ArgumentList $dest } while (-not $done -and (Get-Date) -lt $end)
    $text = Invoke-Command $s { param($d) if (Test-Path "$d\.out.txt") { Get-Content "$d\.out.txt" -Raw } } -ArgumentList $dest
    if ($OutFile) { $text | Set-Content -LiteralPath $OutFile -Encoding UTF8 } else { $text }
    if (-not $done) { Write-Warning 'The run did not finish in time.' }
}
finally {
    try { Invoke-Command $s { param($d, $task) Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest, $task } catch { $null = $_ }
    Remove-PSSession $s
}
