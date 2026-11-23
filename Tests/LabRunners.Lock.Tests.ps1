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
        $lib = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\LabHarness.Common.ps1') -Raw
        $lib | Should -Match '-gt \$StaleMinutes -and'
        $lib | Should -Match '\$StaleMinutes = 30'
        $script:Text | Should -Match 'Get-LockDecision'
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

    It 'ends the left-over processes of its own ledger before the run and fails a run that leaves any behind' {
        $script:Text | Should -Match '\.pids'
        $script:Text | Should -Not -Match 'CommandLine'
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
        # The watchdog is recorded in the ledger of the run, and the stray check skips every process of the ledger.
        $script:Text | Should -Match 'Select-Object -Skip 1'
        $script:Text | Should -Match 'w\.Id, .{1,2}w\.StartTime\.Ticks'
    }
}

Describe 'Run-VisibleProbe lock format' {
    BeforeAll {
        # The format check lives in the shared library: owner|pid|start time. The runner decides with Get-LockDecision.
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\LabHarness.Common.ps1')
    }

    It 'knows the pattern of its own lock text' {
        ConvertFrom-LockText -Text 'dt-f|22440|2026-11-15T01:27:34' | Should -Not -BeNullOrEmpty
        ConvertFrom-LockText -Text 'pester|1|2026-11-15T01:27:34' | Should -Not -BeNullOrEmpty
    }

    It 'treats every other lock text as unknown, never as free' -ForEach @(
        @{ Text = '' }
        @{ Text = 'claude-apd-labcheck' }
        @{ Text = '{"owner":"claude-apd-labcheck","pid":4120}' }
        @{ Text = 'owner=claude-apd-labcheck pid=4120 start=2026-11-15T01:27:34' }
        @{ Text = 'dt-f|abc|2026-11-15T01:27:34' }
        @{ Text = '|22440|2026-11-15T01:27:34' }
    ) {
        Get-LockDecision -Text $Text -AgeMinutes 9999 -AliveLab $false -AliveHere $false | Should -Be 'unknown'
    }

    It 'blocks on an unknown lock: it reports it, waits, fails with nothing started at the end of the wait and does not remove the lock' {
        $script:Text.Contains("`$decision -eq 'unknown'") | Should -BeTrue
        $script:Text.Contains('Nothing was started') | Should -BeTrue
        $script:Text.Contains('Waiting; the lock is not removed') | Should -BeTrue
        # Only the stale branch removes the lock.
        $stale = $script:Text.IndexOf("`$decision -eq 'stale'")
        $remove = $script:Text.IndexOf('Remove-Item -LiteralPath $path -Force', $script:Text.IndexOf('$got -like'))
        $remove | Should -BeGreaterThan $stale
    }
}
Describe 'Run-VisibleProbe hardening (Q-118)' {
    It 'creates the lock file with its text in one step, so a waiting run never reads an empty lock' {
        $script:Text | Should -Match '\[IO\.File\]::Move\(\$tmp, \$path\)'
    }

    It 'writes who holds the lock to the output of a waiting run' {
        $script:Text | Should -Match 'Format-LockHolder'
        $script:Text | Should -Match 'LOCK: waiting'
    }

    It 'sweeps every ledger under C:\guide after it took the lock and before it copies the repo' {
        $lock = $script:Text.IndexOf('$haveLock = $true')
        $sweep = $script:Text.IndexOf('Get-LedgerPath')
        $copy = $script:Text.IndexOf('Copy-Item -LiteralPath $i.FullName')
        $sweep | Should -BeGreaterThan $lock
        $copy | Should -BeGreaterThan $sweep
    }

    It 'records a HARNESS snapshot at the start and at the end of the run and refuses to start on a desktop with stray app windows' {
        $script:Text | Should -Match "Write-RunSnapshot -Phase 'start'"
        $script:Text | Should -Match "Write-RunSnapshot -Phase 'end'"
        $script:Text | Should -Match 'FAIL: preflight'
        $cmd = $script:Text.IndexOf('& { {CMD} }')
        $script:Text.IndexOf("Phase 'start'") | Should -BeLessThan $cmd
        $script:Text.IndexOf('Test-DesktopClean -Close') | Should -BeLessThan $cmd
    }

    It 'closes the windows that the run left open and reports them' {
        $script:Text | Should -Match 'WARN: leak'
        $script:Text | Should -Match 'Close-AppWindow'
    }

    It 'ends the run by ledger in the finally block before it releases the lock, and cleans up only a run that took the lock' {
        $fin = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Releasing the lab lock' }, $true))
        $fin.Count | Should -Be 1
        $t = $fin[0].Finally.Extent.Text
        $t | Should -Match 'if \(\$haveLock\)'
        $t.IndexOf("'All'") | Should -BeGreaterThan 0
        $t.IndexOf("'All'") | Should -BeLessThan $t.IndexOf('Releasing the lab lock')
        $t.IndexOf('Stop-ScheduledTask') | Should -BeGreaterThan 0
        $t.IndexOf('Unregister-ScheduledTask') | Should -BeLessThan $t.IndexOf('Releasing the lab lock')
    }
}