<#
.SYNOPSIS
    Captures the suite launcher window for docs\launcher.png. Runs in the interactive session of a lab computer.

.DESCRIPTION
    Seeds a temporary data root with two fictional sites (AB1 and CD2, hosts on example.com) and a temporary tools folder with one
    stub folder per suite tool, starts start-suite.ps1 against them, captures the window and writes the PNG. Nothing of the real
    profile is read or written: APP_PACKAGER_DATA_ROOT and ToolsRoot point at the temporary folders.
    Run it through tools\Run-VisibleProbe.ps1, which holds C:\guide\capture.lock. With -Base64 the PNG is also printed as one
    PNG64:<text> line, so that the caller can write the file on its own computer.

.PARAMETER Versions
    A JSON file: an object of tool folder name -> version text for the tile captions.
.PARAMETER OutFile
    The PNG path.
#>
param(
    [string]$Versions,
    [string]$OutFile = (Join-Path ([IO.Path]::GetTempPath()) 'launcher.png'),
    [switch]$Base64,
    [switch]$Dark
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Namespace Cap -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr h, int x, int y, int w, int hh, bool r);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
'@
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path (Split-Path -Path $OutFile -Parent) 'launcher-cap'
$tmpBase = $tmp
$data = Join-Path $tmp 'data'
$tools = Join-Path $tmp 'Tools'
[void](New-Item -ItemType Directory -Path $data, $tools -Force)
$ver = @{}
if ($Versions -and (Test-Path $Versions)) { (Get-Content $Versions -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ver[$_.Name] = [string]$_.Value } }
$registry = @(
    @('app-packager', 'start-apppackager.ps1'), @('dp-content-manager', 'start-dpcontentmgr.ps1'), @('collection-manager', 'start-collectionmanager.ps1'),
    @('deployment-helper', 'start-deploymenthelper.ps1'), @('detection-tester', 'start-detectiontester.ps1'), @('installer-analysis', 'start-installeranalysis.ps1'),
    @('maintenance-window-manager', 'start-maintenancewindowmgr.ps1'), @('collection-and-compliance-manager', 'start-ccm.ps1'), @('site-hygiene', 'start-sitehygiene.ps1'),
    @('pivots-and-scripts', 'start-pivotsandscripts.ps1'), @('update-planner', 'start-updateplanner.ps1'), @('device-inspector', 'start-deviceinspector.ps1'))
foreach ($t in $registry) {
    $d = Join-Path $tools $t[0]
    [void](New-Item -ItemType Directory -Path $d -Force)
    Set-Content -LiteralPath (Join-Path $d $t[1]) -Value '# stub for the launcher capture'
    $v = $ver[$t[0]]
    if ($v) { Set-Content -LiteralPath (Join-Path $d 'CHANGELOG.md') -Value ("# Changelog`n`n## [$v] - 2026-11-22`n") }
}
# Two sites. AB1 is active.
$now = '2026-11-22T08:00:00Z'
foreach ($s in @(@('AB1', 'cm01.example.com'), @('CD2', 'cm02.example.com'))) {
    $dir = Join-Path $data ('Users\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '\sites\' + $s[0])
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $node = [ordered]@{ schemaVersion = 1; siteCode = $s[0]; providers = @($s[1]); createdUtc = $now; lastUsedUtc = $now }
    Set-Content -LiteralPath (Join-Path $dir 'site.json') -Value ($node | ConvertTo-Json)
}
$root = Join-Path $data ('Users\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
Set-Content -LiteralPath (Join-Path $root 'active-site.json') -Value (([ordered]@{ schemaVersion = 1; siteCode = 'AB1'; changedUtc = $now }) | ConvertTo-Json)
$settings = [ordered]@{ SiteCode = ''; SMSProvider = ''; DarkMode = [bool]$Dark; ToolsRoot = $tools }
$settingsPath = Join-Path $repo 'suite.settings.json'
$hadSettings = Test-Path $settingsPath
$backup = $null
if ($hadSettings) { $backup = Get-Content $settingsPath -Raw }
Set-Content -LiteralPath $settingsPath -Value ($settings | ConvertTo-Json)
$env:APP_PACKAGER_DATA_ROOT = $data
Remove-Item Env:SUITE_CM_SITECODE, Env:APP_PACKAGER_SITE -ErrorAction SilentlyContinue
$p = $null
try {
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $repo 'start-suite.ps1') + '"') -PassThru
    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $found = [Cap.Win]::FindWindow([NullString]::Value, 'AppPackager Suite')
        if ($found -ne [IntPtr]::Zero) { $h = $found; break }
    }
    if ($h -eq [IntPtr]::Zero) { throw 'The launcher window did not open.' }
    [void][Cap.Win]::MoveWindow($h, 80, 80, 760, 560, $true)
    [void][Cap.Win]::SetForegroundWindow($h)
    Start-Sleep -Seconds 4
    $r = New-Object Cap.Win+RECT
    [void][Cap.Win]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $hh))
    $g.Dispose()
    $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    'captured {0}x{1} to {2}' -f $w, $hh, $OutFile
    if ($Base64) { 'PNG64:' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($OutFile)) }
}
finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    if ($hadSettings) { Set-Content -LiteralPath $settingsPath -Value $backup } else { Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
