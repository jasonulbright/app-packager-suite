#requires -Module Pester
<#
.SYNOPSIS
    The lab harness stops only what it started. Real processes, no window.

.DESCRIPTION
    An older form of the harness walked ParentProcessId below the processes of its ledger. Windows uses process ids again, so such a
    walk can reach an older, unrelated process whose parent had the same id. A script with that walk ended the signed-in session of a
    lab client. These tests make such an unrelated process and show that no part of the harness stops it, and that the job object
    (tools\ProcessJob.ps1) ends everything that a run started. Every process here is started by the tests and held by its handle.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'tools\LabHarness.Common.ps1')
    . (Join-Path $script:Root 'tools\ProcessJob.ps1')
    $script:Shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Sleep = "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120"

    function Wait-File([string]$Path, [int]$Seconds = 60) {
        $until = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $until) {
            $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
            if ($text -and $text.EndsWith("`n")) { return $text.Trim() }
            Start-Sleep -Milliseconds 200
        }
        throw "no text in $Path after $Seconds s"
    }

    # The process object of an id, with its handle opened while the process runs, so it keeps naming that process.
    function Get-HeldProcess([int]$Id) { $p = Get-Process -Id $Id -ErrorAction Stop; $null = $p.Handle; $p }

    # A script that starts a sleeping child, writes its id to a file and, with -Stay, keeps running.
    function New-ParentScript([string]$Dir, [string]$Name, [switch]$Stay) {
        $idFile = Join-Path $Dir "$Name.child"
        $lines = @(
            "`$c = Start-Process '$($script:Shell)' -ArgumentList '$($script:Sleep)' -PassThru -WindowStyle Hidden"
            "Set-Content -LiteralPath '$idFile' -Value `$c.Id"
        )
        if ($Stay) { $lines += 'Start-Sleep -Seconds 120' }
        $path = Join-Path $Dir "$Name.ps1"
        Set-Content -LiteralPath $path -Value $lines -Encoding Ascii
        [pscustomobject]@{ Script = $path; ChildFile = $idFile }
    }

    # An unrelated process whose parent has ended: it still names the id of that parent as its ParentProcessId.
    function New-Orphan([string]$Dir) {
        $s = New-ParentScript -Dir $Dir -Name ('orphan-' + [guid]::NewGuid().ToString('N'))
        $parent = Start-Process $script:Shell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $s.Script + '"')
        $null = $parent.Handle
        $parentStart = $parent.StartTime
        $orphan = Get-HeldProcess ([int](Wait-File $s.ChildFile))
        if (-not $parent.WaitForExit(30000)) { throw 'the parent did not end' }
        [pscustomobject]@{ ParentId = $parent.Id; ParentStart = $parentStart; Process = $orphan }
    }

    function Stop-Held($Process) { if ($Process -and -not $Process.HasExited) { $Process.Kill() } }

    function Start-Bystander { $p = Start-Process $script:Shell -PassThru -WindowStyle Hidden -ArgumentList $script:Sleep; $null = $p.Handle; $p }
}

Describe 'A reused parent id' {
    BeforeEach {
        $script:Orphan = New-Orphan -Dir $TestDrive
        # The setup is the real hazard: the unrelated process names a parent id that no longer runs.
        (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $script:Orphan.Process.Id)).ParentProcessId | Should -Be $script:Orphan.ParentId
        Get-Process -Id $script:Orphan.ParentId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    AfterEach { Stop-Held $script:Orphan.Process }

    It 'the ledger sweep does not stop it when a dead ledger root had the same id earlier' {
        # The ledger names a run that ended an hour before the unrelated parent got the same id.
        $ledger = Join-Path $TestDrive 'reused.pids'
        Set-Content -LiteralPath $ledger -Value ('{0}|{1}' -f $script:Orphan.ParentId, $script:Orphan.ParentStart.AddHours(-1).Ticks)
        @(Stop-LedgerProcess -Ledger $ledger).Count | Should -Be 0
        $script:Orphan.Process.WaitForExit(2000) | Should -BeFalse
    }

    It 'the ledger sweep does not stop it when the ledger names its parent exactly and that parent has ended' {
        $ledger = Join-Path $TestDrive 'exact.pids'
        Set-Content -LiteralPath $ledger -Value ('{0}|{1}' -f $script:Orphan.ParentId, $script:Orphan.ParentStart.Ticks)
        @(Stop-LedgerProcess -Ledger $ledger).Count | Should -Be 0
        $script:Orphan.Process.WaitForExit(2000) | Should -BeFalse
    }

    It 'ending a run folder does not stop it' {
        $dir = Join-Path $TestDrive 'run-reused'
        New-Item -ItemType Directory $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir '.pids') -Value ('{0}|{1}' -f $script:Orphan.ParentId, $script:Orphan.ParentStart.AddHours(-1).Ticks)
        @(Stop-LabRun -Dir $dir -WaitSeconds 2).Count | Should -Be 0
        $script:Orphan.Process.WaitForExit(2000) | Should -BeFalse
    }
}

