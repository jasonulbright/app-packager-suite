#requires -Module Pester
<#
.SYNOPSIS
    Guard for the lab window runner: it must take the exclusive lock on the lab computer before it opens any window,
    refresh the lock while the run goes, release it in a finally block, and fail a run that leaves stray processes.
    Two window runs on the one desktop corrupt each other, so a runner without the lock is a defect.
#>

BeforeAll {
    $script:Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Run-VisibleProbe.ps1'
    $script:Text = Get-Content -LiteralPath $script:Path -Raw
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$null, [ref]$null)
}

Describe 'Run-VisibleProbe lab lock' {
    It 'names the shared lock file of the guide captures' {
        $script:Text.Contains('C:\guide\capture.lock') | Should -BeTrue
    }

    It 'takes the lock before the first scheduled task is registered or started' {
        $lock = $script:Text.IndexOf('$haveLock = $true')
        $task = $script:Text.IndexOf('Register-ScheduledTask')
        $lock | Should -BeGreaterThan 0
        $task | Should -BeGreaterThan $lock
    }

    It 'copies the repo and starts the run only after the lock' {
        $lock = $script:Text.IndexOf('$haveLock = $true')
        $copy = $script:Text.IndexOf('Copy-Item -LiteralPath $i.FullName')
        $copy | Should -BeGreaterThan $lock
    }

    It 'treats a lock older than 30 minutes as stale and refreshes the lock while the run goes' {
        $script:Text | Should -Match 'TotalMinutes -gt 30'
        $script:Text | Should -Match 'LastWriteTime = Get-Date'
    }

    It 'releases the lock in a finally block, only when this run took it' {
        $finals = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally }, $true))
        @($finals | Where-Object { $_.Finally.Extent.Text -match '\$haveLock' -and $_.Finally.Extent.Text -match 'Remove-Item -LiteralPath \$path' }).Count | Should -BeGreaterThan 0
    }

    It 'ends stray processes before the run and fails a run that leaves any behind' {
        $script:Text.Contains("CommandLine -like '*C:\guide\*'") | Should -BeTrue
        $script:Text | Should -Match 'left \$\(\$stray\.Count\) stray process'
    }

    It 'never signs out, locks, disconnects or restarts the lab session' {
        $script:Text | Should -Not -Match '(?i)logoff|shutdown|Restart-Computer|tsdiscon|LockWorkStation'
    }
}
