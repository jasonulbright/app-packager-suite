#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the suite update check and self-update in SuiteCommon.

.DESCRIPTION
    The release lookup, the download and the signature check are mocked
    inside the module; the cache is redirected into the test drive. No
    network, no installer run.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\SuiteCommon\SuiteCommon.psd1" -Force -DisableNameChecking
    $script:OrigLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
}

AfterAll {
    $env:LOCALAPPDATA = $script:OrigLocalAppData
}

Describe 'Get-SuiteInstallInfo' {
    It 'finds the manifest in the folder or one level up' {
        $root = Join-Path $TestDrive 'suite-root'
        New-Item -ItemType Directory -Path (Join-Path $root 'app-packager') -Force | Out-Null
        '{ "suite": "AppPackager Suite", "version": "2026.10.11.0051" }' | Set-Content -LiteralPath (Join-Path $root 'suite-manifest.json') -Encoding ASCII
        $info = Get-SuiteInstallInfo -Path (Join-Path $root 'app-packager')
        $info.Installed | Should -BeTrue
        $info.Version | Should -Be '2026.10.11.0051'
        $info.Root | Should -Be $root
        (Get-SuiteInstallInfo -Path $root).Installed | Should -BeTrue
    }

    It 'reports a plain checkout as not installed' {
        $dir = Join-Path $TestDrive 'checkout\tool'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        (Get-SuiteInstallInfo -Path $dir).Installed | Should -BeFalse
    }
}

Describe 'Version helpers' {
    It 'reads the suite version from a release tag' {
        ConvertFrom-SuiteReleaseTag 'v2026.10.11.0051' | Should -Be '2026.10.11.0051'
        ConvertFrom-SuiteReleaseTag '2026.10.11.0051' | Should -Be '2026.10.11.0051'
        ConvertFrom-SuiteReleaseTag 'v1.2.3' | Should -Be ''
        ConvertFrom-SuiteReleaseTag '' | Should -Be ''
    }

    It 'compares build numbers with and without zero padding' {
        Compare-SuiteVersion '2026.10.11.0050' '2026.10.11.0051' | Should -Be -1
        Compare-SuiteVersion '2026.10.11.0051' '2026.10.11.0051' | Should -Be 0
        Compare-SuiteVersion '2026.10.11.51' '2026.10.11.0051' | Should -Be 0
        Compare-SuiteVersion '2026.10.12.0001' '2026.10.11.0099' | Should -Be 1
        Compare-SuiteVersion '' '2026.10.11.0051' | Should -Be -1
    }

    It 'treats a missing or old check as due' {
        Test-SuiteUpdateDue -LastCheckUtc '' | Should -BeTrue
        Test-SuiteUpdateDue -LastCheckUtc 'not a date' | Should -BeTrue
        Test-SuiteUpdateDue -LastCheckUtc ((Get-Date).ToUniversalTime().AddHours(-25).ToString('o')) | Should -BeTrue
        Test-SuiteUpdateDue -LastCheckUtc ((Get-Date).ToUniversalTime().AddHours(-1).ToString('o')) | Should -BeFalse
    }
}