Describe 'The job of a run' {
    BeforeEach { $script:Bystander = Start-Bystander }
    AfterEach { Stop-Held $script:Bystander }

    It 'ends the child and the orphaned grandchild of a run, and no other process' {
        $leaf = New-ParentScript -Dir $TestDrive -Name 'leaf'
        $topText = "Start-Process '$($script:Shell)' -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($leaf.Script)`"' -WindowStyle Hidden -Wait:`$false; Start-Sleep -Seconds 120"
        $top = Join-Path $TestDrive 'top.ps1'
        Set-Content -LiteralPath $top -Value $topText -Encoding Ascii
        $run = Start-JobProcess -FilePath $script:Shell -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$top`""
        try {
            # The middle process ends after it started the grandchild: no parent chain leads to the grandchild.
            $grandchild = Get-HeldProcess ([int](Wait-File $leaf.ChildFile))
            $run.MemberIds() | Should -Contain $grandchild.Id
            $run.MemberIds() | Should -Not -Contain $script:Bystander.Id
        }
        finally { Stop-JobProcess -Run $run }
        # No wait here: Stop returns when the members are gone.
        $run.Process.HasExited | Should -BeTrue
        $grandchild.HasExited | Should -BeTrue
        $script:Bystander.WaitForExit(2000) | Should -BeFalse
        Stop-JobProcess -Run $run
    }

    It 'ends the members when the owner of the job is stopped and runs no finally block' {
        $memberFile = Join-Path $TestDrive 'member.txt'
        $owner = Join-Path $TestDrive 'owner.ps1'
        Set-Content -LiteralPath $owner -Encoding Ascii -Value @(
            ". '$(Join-Path $script:Root 'tools\ProcessJob.ps1')'"
            "`$run = Start-JobProcess -FilePath '$($script:Shell)' -ArgumentList '$($script:Sleep)'"
            "Set-Content -LiteralPath '$memberFile' -Value `$run.Process.Id"
            'Start-Sleep -Seconds 120')
        $p = Start-Process $script:Shell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $owner + '"')
        $null = $p.Handle
        $member = $null
        try {
            $member = Get-HeldProcess ([int](Wait-File $memberFile))
            $p.Kill()
            $member.WaitForExit(15000) | Should -BeTrue
            $script:Bystander.HasExited | Should -BeFalse
        }
        finally { Stop-Held $p; Stop-Held $member }
    }

    It 'reports why a watched run ended: <Reason>' -ForEach @(
        @{ Reason = 'time'; Minutes = 0.05; Quiet = 0; StopFile = $false }
        @{ Reason = 'quiet'; Minutes = 5; Quiet = 0.05; StopFile = $false }
        @{ Reason = 'stop'; Minutes = 5; Quiet = 0; StopFile = $true }
    ) {
        $stop = Join-Path $TestDrive "$Reason.stop"
        if ($StopFile) { Set-Content -LiteralPath $stop -Value 'stop' }
        $run = Start-JobProcess -FilePath $script:Shell -ArgumentList $script:Sleep
        try {
            $r = Wait-JobRun -Run $run -Minutes $Minutes -QuietMinutes $Quiet -OutputFile (Join-Path $TestDrive "$Reason.out") -StopFile $stop -PollMilliseconds 200
            $r.Reason | Should -Be $Reason
            $run.Process.HasExited | Should -BeFalse -Because 'the watch stops nothing, the caller closes the job'
        }
        finally { Stop-JobProcess -Run $run }
        $run.Process.WaitForExit(15000) | Should -BeTrue
    }

    It 'lists a member that the run left running' {
        $s = New-ParentScript -Dir $TestDrive -Name 'leaver'
        $run = Start-JobProcess -FilePath $script:Shell -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$($s.Script)`""
        try {
            $left = Get-HeldProcess ([int](Wait-File $s.ChildFile))
            $r = Wait-JobRun -Run $run -Minutes 2 -GraceSeconds 1 -PollMilliseconds 200
            $r.Reason | Should -Be 'exit'
            ($r.Stray -join ' ') | Should -Match ('pid ' + $left.Id + ': powershell')
            ($r.Stray -join ' ') | Should -Not -Match ('pid ' + $script:Bystander.Id + ':')
        }
        finally { Stop-JobProcess -Run $run }
        $left.WaitForExit(15000) | Should -BeTrue
        $script:Bystander.HasExited | Should -BeFalse
    }
}

Describe 'A command run in a job' {
    It 'returns both streams in order and the exit code, and keeps the quotes of the command' {
        $log = Join-Path $TestDrive 'cmd.log'
        $out = @(Invoke-JobCommand -Command '[Console]::Out.WriteLine("one ""two"" \three\"); [Console]::Error.WriteLine(''err''); [Console]::Out.WriteLine(''last''); exit 7' -LogFile $log -PollMilliseconds 200) -join "`n"
        $out | Should -Match '(?s)one "two" \\three\\.*err.*last'
        $out | Should -Match 'EXIT=7'
    }

    It 'ends a command that does not finish, with what it started' {
        $s = New-ParentScript -Dir $TestDrive -Name 'hang' -Stay
        $log = Join-Path $TestDrive 'hang.log'
        $bystander = Start-Bystander
        try {
            $out = @(Invoke-JobCommand -Command "& '$($s.Script)'" -LogFile $log -Minutes 0.2 -PollMilliseconds 200) -join "`n"
            $out | Should -Match 'did not finish in 0\.2 minutes'
            $out | Should -Match 'EXIT=1'
            $id = [int](Wait-File $s.ChildFile 5)
            $until = (Get-Date).AddSeconds(15)
            while ((Get-Process -Id $id -ErrorAction SilentlyContinue) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
            Get-Process -Id $id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $bystander.HasExited | Should -BeFalse
        }
        finally { Stop-Held $bystander }
    }
}

