<#
.SYNOPSIS
    Merges every file of a renamed install folder into its replacement and
    removes the old folder only when no file is left in it.

.DESCRIPTION
    Runs from the suite installer when both the old and the new folder exist.
    Each file under Source is handled by its relative path:

      - absent under Destination: moved there;
      - present with identical content: the Source copy is deleted;
      - present with different content: Destination keeps its file and the
        Source copy moves to <Destination>\legacy\<Source folder name>\.

    The Source folder is deleted only after a pass that moved or kept every
    file and found no file left. A file that cannot move (for example one that
    a running tool holds open) stays in place, the script exits with 2, and the
    next run continues from the remaining files.

    Exit codes: 0 merged and old folder removed (or nothing to merge), 2 files
    remain in Source, 3 the empty Source folder could not be removed.

.PARAMETER Source
    The old folder. Defaults to the SUITE_MERGE_SRC environment variable.

.PARAMETER Destination
    The new folder. Defaults to the SUITE_MERGE_DST environment variable.
#>
[CmdletBinding()]
param(
    [string]$Source = $env:SUITE_MERGE_SRC,
    [string]$Destination = $env:SUITE_MERGE_DST
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileDigest {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)) }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Test-SameContent {
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    if ((New-Object System.IO.FileInfo($A)).Length -ne (New-Object System.IO.FileInfo($B)).Length) { return $false }
    return ((Get-FileDigest -Path $A) -eq (Get-FileDigest -Path $B))
}

function Initialize-ParentFolder {
    param([Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
}

if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Destination)) {
    Write-Host 'Merge needs a Source and a Destination folder.'
    exit 2
}
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { exit 0 }
if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    Write-Host ('Merge target does not exist: {0}' -f $Destination)
    exit 2
}

$sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
$destinationRoot = (Resolve-Path -LiteralPath $Destination).ProviderPath.TrimEnd('\')
if ($sourceRoot -ieq $destinationRoot) {
    Write-Host 'Merge source and target are the same folder.'
    exit 2
}
$keptRoot = Join-Path (Join-Path $destinationRoot 'legacy') (Split-Path -Leaf $sourceRoot)

$moved = 0; $duplicate = 0; $kept = 0; $failed = 0
foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $target = Join-Path $destinationRoot $relative
    try {
        if (-not (Test-Path -LiteralPath $target)) {
            Initialize-ParentFolder -Path $target
            [System.IO.File]::Move($file.FullName, $target)
            $moved++
        }
        elseif ((Test-Path -LiteralPath $target -PathType Leaf) -and (Test-SameContent -A $file.FullName -B $target)) {
            Remove-Item -LiteralPath $file.FullName -Force
            $duplicate++
        }
        else {
            $keep = Join-Path $keptRoot $relative
            $suffix = 1
            while (Test-Path -LiteralPath $keep) { $keep = Join-Path $keptRoot ('{0}.{1}' -f $relative, $suffix); $suffix++ }
            Initialize-ParentFolder -Path $keep
            [System.IO.File]::Move($file.FullName, $keep)
            $kept++
            Write-Host ('Conflict: {0} differs from the file in the new folder; the old copy is kept as {1}' -f $relative, $keep)
        }
    }
    catch {
        $failed++
        Write-Host ('Could not move {0}: {1}' -f $file.FullName, $_.Exception.Message)
    }
}

$remaining = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)
if ($failed -gt 0 -or $remaining.Count -gt 0) {
    Write-Host ('{0} file(s) remain in {1}; the folder is left in place.' -f $remaining.Count, $sourceRoot)
    exit 2
}

try { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
catch {
    Write-Host ('Could not remove {0}: {1}' -f $sourceRoot, $_.Exception.Message)
    exit 3
}
Write-Host ('Merged {0} into {1}: {2} moved, {3} identical, {4} conflicting kept under {5}.' -f $sourceRoot, $destinationRoot, $moved, $duplicate, $kept, $keptRoot)
exit 0