Describe 'Get-SuiteUpdateState' {
    BeforeEach {
        $cache = Get-SuiteUpdateCachePath
        if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force }
        $script:Lookups = 0
        Mock -ModuleName SuiteCommon Get-SuiteLatestRelease {
            $script:Lookups++
            [pscustomobject]@{ Tag = 'v2026.10.11.0051'; Version = '2026.10.11.0051'; Url = 'https://github.com/jasonulbright/app-packager-suite/releases/tag/v2026.10.11.0051' }
        }
    }

    It 'looks the release up, caches it, and reports an update' {
        $s = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0050'
        $s.Available | Should -BeTrue
        $s.Latest | Should -Be '2026.10.11.0051'
        $s.Checked | Should -BeTrue
        $s.ReleaseUrl | Should -Match 'v2026\.10\.11\.0051$'
        $script:Lookups | Should -Be 1
        (Read-SuiteUpdateCache).LatestVersion | Should -Be '2026.10.11.0051'
    }

    It 'serves the second call from the cache' {
        $null = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0050'
        $s = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0051'
        $s.Checked | Should -BeFalse
        $s.Available | Should -BeFalse
        $script:Lookups | Should -Be 1
    }

    It 'looks up again with -Force' {
        $null = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0050'
        $null = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0050' -Force
        $script:Lookups | Should -Be 2
    }

    It 'keeps the cached answer and reports the error when the lookup fails' {
        $null = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0050'
        Mock -ModuleName SuiteCommon Get-SuiteLatestRelease { throw 'Download failed (curl exit 7)' }
        $s = Get-SuiteUpdateState -InstalledVersion '2026.10.11.0050' -Force
        $s.Error | Should -Match 'curl exit 7'
        $s.Latest | Should -Be '2026.10.11.0051'
        $s.Available | Should -BeTrue
        $s.Checked | Should -BeFalse
    }

    It 'does not report an update without an installed version' {
        $s = Get-SuiteUpdateState -InstalledVersion ''
        $s.Latest | Should -Be '2026.10.11.0051'
        $s.Available | Should -BeFalse
    }
}

Describe 'Get-SuiteUpdateDownload' {
    BeforeEach {
        $script:Folder = Join-Path $TestDrive ('dl-' + [guid]::NewGuid().ToString('N'))
        $script:Payload = 'installer bytes ' + [guid]::NewGuid().ToString('N')
        $script:Subject = 'CN=Jason Ulbright, O=Jason Ulbright, L=Apex, S=nc, C=US'
        $script:SigStatus = 'Valid'
        Mock -ModuleName SuiteCommon Invoke-SuiteHttpGet {
            param($Url, $OutFile, $TimeoutSeconds)
            if ($Url -like '*/checksums.txt') {
                $exe = Join-Path (Split-Path -Parent $OutFile) 'SuiteSetup-2026.10.11.0051.exe'
                $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($script:BadHash) { $hash = ('0' * 64) }
                Set-Content -LiteralPath $OutFile -Value ($hash + '  SuiteSetup-2026.10.11.0051.exe') -Encoding ASCII
                return $OutFile
            }
            Set-Content -LiteralPath $OutFile -Value $script:Payload -Encoding ASCII
            return $OutFile
        }
        Mock -ModuleName SuiteCommon Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = $script:SigStatus; SignerCertificate = [pscustomobject]@{ Subject = $script:Subject } }
        }
        $script:BadHash = $false
    }

    It 'returns the installer when the hash and the signer match' {
        $exe = Get-SuiteUpdateDownload -Version '2026.10.11.0051' -Folder $script:Folder
        $exe | Should -Be (Join-Path $script:Folder 'SuiteSetup-2026.10.11.0051.exe')
        Test-Path -LiteralPath $exe | Should -BeTrue
        Should -Invoke -ModuleName SuiteCommon Invoke-SuiteHttpGet -Times 2 -Exactly
    }

    It 'asks the release asset host for the versioned installer' {
        $script:Urls = @()
        Mock -ModuleName SuiteCommon Invoke-SuiteHttpGet {
            param($Url, $OutFile, $TimeoutSeconds)
            $script:Urls += $Url
            if ($Url -like '*/checksums.txt') {
                $exe = Join-Path (Split-Path -Parent $OutFile) 'SuiteSetup-2026.10.11.0051.exe'
                $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
                Set-Content -LiteralPath $OutFile -Value ($hash + '  SuiteSetup-2026.10.11.0051.exe') -Encoding ASCII
                return $OutFile
            }
            Set-Content -LiteralPath $OutFile -Value 'x' -Encoding ASCII
            return $OutFile
        }
        $null = Get-SuiteUpdateDownload -Version '2026.10.11.0051' -Folder $script:Folder
        $script:Urls[0] | Should -Be 'https://github.com/jasonulbright/app-packager-suite/releases/download/v2026.10.11.0051/SuiteSetup-2026.10.11.0051.exe'
        $script:Urls[1] | Should -Be 'https://github.com/jasonulbright/app-packager-suite/releases/download/v2026.10.11.0051/checksums.txt'
    }

    It 'rejects a hash mismatch and deletes the file' {
        $script:BadHash = $true
        { Get-SuiteUpdateDownload -Version '2026.10.11.0051' -Folder $script:Folder } | Should -Throw '*SHA256 mismatch*'
        Test-Path -LiteralPath (Join-Path $script:Folder 'SuiteSetup-2026.10.11.0051.exe') | Should -BeFalse
    }

    It 'rejects an invalid signature' {
        $script:SigStatus = 'NotSigned'
        { Get-SuiteUpdateDownload -Version '2026.10.11.0051' -Folder $script:Folder } | Should -Throw '*NotSigned*'
        Test-Path -LiteralPath (Join-Path $script:Folder 'SuiteSetup-2026.10.11.0051.exe') | Should -BeFalse
    }

    It 'rejects another signer' {
        $script:Subject = 'CN=Someone Else, O=Someone Else, C=US'
        { Get-SuiteUpdateDownload -Version '2026.10.11.0051' -Folder $script:Folder } | Should -Throw '*Signer of*'
    }
}

