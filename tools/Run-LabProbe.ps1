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
$s = New-PSSession -ComputerName $Target -Credential $LabCredential
try {
    Invoke-Command $s { param($d) Set-Location C:\; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $dest
    foreach ($i in Get-ChildItem -LiteralPath $Worktree -Force | Where-Object { $_.Name -ne '.git' }) { Copy-Item -LiteralPath $i.FullName -Destination "$dest\$($i.Name)" -ToSession $s -Recurse -Force }
    # -NonInteractive: a missing mandatory parameter fails the test instead of waiting for input.
    $job = Invoke-Command $s { param($d, $a) Set-Location $d; $o = & powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -Command $a 2>&1 | Out-String; $o; "EXIT=$LASTEXITCODE"; Set-Location C:\ } -ArgumentList $dest, $ProbeArgs -AsJob
    if (Wait-Job $job -Timeout ($Minutes * 60)) {
        $out = Receive-Job $job
    }
    else {
        # The run took longer than the limit: end only the processes of this copy, report a failure.
        Invoke-Command $s { param($d) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$d*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } } -ArgumentList $dest
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
