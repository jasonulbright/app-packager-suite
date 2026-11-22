#Requires -Modules Pester

<#
.SYNOPSIS
    Guard for the launcher footer: the footer shows the status text and the
    Check for updates button, with a gap and an ellipsis; it shows no site code
    and no site server.

.DESCRIPTION
    start-suite.ps1 is a window script. The first tests read its XAML and its
    AST and create no window. The layout tests create the footer bar from the
    launcher XAML in a window that is shown off screen, so they run in an STA
    host only. The two boxes cmbSite and txtProvider stay in the launcher
    main window and are the place to edit the connection profile, so the footer
    does not repeat it.
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
        # Siblings and every other element in the footer bar count too.
        $bar = $el.ParentNode
        foreach ($d in $bar.SelectNodes('.//*')) {
            if ($d -eq $el) { continue }
            foreach ($a in $d.Attributes) {
                $n = $a.LocalName -replace '^.*\.', ''
                if ($script:FontAttr -contains $n) { $found += ('{0}.{1}' -f $d.LocalName, $a.LocalName) }
            }
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
        $sib = New-Object System.Xml.XmlDocument
        $sib.LoadXml('<Border><DockPanel><Button FontSize="11"/><TextBlock x:Name="txtStatus" xmlns:x="u"/></DockPanel></Border>')
        (Get-FooterFontViolation -Xml $sib).Count | Should -BeGreaterThan 0
    }

    It 'takes every font value of the status text from the shared footer style' {
        $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-SuiteFooterStyle' }, $true).Count | Should -BeGreaterThan 0
        $hits = @($script:Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -match '(?i)txtStatus\.(FontFamily|FontSize|FontWeight|FontStyle|TextDecorations)'
                }, $true))
        $hits.Count | Should -BeGreaterOrEqual 4
        foreach ($h in $hits) { $h.Right.Extent.Text | Should -Match 'footerStyle' -Because $h.Extent.Text }
    }

    It 'shows no site code and no site server in the footer' {
        $calls = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -in 'Initialize-SuiteFooter', 'Update-SuiteFooter', 'Format-SuiteFooterSite'
            }, $true)
        @($calls).Count | Should -Be 0
        $script:Text | Should -Not -Match 'txtFooterSite'
    }

    It 'keeps the status text and the Check for updates button in the footer, with a 12 pixel gap and an ellipsis' {
        $xml = Get-LauncherXaml -Text $script:Text
        $status = $xml.SelectSingleNode("//*[@*[local-name()='Name' and .='txtStatus']]")
        $status.GetAttribute('Text') | Should -Be 'Ready.'
        $status.GetAttribute('TextTrimming') | Should -Be 'CharacterEllipsis'
        $button = $xml.SelectSingleNode("//*[@*[local-name()='Name' and .='btnCheckUpdates']]")
        $button.GetAttribute('Content') | Should -Be 'Check for updates'
        $button.GetAttribute('DockPanel.Dock') | Should -Be 'Right'
        [double](($button.GetAttribute('Margin') -split ',')[0]) | Should -BeGreaterOrEqual 12
        $button.ParentNode | Should -Be $status.ParentNode
    }

    It 'sets the status text and its tooltip in one place' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-SuiteStatus' }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty
        $fn.Body.Extent.Text | Should -Match '\$txtStatus\.Text\s*=\s*\$Text'
        $fn.Body.Extent.Text | Should -Match '\$txtStatus\.ToolTip\s*=\s*\$Text'
    }
}

Describe 'Launcher footer layout (real controls from the launcher XAML, STA only)' -Skip:([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {

    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $script:Wpf = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        $script:WpfX = 'http://schemas.microsoft.com/winfx/2006/xaml'

        # The footer bar of the launcher XAML, without the MahApps attributes that need the library.
        function New-LauncherFooterBar {
            $xml = Get-LauncherXaml -Text $script:Text
            $status = $xml.SelectSingleNode("//*[@*[local-name()='Name' and .='txtStatus']]")
            $bar = $status.ParentNode.ParentNode.CloneNode($true)
            foreach ($n in @($bar.SelectNodes('descendant-or-self::*'))) {
                foreach ($a in @($n.Attributes)) {
                    if ($a.Prefix -eq 'Controls' -or $a.Name -eq 'Style') { [void]$n.Attributes.Remove($a) }
                }
            }
            $inner = $bar.InnerXml
            $attrs = (@($bar.Attributes | ForEach-Object { '{0}="{1}"' -f $_.Name, $_.Value }) -join ' ')
            $text = '<Border xmlns="{0}" xmlns:x="{1}" {2}>{3}</Border>' -f $script:Wpf, $script:WpfX, $attrs, $inner
            [System.Windows.Markup.XamlReader]::Parse($text)
        }
        function Get-FooterLeft($Element, $Ancestor) {
            $Element.TransformToAncestor($Ancestor).Transform([System.Windows.Point]::new(0, 0)).X
        }
        function Show-FooterBar([string]$StatusText, [double]$Width) {
            $bar = New-LauncherFooterBar
            $win = New-Object System.Windows.Window
            $win.Width = $Width; $win.Height = 120
            $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
            $win.Left = -4000; $win.Top = 0; $win.ShowInTaskbar = $false; $win.ShowActivated = $false
            $win.Content = $bar
            $win.Show()
            $status = $bar.FindName('txtStatus')
            $status.Text = $StatusText
            for ($i = 0; $i -lt 3; $i++) { $win.UpdateLayout(); $win.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) }
            [pscustomobject]@{ Window = $win; Bar = $bar; Dock = $bar.Child; Status = $status; Button = $bar.FindName('btnCheckUpdates') }
        }
    }

    It 'leaves at least 12 pixels between a short status text and the button' {
        $f = Show-FooterBar 'Ready.' 620
        try {
            $statusRight = (Get-FooterLeft $f.Status $f.Dock) + $f.Status.ActualWidth
            ((Get-FooterLeft $f.Button $f.Dock) - $statusRight) | Should -BeGreaterOrEqual 12
        }
        finally { $f.Window.Close() }
    }

    It 'shortens a long status text with an ellipsis at the minimum window width and never reaches the button' {
        $long = 'Connection profile saved; new launches inherit it. ' + ('C:\projects\app-packager-suite\a-very-long-folder-name\' * 3)
        $long.Length | Should -BeGreaterThan 100
        $f = Show-FooterBar $long 620
        try {
            $f.Status.TextTrimming | Should -Be ([System.Windows.TextTrimming]::CharacterEllipsis)
            $statusRight = (Get-FooterLeft $f.Status $f.Dock) + $f.Status.ActualWidth
            ((Get-FooterLeft $f.Button $f.Dock) - $statusRight) | Should -BeGreaterOrEqual 12
            $f.Status.ActualWidth | Should -BeGreaterThan 0
        }
        finally { $f.Window.Close() }
    }
}