Describe 'Start-SuiteUpdateInstaller' {
    It 'writes a bootstrap that waits, runs the setup silently, and relaunches' {
        $exe = Join-Path $TestDrive "Suite Setup's.exe"
        Set-Content -LiteralPath $exe -Value 'x' -Encoding ASCII
        Mock -ModuleName SuiteCommon Start-Process { param($FilePath, $ArgumentList) $script:Started = @($ArgumentList) }
        $bootstrap = Start-SuiteUpdateInstaller -InstallerPath $exe -WaitForProcessId 4242 -Relaunch 'C:\Tools\suite\start-suite.ps1'
        Test-Path -LiteralPath $bootstrap | Should -BeTrue
        $text = Get-Content -LiteralPath $bootstrap -Raw
        $text | Should -Match 'Wait-Process -Id 4242 -Timeout 120'
        $text | Should -Match "Start-Process -FilePath 'C:\\.*Suite Setup''s\.exe' -ArgumentList '/S' -PassThru -Wait"
        $text | Should -Match "if \(\`$p\.ExitCode -eq 0\) \{ Start-Process -FilePath 'powershell\.exe' .*start-suite\.ps1"
        $script:Started | Should -Contain ('"' + $bootstrap + '"')
        $script:Started | Should -Contain 'Hidden'
        Remove-Item -LiteralPath $bootstrap -Force -ErrorAction SilentlyContinue
    }

    It 'refuses a missing installer' {
        { Start-SuiteUpdateInstaller -InstallerPath (Join-Path $TestDrive 'missing.exe') } | Should -Throw '*not found*'
    }
}


