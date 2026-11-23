#requires -Module Pester
<#
.SYNOPSIS
    Tests of the real-window harness library (tools\LabHarness.Common.ps1, Q-118): lock decisions, ledger handling and the
    leftover-process stop, the app-window filter, the preflight and the run snapshot. No test opens a window.
#>

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\LabHarness.Common.ps1')
    function New-Win { param($Class = 'HwndWrapper[App;;x]', $Title = 'T', $Process = 'powershell', [int]$ProcessId = 100, [bool]$Visible = $true) [pscustomobject]@{ Handle = [IntPtr]1; ProcessId = $ProcessId; Process = $Process; Class = $Class; Title = $Title; Visible = $Visible } }
}

Describe 'Lock text and decision' {
    It 'parses owner|pid|start and rejects other text' {
        $l = ConvertFrom-LockText -Text 'deployment-helper|4242|2026-11-23T14:10:00'
        $l.Owner | Should -Be 'deployment-helper'
        $l.ProcessId | Should -Be 4242
        ConvertFrom-LockText -Text 'busy' | Should -BeNullOrEmpty
        ConvertFrom-LockText -Text '' | Should -BeNullOrEmpty
        ConvertFrom-LockText -Text '|1|2026-11-23T14:10:00' | Should -BeNullOrEmpty
    }

    It 'waits while the owner is alive, however old the lock is' {
        Get-LockDecision -Text 'a|1|2026-11-23T14:10:00' -AgeMinutes 600 -AliveLab $true -AliveHere $false | Should -Be 'held'
        Get-LockDecision -Text 'a|1|2026-11-23T14:10:00' -AgeMinutes 600 -AliveLab $false -AliveHere $true | Should -Be 'held'
    }

    It 'waits while the lock is fresh, even with no owner process' {
        Get-LockDecision -Text 'a|1|2026-11-23T14:10:00' -AgeMinutes 30 -AliveLab $false -AliveHere $false | Should -Be 'held'
    }

    It 'calls a lock stale only after 30 minutes with no owner on either computer' {
        Get-LockDecision -Text 'a|1|2026-11-23T14:10:00' -AgeMinutes 31 -AliveLab $false -AliveHere $false | Should -Be 'stale'
    }

    It 'never frees a lock in an unknown format' {
        Get-LockDecision -Text 'garbage' -AgeMinutes 999 -AliveLab $false -AliveHere $false | Should -Be 'unknown'
        Get-LockDecision -Text '' -AgeMinutes 999 -AliveLab $false -AliveHere $false | Should -Be 'unknown'
    }

    It 'names the holder in the wait line' {
        Format-LockHolder -Text 'deployment-helper|4242|2026-11-23T14:10:00' -AgeMinutes 3 | Should -Be 'lock held by deployment-helper (pid 4242, since 2026-11-23T14:10:00, last refresh 3 min ago)'
        Format-LockHolder -Text 'x' -AgeMinutes 3 | Should -Match 'unknown'
    }

    It 'a file created with its text in one step lets exactly one of two runs take it' {
        $f = Join-Path $TestDrive 'capture.lock'
        New-Item -ItemType File -Path $f -Value 'one|1|2026-11-23T14:10:00' -ErrorAction Stop | Out-Null
        { New-Item -ItemType File -Path $f -Value 'two|2|2026-11-23T14:10:01' -ErrorAction Stop } | Should -Throw
        (Get-Content -LiteralPath $f -Raw).Trim() | Should -Be 'one|1|2026-11-23T14:10:00'
    }
}

Describe 'Ledger' {
    It 'reads only well-formed lines' {
        $f = Join-Path $TestDrive 'a.pids'
        Set-Content -LiteralPath $f -Value @('12|345', 'junk', '', '7|8')
        $e = @(Read-LedgerEntry -Path $f)
        $e.Count | Should -Be 2
        $e[0].Id | Should -Be 12
        $e[1].Ticks | Should -Be 8
        @(Read-LedgerEntry -Path (Join-Path $TestDrive 'none.pids')).Count | Should -Be 0
    }

    It 'finds the ledgers of the harness and of the guide captures under a root' {
        $r = Join-Path $TestDrive 'guide'
        New-Item -ItemType Directory (Join-Path $r 'visible-x'), (Join-Path $r 'dh\ui'), (Join-Path $r 'other') -Force | Out-Null
        Set-Content (Join-Path $r 'visible-x\.pids') '1|2'
        Set-Content (Join-Path $r 'dh\ui\run.pids') '1|2'
        $found = @(Get-LedgerPath -Root $r)
        $found.Count | Should -Be 2
        @(Get-LedgerPath -Root (Join-Path $TestDrive 'missing')).Count | Should -Be 0
    }

    It 'stops a leftover process that the ledger names with its start time, and leaves a process with the same id and another start time' {
        $keep = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60'
        $kill = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60'
        try {
            $f = Join-Path $TestDrive 'run.pids'
            Set-Content -LiteralPath $f -Value @(('{0}|{1}' -f $kill.Id, $kill.StartTime.Ticks), ('{0}|{1}' -f $keep.Id, ($keep.StartTime.Ticks + 1)))
            $out = @(Stop-LedgerProcess -Ledger $f)
            $kill.WaitForExit(10000) | Should -BeTrue
            $keep.HasExited | Should -BeFalse
            ($out -join ' ') | Should -Match ('pid ' + $kill.Id)
            ($out -join ' ') | Should -Not -Match ('pid ' + $keep.Id)
        }
        finally { foreach ($p in $keep, $kill) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } }
    }
}

