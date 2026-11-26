#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Parse-only guard (vault: testing-policy, "Process rules on a lab VM"). A script in tools\ stops only a process that it started and
# knows by process id. It never stops a process by a command-line pattern, because another session may own a process that matches.
# Nothing runs and no window opens.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ToolDir = Join-Path $script:Root 'tools'
    $script:Files = @(Get-ChildItem -LiteralPath $script:ToolDir -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cmd', '.bat' })
    # Every code line of every tool script, as 'file:line text'. Comment lines are skipped.
    $script:Lines = foreach ($f in $script:Files) {
        $n = 0
        foreach ($l in (Get-Content -LiteralPath $f.FullName)) {
            $n++
            if ($l.TrimStart().StartsWith('#')) { continue }
            [pscustomobject]@{ Where = ('{0}:{1}' -f $f.Name, $n); Text = $l }
        }
    }
    function Get-Hits([string]$Pattern) { @($script:Lines | Where-Object { $_.Text -match $Pattern } | ForEach-Object { $_.Where }) }
}

Describe 'The tools stop only their own processes' {
    It 'finds the tool scripts' {
        $script:Files.Count | Should -BeGreaterThan 0
    }

    It 'never calls taskkill' {
        Get-Hits '(?i)\btaskkill\b' | Should -BeNullOrEmpty
    }

    It 'never matches a process by its command line' {
        Get-Hits '[.]CommandLine([^A-Za-z]|$)' | Should -BeNullOrEmpty
    }

    It 'never walks parent ids: Windows uses process ids again, so a walk can reach a process that the run did not start' {
        Get-Hits '(?i)ParentProcessId|ParentProcess\b|\.Parent\.Id' | Should -BeNullOrEmpty
    }

    It 'never reads the process list of WMI' {
        Get-Hits '(?i)Win32_Process' | Should -BeNullOrEmpty
    }

    It 'never stops a process with Stop-Process: a stop uses a held process object or the job of the run' {
        Get-Hits '(?i)\bStop-Process\b|\bspps\b|\bwmic\b|Invoke-(Cim|Wmi)Method|CloseMainWindow|ForEach-Object\s+(-MemberName\s+)?Kill\b' | Should -BeNullOrEmpty
    }

    It 'calls Kill only at the two known places: the ledger stop and the launcher capture stop of its own process' {
        $calls = @($script:Lines | Where-Object { $_.Text -match '\.Kill\(' } | ForEach-Object { ($_.Where -split ':')[0] + ' ' + $_.Text.Trim() })
        $calls.Count | Should -Be 2
        $calls | Should -Contain 'LabHarness.Common.ps1 $p.Kill()'
        $calls | Should -Contain 'Capture-Launcher.ps1 if ($p -and -not $p.HasExited) { $p.Kill() }'
    }
}

Describe 'The lab probes stop a run through its job object' {
    It 'starts every run through the job helper' {
        foreach ($name in 'Run-VisibleProbe.ps1', 'Run-LabProbe.ps1') {
            Get-Content -LiteralPath (Join-Path $script:ToolDir $name) -Raw | Should -Match 'ProcessJob\.ps1'
        }
        Get-Content -LiteralPath (Join-Path $script:ToolDir 'Run-VisibleProbe.ps1') -Raw | Should -Match 'Start-JobProcess'
        Get-Content -LiteralPath (Join-Path $script:ToolDir 'Run-LabProbe.ps1') -Raw | Should -Match 'Invoke-JobCommand'
    }

    It 'creates the process suspended and puts it into the job before it runs' {
        $text = Get-Content -LiteralPath (Join-Path $script:ToolDir 'ProcessJob.ps1') -Raw
        $text | Should -Match '0x4 \| 0x08000000'
        $text.IndexOf('AssignProcessToJobObject(job, information.hProcess)') | Should -BeLessThan $text.IndexOf('ResumeThread(information.hThread)')
    }
}