Describe 'ConvertTo-SuiteNativeArgument' {
    BeforeAll {
        Add-Type -Namespace SuiteTest -Name Shell32 -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
public static extern System.IntPtr CommandLineToArgvW([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string commandLine, out int argc);
[DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr mem);
'@

        # Splits a command line the way a native program's startup code does.
        function Split-CommandLine {
            param([string]$CommandLine)
            $count = 0
            $ptr = [SuiteTest.Shell32]::CommandLineToArgvW($CommandLine, [ref]$count)
            try {
                $result = @()
                for ($i = 0; $i -lt $count; $i++) {
                    $result += [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size))
                }
                return , $result
            }
            finally { [void][SuiteTest.Shell32]::LocalFree($ptr) }
        }
    }

    It 'survives the native command-line split for <Name>' -ForEach @(
        @{ Name = 'a plain path';              Value = 'C:\Tools\start-suite.ps1' }
        @{ Name = 'a path with spaces';        Value = 'C:\Program Files\App Packager Suite\start-suite.ps1' }
        @{ Name = 'a trailing backslash';      Value = 'C:\Users\Some One\Temp\' }
        @{ Name = 'a doubled trailing slash';  Value = 'C:\Some One\Temp\\' }
        @{ Name = 'a quote after backslashes'; Value = 'C:\a b\"c\\"d' }
        @{ Name = 'an apostrophe';             Value = "C:\Jason's Tools\x.ps1" }
        @{ Name = 'an empty string';           Value = '' }
    ) {
        $quoted = InModuleScope SuiteCommon -Parameters @{ V = $Value } { ConvertTo-SuiteNativeArgument -Value $V }
        $parsed = Split-CommandLine -CommandLine ('prog.exe -File ' + $quoted + ' tail')
        $parsed.Count | Should -Be 4
        $parsed[2] | Should -Be $Value
        $parsed[3] | Should -Be 'tail'
    }
}

Describe 'Start-SuiteUpdateInstaller with a real child process' {
    BeforeAll {
        $script:OrigTmp = $env:TMP
        $script:OrigTemp = $env:TEMP
        $script:Spaced = Join-Path $TestDrive 'spaced temp dir'
        $script:RelaunchDir = Join-Path $TestDrive 'relaunch dir'
        $script:InstallerDir = Join-Path $TestDrive 'fake installer'
        New-Item -ItemType Directory -Path $script:Spaced, $script:RelaunchDir, $script:InstallerDir -Force | Out-Null

        $script:SetupMarker = Join-Path $script:InstallerDir 'setup-args.txt'
        $script:RelaunchMarker = Join-Path $script:RelaunchDir 'relaunch-argv.txt'
        $script:FakeSetup = Join-Path $script:InstallerDir 'SuiteSetup-fake.cmd'
        Set-Content -LiteralPath $script:FakeSetup -Value ('@echo off' + "`r`n" + 'echo %* > "' + $script:SetupMarker + '"' + "`r`n" + 'exit /b 0') -Encoding ASCII
        $script:Relaunch = Join-Path $script:RelaunchDir 'start-suite.ps1'
        Set-Content -LiteralPath $script:Relaunch -Encoding ASCII -Value @(
            '$lines = [Environment]::GetCommandLineArgs()'
            ('Set-Content -LiteralPath ''' + $script:RelaunchMarker + ''' -Value $lines -Encoding ASCII')
        )

        # A process id that has already exited, so the bootstrap's wait ends at once.
        $done = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 0' -PassThru -WindowStyle Hidden
        $done.WaitForExit()
        $script:GonePid = $done.Id

        $env:TMP = $script:Spaced
        $env:TEMP = $script:Spaced
        try { $script:Bootstrap = Start-SuiteUpdateInstaller -InstallerPath $script:FakeSetup -WaitForProcessId $script:GonePid -Relaunch $script:Relaunch }
        finally { $env:TMP = $script:OrigTmp; $env:TEMP = $script:OrigTemp }

        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $script:RelaunchMarker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    }

    AfterAll {
        $env:TMP = $script:OrigTmp
        $env:TEMP = $script:OrigTemp
        if ($script:Bootstrap) { Remove-Item -LiteralPath $script:Bootstrap -Force -ErrorAction SilentlyContinue }
    }

    It 'writes the bootstrap into the spaced temp folder' {
        $script:Bootstrap | Should -BeLike ($script:Spaced + '\*')
    }

    It 'runs the bootstrap that was started from a spaced path' {
        Test-Path -LiteralPath $script:SetupMarker | Should -BeTrue
        (Get-Content -LiteralPath $script:SetupMarker -Raw).Trim() | Should -Be '/S'
    }

    It 'relaunches the script from a spaced folder as one argument' {
        Test-Path -LiteralPath $script:RelaunchMarker | Should -BeTrue
        $argv = @(Get-Content -LiteralPath $script:RelaunchMarker)
        $argv | Should -Contain $script:Relaunch
        $argv | Should -Contain '-File'
    }
}
