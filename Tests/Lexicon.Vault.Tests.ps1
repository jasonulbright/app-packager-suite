#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x guard: the lexicon data files of this repository equal the canonical files in the vault.
    The tests skip when the vault folder is absent (CI and the lab VMs have no vault).
    Folder: the environment variable LEXICON_VAULT, or C:\projects\_vault\wiki\concepts\configmgr-lexicon.
    Fix a failure with: .\sync-lexicon.ps1 (copies the vault files here and into the consumer repositories).
#>

BeforeDiscovery {
    $vault = if ($env:LEXICON_VAULT) { $env:LEXICON_VAULT } else { 'C:\projects\_vault\wiki\concepts\configmgr-lexicon' }
    $script:VaultPresent = Test-Path -LiteralPath $vault -PathType Container
    $script:Cases = @('configmgr-lexicon.json', 'lexicon-allowlist.json') | ForEach-Object { @{ Name = $_ } }
}

BeforeAll {
    function Get-NormalizedText {
        param([string]$Path)
        [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    }
    $script:Vault = if ($env:LEXICON_VAULT) { $env:LEXICON_VAULT } else { 'C:\projects\_vault\wiki\concepts\configmgr-lexicon' }
    $script:LexDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lexicon'
}

Describe 'Lexicon copy equals the vault file' {
    It '<Name> equals the vault file' -ForEach $script:Cases {
        if (-not $script:VaultPresent) { Set-ItResult -Skipped -Because 'the vault folder is not present'; return }
        $a = Get-NormalizedText (Join-Path $script:Vault $Name)
        $b = Get-NormalizedText (Join-Path $script:LexDir $Name)
        $b | Should -BeExactly $a -Because 'run sync-lexicon.ps1: the vault holds the canonical file'
    }
}