Describe 'The output of a command run in a job' {
    It 'keeps characters outside ASCII' {
        $out = @(Invoke-JobCommand -Command '[Console]::Out.WriteLine(''caf'' + [char]0x00E9)' -LogFile (Join-Path $TestDrive 'oem.log') -PollMilliseconds 200) -join "`n"
        $out | Should -Match ('caf' + [char]0x00E9)
    }
}

Describe 'The launcher of the visible probe' {
    BeforeAll {
        # The real launcher text of tools\Run-VisibleProbe.ps1, run against a wrapper of the test. No window opens.
        $runner = (Get-Content -LiteralPath (Join-Path $script:Root 'tools\Run-VisibleProbe.ps1') -Raw) -replace "`r`n", "`n"
        $m = [regex]::Match($runner, "(?s)\`$launchTemplate = @'`n(?<body>.*?)`n'@")
        if (-not $m.Success) { throw 'the launcher template was not found' }
        $script:LaunchTemplate = $m.Groups['body'].Value

        function New-RunFolder([string]$Name, [string[]]$Wrapper, [string]$Minutes = '3') {
            $d = Join-Path $TestDrive $Name
            New-Item -ItemType Directory $d -Force | Out-Null
            Copy-Item (Join-Path $script:Root 'tools\ProcessJob.ps1') (Join-Path $d '.job.ps1')
            Set-Content -LiteralPath (Join-Path $d '.wrap.ps1') -Value $Wrapper -Encoding Ascii
            Set-Content -LiteralPath (Join-Path $d '.launch.ps1') -Value ($script:LaunchTemplate.Replace('{DIR}', $d).Replace('{MIN}', $Minutes).Replace('{QUIET}', '2')) -Encoding Ascii
            $d
        }
        function Start-Launcher([string]$Dir) {
            $p = Start-Process $script:Shell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $Dir '.launch.ps1') + '"')
            $null = $p.Handle
            $p
        }
    }
    BeforeEach { $script:Bystander = Start-Bystander }
    AfterEach { Stop-Held $script:Bystander }

    It 'finishes a clean run with a done flag and no failure line' {
        $d = New-RunFolder 'clean' @('Set-Content -LiteralPath .out.txt -Value ''EXIT=0''')
        $p = Start-Launcher $d
        try { $p.WaitForExit(90000) | Should -BeTrue } finally { Stop-Held $p }
        Test-Path (Join-Path $d '.done') | Should -BeTrue
        Test-Path (Join-Path $d '.stray') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $d '.out.txt') -Raw).Trim() | Should -Be 'EXIT=0'
        @(Read-LedgerEntry -Path (Join-Path $d '.pids')).Id | Should -Be $p.Id
    }

    It 'fails a run whose wrapper ends without a result' {
        $d = New-RunFolder 'broken' @('throw ''broken wrapper''')
        $p = Start-Launcher $d
        try { $p.WaitForExit(90000) | Should -BeTrue } finally { Stop-Held $p }
        Get-Content -LiteralPath (Join-Path $d '.out.txt') -Raw | Should -Match '(?s)FAIL: remote watchdog: the wrapper ended without a result.*broken wrapper'
    }

    It 'writes the failure line when the time limit ends a wrapper that writes all the time' {
        $d = New-RunFolder 'busywriter' @('while ($true) { Add-Content -LiteralPath .out.txt -Value ''line''; Start-Sleep -Milliseconds 20 }') -Minutes '0.1'
        $p = Start-Launcher $d
        try { $p.WaitForExit(90000) | Should -BeTrue } finally { Stop-Held $p }
        Get-Content -LiteralPath (Join-Path $d '.out.txt') -Raw | Should -Match 'FAIL: remote watchdog: the run did not finish in 0\.1 minutes'
    }

    It 'lists and ends what a run left behind' {
        $s = New-ParentScript -Dir $TestDrive -Name 'stray'
        $d = New-RunFolder 'stray' @("& '$($s.Script)'", 'Set-Content -LiteralPath .out.txt -Value ''EXIT=0''', 'Start-Sleep -Seconds 1')
        $p = Start-Launcher $d
        $left = $null
        try {
            $left = Get-HeldProcess ([int](Wait-File $s.ChildFile))
            $p.WaitForExit(90000) | Should -BeTrue
            $left.WaitForExit(15000) | Should -BeTrue
            Get-Content -LiteralPath (Join-Path $d '.stray') -Raw | Should -Match ('pid ' + $left.Id + ':')
            $script:Bystander.HasExited | Should -BeFalse
        }
        finally { Stop-Held $p; Stop-Held $left }
    }

    It 'ends the run and what it started when the run folder is ended, and nothing else' {
        $s = New-ParentScript -Dir $TestDrive -Name 'busy' -Stay
        $d = New-RunFolder 'busy' @("& '$($s.Script)'")
        $p = Start-Launcher $d
        $child = $null
        try {
            $child = Get-HeldProcess ([int](Wait-File $s.ChildFile))
            @(Stop-LabRun -Dir $d -WaitSeconds 30).Count | Should -Be 0 -Because 'the launcher ends the run itself'
            $p.WaitForExit(15000) | Should -BeTrue
            $child.WaitForExit(15000) | Should -BeTrue
            $script:Bystander.HasExited | Should -BeFalse
        }
        finally { Stop-Held $p; Stop-Held $child }
    }

    It 'ends the run when a launcher that does not answer is stopped by its ledger line' {
        $s = New-ParentScript -Dir $TestDrive -Name 'deaf' -Stay
        $d = New-RunFolder 'deaf' @("& '$($s.Script)'")
        $p = Start-Launcher $d
        $child = $null
        try {
            $child = Get-HeldProcess ([int](Wait-File $s.ChildFile))
            $out = @(Stop-LabRun -Dir $d -WaitSeconds 0)
            ($out -join ' ') | Should -Match ('pid ' + $p.Id + ':')
            $p.WaitForExit(15000) | Should -BeTrue
            $child.WaitForExit(15000) | Should -BeTrue
            $script:Bystander.HasExited | Should -BeFalse
        }
        finally { Stop-Held $p; Stop-Held $child }
    }
}
