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

    It 'treats a lock as stale only after 30 minutes with no running owner, reports a removal and refreshes the lock while the run goes' {
        $script:Text | Should -Match '-gt 30 -and'
        $script:Text | Should -Not -Match 'TotalMinutes -gt 10'
        $script:Text | Should -Match 'Get-Process -Id'
        $script:Text | Should -Match 'the stale lab lock'
        $script:Text | Should -Match '\$lockNotes'
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

Describe 'Run-VisibleProbe remote watchdog' {
    It 'starts a watchdog on the lab computer before the command runs, so a dead runner cannot leave a run unwatched' {
        $watch = $script:Text.IndexOf('.watch.ps1')
        $cmd = $script:Text.IndexOf('SUITE_ALLOW_WINDOW_TESTS')
        $watch | Should -BeGreaterThan 0
        $script:Text.Contains('-WrapPid') | Should -BeTrue
        $script:Text.Contains('remote watchdog') | Should -BeTrue
    }

    It 'ends a run after the total time or after the quiet time, and writes the done flag' {
        $script:Text.Contains('the run did not finish in $Minutes minutes') | Should -BeTrue
        $script:Text.Contains('no output for $Quiet minutes') | Should -BeTrue
        $script:Text.Contains("Set-Content -LiteralPath `"`$Dir\.done`"") | Should -BeTrue
    }
}

Describe 'Run-VisibleProbe stray check and the watchdog' {
    It 'does not count its own watchdog process as a stray process' {
        $script:Text.Contains("-notlike '*.watch.ps1*'") | Should -BeTrue
    }
}

Describe 'Run-VisibleProbe lock format' {
    BeforeAll {
        # The pattern of the runner: owner|pid|start time. Read it from the script, so a change of the format fails here.
        $m = [regex]::Match($script:Text, "\`$text -notmatch '([^']+)'")
        $script:Pattern = $m.Groups[1].Value
    }

    It 'knows the pattern of its own lock text' {
        $script:Pattern | Should -Not -BeNullOrEmpty
        'dt-f|22440|2026-11-15T01:27:34' | Should -Match $script:Pattern
        'pester|1|2026-11-15T01:27:34' | Should -Match $script:Pattern
    }

    It 'treats every other lock text as unknown, never as free' -ForEach @(
        @{ Text = '' }
        @{ Text = 'claude-apd-labcheck' }
        @{ Text = '{"owner":"claude-apd-labcheck","pid":4120}' }
        @{ Text = 'owner=claude-apd-labcheck pid=4120 start=2026-11-15T01:27:34' }
        @{ Text = 'dt-f|abc|2026-11-15T01:27:34' }
        @{ Text = '|22440|2026-11-15T01:27:34' }
    ) {
        $Text | Should -Not -Match $script:Pattern
    }

    It 'blocks on an unknown lock: it reports it, waits, fails with nothing started at the end of the wait and does not remove the lock' {
        $script:Text.Contains("'unknown: ' + `$text") | Should -BeTrue
        $script:Text.Contains("`$got -like 'unknown:*'") | Should -BeTrue
        $script:Text.Contains('Nothing was started') | Should -BeTrue
        $script:Text.Contains('Waiting; the lock is not removed') | Should -BeTrue
        $unknown = $script:Text.IndexOf("'unknown: ' + `$text")
        $held = $script:Text.IndexOf("'held: ' + ")
        $unknown | Should -BeLessThan $held -Because 'the format check comes before the stale check'
    }
}
