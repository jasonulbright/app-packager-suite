<#
.SYNOPSIS
    Archives a retired component folder and merges every file of it into
    <MigrateTo>\legacy\<folder>. Nothing is overwritten and nothing is deleted
    unless it is proven kept.

.DESCRIPTION
    Runs from the suite installer for a component that no longer ships.

      1. The whole old folder is zipped to <LegacyRoot>\<folder>.zip. When that
         name exists, the zip gets a time stamp (and a counter if needed). An
         earlier archive is never overwritten and never replaced.
      2. The zip is opened and its file count is compared with the folder.
         A zip that cannot be read, or that holds fewer files, stops the run
         and leaves the old folder in place.
      3. merge-user-folder.ps1 moves every file into <LegacyRoot>\<folder>. A
         file that already exists there with the same content is removed from
         the old folder; a file with different content is kept under a numbered
         name. The old folder is removed only when no file is left in it.

    Exit codes: 0 done (or nothing to do), 2 files remain in the old folder,
    3 the archive failed or did not verify, so nothing was moved or removed.

.PARAMETER Source
    The old component folder. Defaults to the SUITE_RETIRE_SRC environment variable.

.PARAMETER LegacyRoot
    The legacy folder, <MigrateTo>\legacy. Defaults to SUITE_RETIRE_LEGACY.
#>
[CmdletBinding()]
param(
    [string]$Source = $env:SUITE_RETIRE_SRC,
    [string]$LegacyRoot = $env:SUITE_RETIRE_LEGACY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($LegacyRoot)) {
    Write-Host 'Retire needs a Source and a LegacyRoot folder.'
    exit 2
}
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { exit 0 }

$sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
$name = Split-Path -Leaf $sourceRoot
New-Item -ItemType Directory -Path $LegacyRoot -Force | Out-Null
$legacyDir = Join-Path $LegacyRoot $name

# A unique archive name: never an existing file.
$zip = Join-Path $LegacyRoot ($name + '.zip')
if (Test-Path -LiteralPath $zip) {
    $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
    $zip = Join-Path $LegacyRoot ('{0}-{1}.zip' -f $name, $stamp)
    $counter = 1
    while (Test-Path -LiteralPath $zip) {
        $zip = Join-Path $LegacyRoot ('{0}-{1}-{2}.zip' -f $name, $stamp, $counter)
        $counter++
    }
}

$fileCount = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force).Count
if ($fileCount -gt 0) {
    try {
        Write-Host ('Archiving {0} to {1}' -f $sourceRoot, $zip)
        # No -Force: the name is new, and an existing file stops the run.
        Compress-Archive -LiteralPath $sourceRoot -DestinationPath $zip -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try { $entries = @($archive.Entries | Where-Object { $_.Name -ne '' }).Count }
        finally { $archive.Dispose() }
        if ($entries -lt $fileCount) {
            throw ('the archive holds {0} file(s), the folder holds {1}' -f $entries, $fileCount)
        }
    }
    catch {
        Write-Host ('Archive of {0} failed: {1}; the folder is left in place.' -f $name, $_.Exception.Message)
        exit 3
    }
}

New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
& (Join-Path $PSScriptRoot 'merge-user-folder.ps1') -Source $sourceRoot -Destination $legacyDir
exit $LASTEXITCODE
