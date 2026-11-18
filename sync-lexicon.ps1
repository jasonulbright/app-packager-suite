<#
.SYNOPSIS
    Vendors the ConfigMgr lexicon into the suite repository and into consumer repositories, and reports drift.

.DESCRIPTION
    The canonical lexicon is in the vault: wiki\concepts\configmgr-lexicon\ (configmgr-lexicon.json and
    lexicon-allowlist.json). Step 1 copies these two files from the vault into the lexicon folder of this
    repository. Step 2 copies the lexicon folder (engine, README, data files) and Tests\Lexicon.Guard.Tests.ps1
    into each consumer: Lib\Lexicon and Tests. The file enforce.marker is never copied: a consumer
    owns it. Line endings are ignored when the files are compared.

    -Check compares without copying and exits 1 on drift.

.PARAMETER VaultPath
    Folder with the canonical files. Default: C:\projects\_vault\wiki\concepts\configmgr-lexicon, or the
    environment variable LEXICON_VAULT. When the folder does not exist, step 1 is skipped.

.PARAMETER Consumer
    Consumer repository folders. Default: the 12 PowerShell repositories next to this one.

.EXAMPLE
    .\sync-lexicon.ps1
    .\sync-lexicon.ps1 -Check
    .\sync-lexicon.ps1 -Consumer 'C:\projects\site-hygiene'
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Operator-facing console tool; per-file OK/DRIFT/SYNCED/FAILED lines are the product.')]
param(
    [string]$VaultPath = $(if ($env:LEXICON_VAULT) { $env:LEXICON_VAULT } else { 'C:\projects\_vault\wiki\concepts\configmgr-lexicon' }),
    [string[]]$Consumer = @(),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

if (-not $Consumer -or $Consumer.Count -eq 0) {
    $projectsRoot = Split-Path -Parent $PSScriptRoot
    $Consumer = @(
        'dp-content-manager', 'collection-manager', 'site-hygiene', 'deployment-helper', 'detection-tester', 'installer-analysis',
        'maintenance-window-manager', 'collection-and-compliance-manager', 'app-packager', 'pivots-and-scripts', 'update-planner', 'device-inspector'
    ) | ForEach-Object { Join-Path $projectsRoot $_ }
}

function Get-NormalizedHash {
    # SHA-256 of the text with CRLF turned into LF, so a Git checkout with either line ending compares equal.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))) -replace '-', '' }
    finally { $sha.Dispose() }
}

function Sync-OneFile {
    param([string]$Source, [string]$Destination, [switch]$Check)
    $drift = $false
    try {
        if ((Get-NormalizedHash $Source) -eq (Get-NormalizedHash $Destination)) { Write-Host ("OK     {0}" -f $Destination); return @{ Drift = $false; Failed = $false } }
        $drift = $true
        if ($Check) { Write-Host ("DRIFT  {0}" -f $Destination) }
        else {
            $dir = Split-Path -Parent $Destination
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            Write-Host ("SYNCED {0}" -f $Destination)
        }
        return @{ Drift = $drift; Failed = $false }
    }
    catch {
        Write-Host ("FAILED {0}: {1}" -f $Destination, $_.Exception.Message)
        return @{ Drift = $drift; Failed = $true }
    }
}

$drift = $false
$failures = 0
$lexDir = Join-Path $PSScriptRoot 'lexicon'
$dataFiles = 'configmgr-lexicon.json', 'lexicon-allowlist.json'

# Step 1: vault -> this repository
if (Test-Path -LiteralPath $VaultPath -PathType Container) {
    foreach ($f in $dataFiles) {
        $r = Sync-OneFile -Source (Join-Path $VaultPath $f) -Destination (Join-Path $lexDir $f) -Check:$Check
        if ($r.Drift) { $drift = $true }
        if ($r.Failed) { $failures++ }
    }
}
else {
    Write-Host ("SKIP   vault folder not found: {0}" -f $VaultPath)
}

# Step 2: this repository -> consumers
$files = @(Get-ChildItem -LiteralPath $lexDir -File | Where-Object { $_.Name -ne 'enforce.marker' } | ForEach-Object { $_.Name })
foreach ($c in $Consumer) {
    if (-not (Test-Path -LiteralPath $c -PathType Container)) {
        Write-Host ("SKIP   {0} (consumer path not found or not a directory)" -f $c)
        continue
    }
    foreach ($f in $files) {
        $r = Sync-OneFile -Source (Join-Path $lexDir $f) -Destination (Join-Path $c (Join-Path 'Lib\Lexicon' $f)) -Check:$Check
        if ($r.Drift) { $drift = $true }
        if ($r.Failed) { $failures++ }
    }
    $r = Sync-OneFile -Source (Join-Path $PSScriptRoot 'Tests\Lexicon.Guard.Tests.ps1') -Destination (Join-Path $c 'Tests\Lexicon.Guard.Tests.ps1') -Check:$Check
    if ($r.Drift) { $drift = $true }
    if ($r.Failed) { $failures++ }
}

# Exit codes: 2 = a file failed (real error); 1 = -Check found drift; 0 = clean.
if ($failures -gt 0) { exit 2 }
if ($Check -and $drift) { exit 1 }
