#requires -Module Pester
<#
.SYNOPSIS
    Headless tests of the loading helpers (Q-47): retry of transient faults, member chunks with a partial result,
    cancel, and background work that hands its items to the UI thread. No Configuration Manager and no window.
#>

BeforeAll {
    Get-Module SuiteCommon | Remove-Module -Force -ErrorAction SilentlyContinue
    $script:manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'SuiteCommon\SuiteCommon.psd1'
    Import-Module $script:manifest -Force -ErrorAction Stop
}

AfterAll {
    Get-Module SuiteCommon | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-SuiteTransientFault' {
    It 'calls <Message> transient: <Expected>' -ForEach @(
        @{ Message = 'The operation has timed out.'; Expected = $true }
        @{ Message = 'The RPC server is unavailable. (0x800706BA)'; Expected = $true }
        @{ Message = 'WinRM cannot complete the operation'; Expected = $true }
        @{ Message = 'Provider load failure'; Expected = $true }
        @{ Message = 'Shutting down'; Expected = $true }
        @{ Message = 'Invalid query'; Expected = $false }
        @{ Message = 'Access is denied.'; Expected = $false }
        @{ Message = 'Not found'; Expected = $false }
    ) {
        $err = try { throw $Message } catch { $_ }
        Test-SuiteTransientFault -ErrorRecord $err | Should -Be $Expected
    }

    It 'never calls a cancel transient' {
        $err = try { throw (New-Object System.OperationCanceledException('timeout cancelled')) } catch { $_ }
        Test-SuiteTransientFault -ErrorRecord $err | Should -BeFalse
    }
}

Describe 'Invoke-SuiteCMRead' {
    It 'retries a transient fault and returns the result of the third attempt' {
        $script:Calls = 0
        $r = Invoke-SuiteCMRead -DelaySeconds 0, 0 -ScriptBlock {
            $script:Calls++
            if ($script:Calls -lt 3) { throw 'The operation has timed out.' }
            'data'
        }
        $r | Should -Be 'data'
        $script:Calls | Should -Be 3
    }

    It 'does not retry a permanent fault' {
        $script:Calls = 0
        { Invoke-SuiteCMRead -DelaySeconds 0 -ScriptBlock { $script:Calls++; throw 'Invalid query' } } | Should -Throw '*Invalid query*'
        $script:Calls | Should -Be 1
    }

    It 'throws after the last attempt of a transient fault' {
        $script:Calls = 0
        { Invoke-SuiteCMRead -DelaySeconds 0, 0 -ScriptBlock { $script:Calls++; throw 'The operation has timed out.' } } | Should -Throw
        $script:Calls | Should -Be 3
    }

    It 'adds one note and returns the default for a permanent fault when -Notes is given' {
        $notes = New-Object System.Collections.ArrayList
        $r = Invoke-SuiteCMRead -DelaySeconds 0 -Description 'Windows of C1' -Notes $notes -Default @() -ScriptBlock { throw 'Invalid query' }
        @($r).Count | Should -Be 0
        $notes.Count | Should -Be 1
        $notes[0] | Should -Match 'Windows of C1 failed after 1 attempt'
    }

    It 'stops at once when the cancel flag is set' {
        $script:Calls = 0
        { Invoke-SuiteCMRead -Cancel @{ Cancel = $true } -ScriptBlock { $script:Calls++ } } | Should -Throw '*cancelled*'
        $script:Calls | Should -Be 0
    }
}