Describe 'App window filter' {
    It 'selects WPF, WinForms and PowerShell dialog windows' {
        $r = @((New-Win), (New-Win -Class 'WindowsForms10.Window.8.app'), (New-Win -Class '#32770') | Select-AppWindow)
        $r.Count | Should -Be 3
    }

    It 'leaves out console windows, hidden windows, the shell and a dialog of another program' {
        $r = @((New-Win -Class 'ConsoleWindowClass'), (New-Win -Visible $false), (New-Win -Class 'CabinetWClass' -Process 'explorer'), (New-Win -Class '#32770' -Process 'notepad') | Select-AppWindow)
        $r.Count | Should -Be 0
    }

    It 'lists windows with process id, class and title' {
        Format-WindowList -Window (New-Win -Title 'Deployment Helper' -ProcessId 7) | Should -Be '[pid 7 powershell HwndWrapper[App;;x] "Deployment Helper"]'
        Format-WindowList -Window @() | Should -Be 'none'
    }
}

Describe 'Preflight and snapshot' {
    It 'passes on a clean desktop' {
        Mock Get-StrayAppWindow { @() }
        @(Test-DesktopClean).Count | Should -Be 0
    }

    It 'returns the stray windows and does not close them without -Close' {
        Mock Get-StrayAppWindow { @(New-Win -Title 'Left over') }
        Mock Close-AppWindow {}
        $r = @(Test-DesktopClean)
        $r.Count | Should -Be 1
        Should -Invoke Close-AppWindow -Times 0
    }

    It 'closes stray windows with -Close and checks again' {
        $script:n = 0
        Mock Get-StrayAppWindow { $script:n++; if ($script:n -eq 1) { @(New-Win -Title 'Left over') } else { @() } }
        Mock Close-AppWindow {}
        @(Test-DesktopClean -Close -WaitSeconds 0).Count | Should -Be 0
        Should -Invoke Close-AppWindow -Times 1
    }

    It 'still reports a window that did not close' {
        Mock Get-StrayAppWindow { @(New-Win -Title 'Stubborn') }
        Mock Close-AppWindow {}
        @(Test-DesktopClean -Close -WaitSeconds 0).Count | Should -Be 1
    }

    It 'builds a snapshot line with run, user, theme and window titles' {
        $line = Format-RunSnapshot -Phase 'start' -Run 'deployment-helper' -User 'labadmin' -SessionId 2 -Theme ([pscustomobject]@{ AppsUseLightTheme = 1; SystemUsesLightTheme = 0 }) -Window (New-Win -Title 'Options' -ProcessId 9)
        $line | Should -Match '^HARNESS start: \d{4}-\d{2}-\d{2}T'
        $line | Should -Match 'run=deployment-helper user=labadmin session=2 AppsUseLightTheme=1 SystemUsesLightTheme=0'
        $line | Should -Match 'windows=\[pid 9 powershell HwndWrapper\[App;;x\] "Options"\]'
    }

    It 'appends the snapshot to the run output' {
        Mock Get-StrayAppWindow { @() }
        Mock Get-LabThemeInfo { [pscustomobject]@{ AppsUseLightTheme = 1; SystemUsesLightTheme = 1 } }
        $f = Join-Path $TestDrive 'out.txt'
        $null = Write-RunSnapshot -Phase 'end' -Run 'r' -Path $f
        (Get-Content -LiteralPath $f -Raw) | Should -Match 'HARNESS end:.*windows=none'
    }
}

Describe 'Library file' {
    It 'is plain ASCII and names no command-line selection of processes' {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\LabHarness.Common.ps1'
        [IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'CommandLine|(?i)logoff|shutdown|Restart-Computer|tsdiscon|LockWorkStation'
    }
}
