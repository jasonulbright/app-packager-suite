#Requires -Modules Pester

<#
.SYNOPSIS
    Guard for the launcher footer: the status text takes the shared footer
    style and the footer shows the saved site profile.

.DESCRIPTION
    start-suite.ps1 is a window script. This test reads its XAML and its AST
    and creates no window. The two boxes txtSiteCode and txtProvider stay in
    the launcher main window, which is an allowed place to edit them.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:LauncherPath = Join-Path $script:RepoRoot 'start-suite.ps1'
    $script:Text = [IO.File]::ReadAllText($script:LauncherPath)
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$null, [ref]$null)
    $script:FontAttr = @('FontFamily', 'FontSize', 'FontWeight', 'FontStyle', 'TextDecorations')

    function Get-LauncherXaml {
        param([string]$Text)
        $m = [regex]::Match($Text, '(?s)<Controls:MetroWindow\b.*?</Controls:MetroWindow>')
        if (-not $m.Success) { return $null }
        $xml = New-Object System.Xml.XmlDocument
        try { $xml.LoadXml($m.Value) } catch { return $null }
        $xml
    }

    function Get-FooterFontViolation {
        param([System.Xml.XmlDocument]$Xml, [string]$StatusName = 'txtStatus')
        $found = @()
        $el = $Xml.SelectSingleNode("//*[@*[local-name()='Name' and .='$StatusName']]")
        if (-not $el) { return , @('missing') }
        $node = $el
        while ($node -and $node.NodeType -eq 'Element') {
            foreach ($a in $node.Attributes) {
                $n = $a.LocalName -replace '^.*\.', ''
                if ($script:FontAttr -contains $n) { $found += ('{0}.{1}' -f $node.LocalName, $a.LocalName) }
            }
            $node = $node.ParentNode
        }
        , $found
    }
}

Describe 'Launcher footer' {
    It 'parses the launcher XAML and finds the status text (non-empty scan)' {
        $xml = Get-LauncherXaml -Text $script:Text
        $xml | Should -Not -BeNullOrEmpty
        $xml.SelectSingleNode("//*[@*[local-name()='Name' and .='txtStatus']]") | Should -Not -BeNullOrEmpty
    }

    It 'sets no font attribute on the status text or any ancestor' {
        $xml = Get-LauncherXaml -Text $script:Text
        $v = Get-FooterFontViolation -Xml $xml
        ($v -join ', ') | Should -BeNullOrEmpty
    }

    It 'flags a font attribute on the status text and on a grandparent (bad samples)' {
        $own = New-Object System.Xml.XmlDocument
        $own.LoadXml('<Border><DockPanel><TextBlock x:Name="txtStatus" xmlns:x="u" FontSize="11"/></DockPanel></Border>')
        (Get-FooterFontViolation -Xml $own).Count | Should -BeGreaterThan 0
        $up = New-Object System.Xml.XmlDocument
        $up.LoadXml('<Border FontFamily="Arial"><DockPanel><TextBlock x:Name="txtStatus" xmlns:x="u"/></DockPanel></Border>')
        (Get-FooterFontViolation -Xml $up).Count | Should -BeGreaterThan 0
    }

    It 'sets no font on the status text in code' {
        $hits = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -match '(?i)txtStatus\.(FontFamily|FontSize|FontWeight|FontStyle|TextDecorations)'
            }, $true)
        @($hits).Count | Should -Be 0
    }

    It 'wraps the footer calls in try/catch and calls the helper after load and after a profile save' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-SuiteFooter' }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty
        $tries = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
        @($tries).Count | Should -BeGreaterThan 0
        $tries[0].CatchClauses.Count | Should -BeGreaterThan 0
        $calls = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Initialize-SuiteFooter', 'Update-SuiteFooter' }, $true)
        foreach ($c in $calls) {
            $inside = $false
            foreach ($t in $tries) { if ($c.Extent.StartOffset -ge $t.Body.Extent.StartOffset -and $c.Extent.EndOffset -le $t.Body.Extent.EndOffset) { $inside = $true } }
            $inside | Should -BeTrue
        }
        $users = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Sync-SuiteFooter' }, $true)
        @($users).Count | Should -BeGreaterOrEqual 2
    }
}