Describe 'Member chunks' {
    BeforeAll {
        # A reader that serves a collection of 5 members from a list, and records each query.
        $script:Members = 16777300, 16777301, 16777305, 16777400, 16777401 | ForEach-Object { [pscustomobject]@{ ResourceID = $_; Name = "PC$_"; Domain = 'D'; IsClient = 1; IsActive = 1 } }
        $script:NewReader = {
            param($Fault)
            $members = $script:Members
            $log = New-Object System.Collections.ArrayList
            $reader = {
                param($Query)
                [void]$log.Add($Query)
                if ($Fault) { & $Fault $Query $log }
                if ($Query -match 'WHERE ResourceID >= (\d+) AND ResourceID <= (\d+)') { $members | Where-Object { $_.ResourceID -ge [long]$Matches[1] -and $_.ResourceID -le [long]$Matches[2] } }
                else { $members }
            }.GetNewClosure()
            [pscustomobject]@{ Reader = $reader; Log = $log }
        }
    }

    It 'cuts the IDs into ranges of ChunkSize members' {
        $r = & $script:NewReader
        $plan = Get-SuiteCollectionMemberPlan -CollectionId 'MCM00001' -ChunkSize 2 -Reader $r.Reader
        $plan.Total | Should -Be 5
        @($plan.Ranges).Count | Should -Be 3
        $plan.Ranges[0].From | Should -Be 16777300
        $plan.Ranges[0].To | Should -Be 16777301
        $plan.Ranges[2].Count | Should -Be 1
        $r.Log[0] | Should -Be 'SELECT ResourceID FROM SMS_CM_RES_COLL_MCM00001'
    }

    It 'reads only the grid columns of one range' {
        $r = & $script:NewReader
        $rows = @(Get-SuiteCollectionMemberChunk -CollectionId 'MCM00001' -FromResourceId 16777300 -ToResourceId 16777305 -Reader $r.Reader)
        $rows.Count | Should -Be 3
        $r.Log[0] | Should -Be 'SELECT ResourceID, Name, Domain, IsClient, IsActive FROM SMS_CM_RES_COLL_MCM00001 WHERE ResourceID >= 16777300 AND ResourceID <= 16777305'
        $rows[0].Name | Should -Be 'PC16777300'
    }

    It 'refuses a collection ID that is not 8 letters or digits' {
        { Get-SuiteCollectionMemberPlan -CollectionId "X' OR 1=1" -Reader { } } | Should -Throw '*Not a collection ID*'
    }

    It 'loads all chunks and reports progress' {
        $r = & $script:NewReader
        $state = [hashtable]::Synchronized(@{ Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Notes = (New-Object System.Collections.ArrayList); Cancel = $false })
        Read-SuiteCollectionMember -State $state -CollectionId 'MCM00001' -ChunkSize 2 -Reader $r.Reader -DelaySeconds 0
        $state['Queue'].Count | Should -Be 3
        $state['Loaded'] | Should -Be 5
        $state['Progress'] | Should -Be 'Loaded 5 of 5 members'
        $state['Notes'].Count | Should -Be 0
    }

    It 'retries a transient fault of one chunk and still delivers every member' {
        $script:Hit = 0
        $fault = { param($q, $log) if ($q -match 'ResourceID >= 16777305') { $script:Hit++; if ($script:Hit -eq 1) { throw 'The operation has timed out.' } } }
        $r = & $script:NewReader $fault
        $state = [hashtable]::Synchronized(@{ Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Notes = (New-Object System.Collections.ArrayList); Cancel = $false })
        Read-SuiteCollectionMember -State $state -CollectionId 'MCM00001' -ChunkSize 2 -Reader $r.Reader -DelaySeconds 0
        $state['Loaded'] | Should -Be 5
        $state['Notes'].Count | Should -Be 0
        $script:Hit | Should -Be 2
    }

    It 'gives a note and the partial data for a chunk that fails for good' {
        $fault = { param($q, $log) if ($q -match 'ResourceID >= 16777305') { throw 'Invalid query' } }
        $r = & $script:NewReader $fault
        $state = [hashtable]::Synchronized(@{ Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Notes = (New-Object System.Collections.ArrayList); Cancel = $false })
        Read-SuiteCollectionMember -State $state -CollectionId 'MCM00001' -ChunkSize 2 -Reader $r.Reader -DelaySeconds 0
        $state['Loaded'] | Should -Be 3
        $state['Notes'].Count | Should -Be 1
        $state['Notes'][0] | Should -Match 'failed after 1 attempt'
    }

    It 'stops the load when the cancel flag is set before the next chunk' {
        $r = & $script:NewReader
        $state = [hashtable]::Synchronized(@{ Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Notes = (New-Object System.Collections.ArrayList); Cancel = $false })
        $reader = { param($Query) if ($Query -match 'ResourceID >= 16777305') { $state['Cancel'] = $true }; & $r.Reader $Query }.GetNewClosure()
        { Read-SuiteCollectionMember -State $state -CollectionId 'MCM00001' -ChunkSize 2 -Reader $reader -DelaySeconds 0 } | Should -Throw '*cancelled*'
        $state['Loaded'] | Should -Be 4
    }
}

Describe 'Start-SuiteBgWork' {
    BeforeAll {
        $script:Rs = [runspacefactory]::CreateRunspace()
        $script:Rs.Open()
    }
    AfterAll {
        try { $script:Rs.Dispose() } catch { $null = $_ }
    }

    It 'hands the queued items to OnItem and then calls OnDone once' {
        $script:Items = New-Object System.Collections.ArrayList
        $script:DoneCount = 0
        $h = Start-SuiteBgWork -Runspace $script:Rs -NoTimer -MaxItemsPerTick 2 -ArgumentList 5 `
            -ScriptBlock { param($State, $n) 1..$n | ForEach-Object { $State['Queue'].Enqueue(@($_)) } } `
            -OnItem { param($item, $state) [void]$script:Items.Add($item[0]) } `
            -OnDone { param($state) $script:DoneCount++ }
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Receive-SuiteBgWork -Handle $h) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        @($script:Items) | Should -Be @(1, 2, 3, 4, 5)
        $script:DoneCount | Should -Be 1
        $h.State['Error'] | Should -BeNullOrEmpty
    }

    It 'reports an error of the worker in State.Error' {
        $h = Start-SuiteBgWork -Runspace $script:Rs -NoTimer -ScriptBlock { param($State) throw 'boom' }
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Receive-SuiteBgWork -Handle $h) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $h.State['Error'] | Should -Be 'boom'
    }

    It 'stops a running load with Stop-SuiteBgWork -Discard and calls no callback after that' {
        $script:DoneCount = 0
        $h = Start-SuiteBgWork -Runspace $script:Rs -NoTimer `
            -ScriptBlock { param($State) while (-not $State['Cancel']) { $State['Queue'].Enqueue(@(1)); Start-Sleep -Milliseconds 20 } } `
            -OnDone { param($state) $script:DoneCount++ }
        Start-Sleep -Milliseconds 200
        $null = Stop-SuiteBgWork -Handle $h -Discard
        $deadline = (Get-Date).AddSeconds(20)
        while (-not $h.State['Done'] -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $h.State['Done'] | Should -BeTrue
        $h.State['Cancel'] | Should -BeTrue
        Receive-SuiteBgWork -Handle $h | Should -BeTrue
        $script:DoneCount | Should -Be 0
    }
}
