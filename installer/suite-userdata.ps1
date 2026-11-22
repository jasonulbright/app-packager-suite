<#
.SYNOPSIS
    Places the shipped default files (templates) without overwriting a file the
    user edited, and removes the untouched ones at uninstall.

.DESCRIPTION
    The build moves every file under a component's Templates folder out of the
    component payload into a defaults tree. The installer runs this script with
    that tree. A tool saves its own templates in the same folder, so a plain
    file copy overwrote the user's edits on every upgrade and deleted them at
    uninstall.

    Mode Place, for each default file (path relative to the install root):

      - absent in the install: copied;
      - identical to the default: left alone;
      - different, and identical to the default the last install recorded:
        the user never edited it, so the new default replaces it;
      - different from both (edited, or no record exists from an older
        installer): the file stays as it is and the new default is written
        beside it as <name>.new.

    The record of what was shipped is suite-defaults.json in the install root.

    Mode Remove (uninstall): a file identical to its recorded default is
    deleted, with its .new file and each folder that becomes empty. An edited
    file stays. The record is deleted last.

    Exit codes: 0 done, 2 at least one file could not be handled (the install
    continues; the file is left as it was).

.PARAMETER Mode
    Place or Remove. Defaults to SUITE_UD_MODE.

.PARAMETER InstallRoot
    The suite install root. Defaults to SUITE_UD_ROOT.

.PARAMETER DefaultsDir
    The defaults tree (Place only). Defaults to SUITE_UD_DEFAULTS.
#>
[CmdletBinding()]
param(
    [string]$Mode = $env:SUITE_UD_MODE,
    [string]$InstallRoot = $env:SUITE_UD_ROOT,
    [string]$DefaultsDir = $env:SUITE_UD_DEFAULTS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Read-Record {
    param([Parameter(Mandatory)][string]$Path)
    $record = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $record }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $record[$p.Name] = [string]$p.Value }
    }
    catch { Write-Host ('The record {0} could not be read; every changed file is treated as edited.' -f $Path) }
    return $record
}

function Write-Record {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Record)
    $ordered = [ordered]@{}
    foreach ($k in ($Record.Keys | Sort-Object)) { $ordered[$k] = $Record[$k] }
    $text = ($ordered | ConvertTo-Json)
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

if ([string]::IsNullOrWhiteSpace($InstallRoot) -or -not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    Write-Host 'The install root does not exist; nothing to do.'
    exit 0
}
$root = (Resolve-Path -LiteralPath $InstallRoot).ProviderPath.TrimEnd('\')
$recordPath = Join-Path $root 'suite-defaults.json'
$failed = 0

if ($Mode -eq 'Place') {
    if ([string]::IsNullOrWhiteSpace($DefaultsDir) -or -not (Test-Path -LiteralPath $DefaultsDir -PathType Container)) {
        Write-Host 'No defaults to place.'
        exit 0
    }
    $defaultsRoot = (Resolve-Path -LiteralPath $DefaultsDir).ProviderPath.TrimEnd('\')
    $old = Read-Record -Path $recordPath
    $new = @{}
    foreach ($k in $old.Keys) { $new[$k] = $old[$k] }
    $placed = 0; $same = 0; $updated = 0; $kept = 0

    # EnumerateFiles returns paths that start with $defaultsRoot exactly. The temp
    # folder of a runner is an 8.3 short path, and Get-ChildItem returns long
    # paths below it, so cutting the root off a long path gives a wrong result.
    foreach ($sourcePath in @([System.IO.Directory]::EnumerateFiles($defaultsRoot, '*', [System.IO.SearchOption]::AllDirectories))) {
        $relative = $sourcePath.Substring($defaultsRoot.Length).TrimStart([char]92)
        $target = Join-Path $root $relative
        try {
            $shipped = Get-Sha256 -Path $sourcePath
            if (-not (Test-Path -LiteralPath $target)) {
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item -LiteralPath $sourcePath -Destination $target
                $placed++
            }
            else {
                $current = Get-Sha256 -Path $target
                if ($current -eq $shipped) { $same++ }
                elseif ($old.ContainsKey($relative) -and $old[$relative] -eq $current) {
                    Copy-Item -LiteralPath $sourcePath -Destination $target -Force
                    $updated++
                }
                else {
                    Copy-Item -LiteralPath $sourcePath -Destination ($target + '.new') -Force
                    $kept++
                    Write-Host ('Kept your edited {0}; the new default is {0}.new' -f $relative)
                }
            }
            $new[$relative] = $shipped
        }
        catch {
            $failed++
            Write-Host ('Could not place {0}: {1}' -f $relative, $_.Exception.Message)
        }
    }
    Write-Record -Path $recordPath -Record $new
    Write-Host ('Defaults: {0} new, {1} unchanged, {2} updated, {3} edited file(s) kept.' -f $placed, $same, $updated, $kept)
}
elseif ($Mode -eq 'Remove') {
    $record = Read-Record -Path $recordPath
    $removed = 0; $kept = 0
    foreach ($relative in @($record.Keys)) {
        $target = Join-Path $root $relative
        try {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                if ((Get-Sha256 -Path $target) -eq $record[$relative]) {
                    Remove-Item -LiteralPath $target -Force
                    $removed++
                }
                else {
                    $kept++
                    Write-Host ('Kept your edited {0}' -f (Join-Path $root $relative))
                }
            }
            $sidecar = $target + '.new'
            if (Test-Path -LiteralPath $sidecar -PathType Leaf) { Remove-Item -LiteralPath $sidecar -Force }
            # Remove each folder that is now empty, up to (not including) the install root.
            $dir = Split-Path -Parent $target
            while ($dir.Length -gt $root.Length -and $dir.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                if (@(Get-ChildItem -LiteralPath $dir -Force).Count -gt 0) { break }
                Remove-Item -LiteralPath $dir -Force
                $dir = Split-Path -Parent $dir
            }
        }
        catch {
            $failed++
            Write-Host ('Could not remove {0}: {1}' -f $relative, $_.Exception.Message)
        }
    }
    if ($failed -eq 0 -and (Test-Path -LiteralPath $recordPath)) { Remove-Item -LiteralPath $recordPath -Force }
    Write-Host ('Defaults: {0} removed, {1} edited file(s) kept.' -f $removed, $kept)
}
else {
    Write-Host ('Unknown mode: {0}' -f $Mode)
    exit 2
}

if ($failed -gt 0) { exit 2 }
exit 0
