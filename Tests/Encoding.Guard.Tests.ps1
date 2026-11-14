#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x guard: every PowerShell source file and every file a script or test reads is plain ASCII
    (.ps1 .psm1 .psd1 .ps1xml .json .xml .xaml .csv .txt .config .md).
    No UTF-8 BOM, no byte above 0x7F (no em dash, en dash, emoji, curly quote or accented letter).
    Output a non-ASCII character with a code, for example [char]0x00B7 or [char]::ConvertFromUtf32(0x1F642).
    PowerShell 5.1 reads a file without a BOM as ANSI, so a non-ASCII character in a script changes or breaks it.
#>

BeforeDiscovery {
    $script:Root = Split-Path -Path $PSScriptRoot -Parent
    $script:Files = @(Get-ChildItem -LiteralPath $script:Root -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.ps1xml', '.json', '.xml', '.xaml', '.csv', '.txt', '.config', '.md' } |
            Where-Object { $_.FullName.Substring($script:Root.Length) -notmatch '[\\/](\.git|\.claude|node_modules)[\\/]|[\\/]Lib[\\/](?!SuiteCommon)' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($script:Root.Length + 1) } })
}

Describe 'PowerShell source and data files are plain ASCII' {
    It 'finds PowerShell files' {
        # BeforeDiscovery variables are not visible in the run phase: look again.
        $root = Split-Path -Path $PSScriptRoot -Parent
        @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }).Count | Should -BeGreaterThan 0
    }

    It 'has no BOM and no non-ASCII byte in <Name>' -ForEach $script:Files {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $hasBom | Should -BeFalse -Because 'a UTF-8 BOM is not allowed; remove it'
        $bad = New-Object System.Collections.Generic.List[string]
        $line = 1
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { $line++ }
            elseif ($bytes[$i] -gt 127) { $bad.Add(('line {0}' -f $line)); while ($i + 1 -lt $bytes.Length -and $bytes[$i + 1] -gt 127) { $i++ } }
        }
        $bad | Select-Object -First 5 | Should -BeNullOrEmpty -Because 'use [char] codes for non-ASCII characters'
    }
}
