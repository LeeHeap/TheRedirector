#Requires -Version 5.1
<#
.SYNOPSIS
    TheRedirector - NTFS Junction Point Manager

.DESCRIPTION
    A GUI tool for managing NTFS junction points (symlinks) to redirect
    application settings folders to a synced location (e.g. OneDrive).

.NOTES
    Requires administrator privileges to create/remove junction points.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBALS
# ─────────────────────────────────────────────────────────────────────────────
$script:Version      = "1.1.0"
$script:ConfigPath   = Join-Path $PSScriptRoot "config.json"
$script:Redirects    = @()
$script:SelectedItem   = $null
$script:SelectedBorder = $null
$script:ListViewErrors = ""

# ─────────────────────────────────────────────────────────────────────────────
#  ADMIN ELEVATION  (must happen before any WPF window is shown)
# ─────────────────────────────────────────────────────────────────────────────
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$_isSTA   = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
$_isAdmin = Test-IsAdmin

if (-not $_isAdmin -or -not $_isSTA) {
    if (-not $_isAdmin) {
        # Show a plain Win32 message box (no WPF window yet)
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "TheRedirector needs administrator privileges to create and manage junction points.`n`nRestart as Administrator?",
            "Administrator Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    # Re-launch with -STA and -Verb RunAs; use full path to avoid ShellExecute FILE_NOT_FOUND
    # Use return (not exit) so the caller's terminal session stays alive
    $_ps  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $_arg = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath $_ps -Verb RunAs -ArgumentList $_arg
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not restart as Administrator:`n$_",
            "Elevation Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    return
}

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIG
# ─────────────────────────────────────────────────────────────────────────────
function Load-Config {
    $script:LoadError = $null
    $log = Join-Path $env:TEMP "TheRedirector_debug.log"
    "$(Get-Date -f 'HH:mm:ss') Load-Config start. ConfigPath=[$script:ConfigPath]" | Add-Content $log

    if (Test-Path $script:ConfigPath) {
        try {
            $json = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:Redirects = @($json.redirects | ForEach-Object {
                [PSCustomObject]@{
                    Name   = $_.name
                    Type   = if ($_.type) { $_.type } else { "Folder" }
                    Source = $_.source
                    Target = $_.target
                }
            })
            "$(Get-Date -f 'HH:mm:ss') Loaded $($script:Redirects.Count) redirect(s)." | Add-Content $log
        } catch {
            $script:Redirects = @()
            $script:LoadError = "Parse error: $_"
            "$(Get-Date -f 'HH:mm:ss') ERROR: $script:LoadError" | Add-Content $log
        }
    } else {
        $script:Redirects = @()
        $script:LoadError = "Config not found: $script:ConfigPath"
        "$(Get-Date -f 'HH:mm:ss') Config not found. Creating blank." | Add-Content $log
        try { Save-Config } catch {}
    }
}

function Save-Config {
    $obj = @{
        redirects = @($script:Redirects | ForEach-Object {
            [ordered]@{ name = $_.Name; type = $_.Type; source = $_.Source; target = $_.Target }
        })
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $script:ConfigPath -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
#  JUNCTION / STATUS HELPERS
# ─────────────────────────────────────────────────────────────────────────────
function Get-RedirectStatus {
    param([string]$Source, [string]$Target, [string]$Type = "Folder")

    $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if (-not $item) { return "Inactive" }

    if ($Type -eq "File") {
        # File redirect: check for symbolic link (not directory)
        if ($item.LinkType -eq "SymbolicLink" -and -not $item.PSIsContainer) {
            $lt = $item.Target
            if ($lt) { $lt = $lt[0] }
            try {
                $normLt  = [System.IO.Path]::GetFullPath($lt).TrimEnd('\')
                $normTgt = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
                if ($normLt -ieq $normTgt) {
                    return $(if (Test-Path -LiteralPath $Target) { "Active" } else { "Broken" })
                } else {
                    return "WrongTarget"
                }
            } catch { return "Broken" }
        } else {
            return "Unlinked"   # regular file, directory, or wrong link type
        }
    } else {
        # Folder redirect: check for junction (existing logic)
        if ($item.LinkType -eq "Junction") {
            $jt = $item.Target
            if ($jt) { $jt = $jt[0] }
            try {
                $normJt  = [System.IO.Path]::GetFullPath($jt).TrimEnd('\')
                $normTgt = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
                if ($normJt -ieq $normTgt) {
                    return $(if (Test-Path -LiteralPath $Target) { "Active" } else { "Broken" })
                } else {
                    return "WrongTarget"
                }
            } catch { return "Broken" }
        } else {
            return "Unlinked"   # regular folder, file, or wrong link type
        }
    }
}

function Get-StatusMeta {
    param([string]$Status)
    switch ($Status) {
        "Active"      { @{ Text = "Active";        Color = "#4ADE80"; BG = "#052e16" } }
        "Inactive"    { @{ Text = "Inactive";      Color = "#9CA3AF"; BG = "#1f2937" } }
        "Unlinked"    { @{ Text = "Not Linked";    Color = "#FBBF24"; BG = "#451a03" } }
        "Broken"      { @{ Text = "Broken Link";   Color = "#F87171"; BG = "#450a0a" } }
        "WrongTarget" { @{ Text = "Wrong Target";  Color = "#FB923C"; BG = "#431407" } }
        default       { @{ Text = $Status;         Color = "#9CA3AF"; BG = "#1f2937" } }
    }
}

function Enable-Redirect {
    param($Redirect)

    $source   = $Redirect.Source
    $target   = $Redirect.Target
    $isFile   = $Redirect.Type -eq "File"
    $typeWord = if ($isFile) { "file" } else { "folder" }
    $linkWord = if ($isFile) { "symbolic link" } else { "junction" }
    $status   = Get-RedirectStatus -Source $source -Target $target -Type $Redirect.Type

    switch ($status) {
        "Active" {
            [System.Windows.MessageBox]::Show(
                "This redirect is already active.", "Already Active",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information) | Out-Null
            return $false
        }
        "WrongTarget" {
            $item   = Get-Item -LiteralPath $source -Force
            $actual = if ($item.Target) { $item.Target[0] } else { "unknown" }
            [System.Windows.MessageBox]::Show(
                "A $linkWord already exists at the source but points elsewhere:`n  $actual`n`nPlease disable it first, or remove it manually.",
                "Cannot Enable", [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $false
        }
        "Broken" {
            [System.Windows.MessageBox]::Show(
                "A $linkWord exists at the source but the target $typeWord is missing:`n  $target`n`nPlease restore the target $typeWord or disable this redirect.",
                "Broken $linkWord", [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $false
        }
        "Unlinked" {
            $targetExists = Test-Path -LiteralPath $target

            if ($targetExists) {
                $ans = [System.Windows.MessageBox]::Show(
                    "The source $typeWord has existing data, and the target already exists too.`n`nSource: $source`nTarget: $target`n`nTo proceed, the source must be deleted (your data lives in the target).`n`nDelete the source $typeWord and create the $($linkWord)?",
                    "Data Conflict - Confirm",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning)

                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return $false }

                try {
                    if ($isFile) { Remove-Item -LiteralPath $source -Force }
                    else         { Remove-Item -LiteralPath $source -Recurse -Force }
                }
                catch {
                    [System.Windows.MessageBox]::Show("Could not delete source $($typeWord):`n$_", "Error",
                        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                    return $false
                }
            } else {
                $ans = [System.Windows.MessageBox]::Show(
                    "The source $typeWord contains data. What should happen to it?`n`nSource: $source`nTarget: $target`n`nYes    - Move data to the target location`nNo     - Delete source data (data will be lost!)`nCancel - Do nothing",
                    "Existing Data Found",
                    [System.Windows.MessageBoxButton]::YesNoCancel,
                    [System.Windows.MessageBoxImage]::Question)

                switch ($ans) {
                    ([System.Windows.MessageBoxResult]::Yes) {
                        try {
                            $parentDir = Split-Path -Parent $target
                            if ($parentDir -and -not (Test-Path $parentDir)) {
                                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                            }
                            Move-Item -LiteralPath $source -Destination $target -Force
                        } catch {
                            [System.Windows.MessageBox]::Show("Could not move data:`n$_", "Error",
                                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                            return $false
                        }
                    }
                    ([System.Windows.MessageBoxResult]::No) {
                        try {
                            if ($isFile) { Remove-Item -LiteralPath $source -Force }
                            else         { Remove-Item -LiteralPath $source -Recurse -Force }
                        }
                        catch {
                            [System.Windows.MessageBox]::Show("Could not delete source $($typeWord):`n$_", "Error",
                                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                            return $false
                        }
                    }
                    default { return $false }
                }
            }
        }
        "Inactive" {
            $targetExists = Test-Path -LiteralPath $target
            if (-not $targetExists) {
                $ans = [System.Windows.MessageBox]::Show(
                    "The target $typeWord doesn't exist yet:`n  $target`n`nCreate it and the $($linkWord)?",
                    "Target Missing",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question)
                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
                try {
                    if ($isFile) {
                        $parentDir = Split-Path -Parent $target
                        if ($parentDir -and -not (Test-Path $parentDir)) {
                            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                        }
                        New-Item -ItemType File -Path $target -Force | Out-Null
                    } else {
                        New-Item -ItemType Directory -Path $target -Force | Out-Null
                    }
                }
                catch {
                    [System.Windows.MessageBox]::Show("Could not create target $($typeWord):`n$_", "Error",
                        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                    return $false
                }
            }
        }
    }

    # --- Create the link ---
    try {
        $parentDir = Split-Path -Parent $source
        if ($parentDir -and -not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        if ($isFile) {
            New-Item -ItemType SymbolicLink -Path $source -Target $target | Out-Null
        } else {
            New-Item -ItemType Junction -Path $source -Target $target | Out-Null
        }
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Failed to create $($linkWord):`n$_", "Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return $false
    }
}

function Disable-Redirect {
    param($Redirect)

    $source   = $Redirect.Source
    $isFile   = $Redirect.Type -eq "File"
    $typeWord = if ($isFile) { "file" } else { "folder" }
    $linkWord = if ($isFile) { "symbolic link" } else { "junction" }
    $status   = Get-RedirectStatus -Source $source -Target $Redirect.Target -Type $Redirect.Type

    if ($status -eq "Inactive") {
        [System.Windows.MessageBox]::Show(
            "No $linkWord found at the source path. Nothing to disable.",
            "Not Active", [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return $false
    }
    if ($status -eq "Unlinked") {
        [System.Windows.MessageBox]::Show(
            "The source path is a regular $typeWord, not a $linkWord. Cannot disable.",
            "Not a Link", [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return $false
    }

    # Remove only the link, not the target contents
    try {
        if ($isFile) {
            [System.IO.File]::Delete($source)
        } else {
            [System.IO.Directory]::Delete($source, $false)
        }
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Failed to remove $($linkWord):`n$_", "Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN WINDOW XAML
# ─────────────────────────────────────────────────────────────────────────────
[xml]$MainXAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="TheRedirector"
    Width="960" Height="640"
    MinWidth="720" MinHeight="460"
    WindowStartupLocation="CenterScreen"
    Background="#0D0D0D"
    Foreground="#E5E5E5"
    FontFamily="Segoe UI">

    <Window.Resources>

        <!-- ── Scrollbar ── -->
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="6"/>
            <Setter Property="Background" Value="Transparent"/>
        </Style>

        <!-- ── Primary Button ── -->
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1488DB"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#005BA4"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── Secondary Button ── -->
        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#252525"/>
            <Setter Property="Foreground" Value="#D0D0D0"/>
            <Setter Property="BorderBrush" Value="#383838"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#303030"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1A1A1A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── Danger Button ── -->
        <Style x:Key="BtnDanger" TargetType="Button">
            <Setter Property="Background" Value="#6B1A1A"/>
            <Setter Property="Foreground" Value="#FCA5A5"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#8B2222"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#550F0F"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>


    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="68"/>
            <RowDefinition Height="54"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="34"/>
        </Grid.RowDefinitions>

        <!-- ══════════════ HEADER ══════════════ -->
        <Border Grid.Row="0">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#004E8C" Offset="0"/>
                    <GradientStop Color="#0078D4" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Grid Margin="22,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⇌" FontSize="30" Foreground="White"
                               VerticalAlignment="Center" Margin="0,0,14,2"/>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="TheRedirector" FontSize="20"
                                   Foreground="White" FontWeight="SemiBold"/>
                        <TextBlock Text="NTFS Junction &amp; Symlink Manager"
                                   FontSize="11" Foreground="#A8D4F5" Margin="1,2,0,0"/>
                    </StackPanel>
                </StackPanel>
                <Border Grid.Column="1" VerticalAlignment="Center"
                        Background="#00000040" CornerRadius="4" Padding="10,4">
                    <TextBlock x:Name="tbAdminBadge" Text="⚡ Running as Administrator"
                               FontSize="11" Foreground="#A8D4F5"/>
                </Border>
            </Grid>
        </Border>

        <!-- ══════════════ TOOLBAR ══════════════ -->
        <Border Grid.Row="1" Background="#161616" BorderBrush="#222222" BorderThickness="0,0,0,1">
            <Grid Margin="18,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" >
                    <Button x:Name="btnAddFolder" Content="＋  Add Folder"  Style="{StaticResource BtnPrimary}"   Margin="0,0,8,0"/>
                    <Button x:Name="btnAddFile"   Content="＋  Add File"    Style="{StaticResource BtnPrimary}"   Margin="0,0,8,0"/>
                    <Button x:Name="btnEdit"    Content="✎  Edit"           Style="{StaticResource BtnSecondary}" Margin="0,0,8,0" IsEnabled="False"/>
                    <Button x:Name="btnRemove"  Content="✕  Remove"         Style="{StaticResource BtnDanger}"    Margin="0,0,20,0" IsEnabled="False"/>
                    <Rectangle Width="1" Height="22" Fill="#333333" Margin="0,0,20,0"/>
                    <Button x:Name="btnEnable"  Content="▶  Enable"         Style="{StaticResource BtnPrimary}"   Margin="0,0,8,0" IsEnabled="False"/>
                    <Button x:Name="btnDisable" Content="⏹  Disable"        Style="{StaticResource BtnSecondary}" IsEnabled="False"/>
                </StackPanel>
                <Button x:Name="btnRefresh" Grid.Column="1" Content="⟳  Refresh"
                        Style="{StaticResource BtnSecondary}" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- ══════════════ CONTENT ══════════════ -->
        <Grid Grid.Row="2">

            <!-- Empty state -->
            <StackPanel x:Name="emptyState" VerticalAlignment="Center"
                        HorizontalAlignment="Center" Visibility="Collapsed">
                <TextBlock Text="⇌" FontSize="56" HorizontalAlignment="Center"
                           Foreground="#2A2A2A" Margin="0,0,0,16"/>
                <TextBlock Text="No redirects configured yet"
                           FontSize="16" Foreground="#555555"
                           HorizontalAlignment="Center" Margin="0,0,0,6"/>
                <TextBlock Text="Click '＋ Add Folder' or '＋ Add File' in the toolbar to get started."
                           FontSize="12" Foreground="#3D3D3D" HorizontalAlignment="Center"/>
            </StackPanel>

            <!-- Redirect list -->
            <ScrollViewer x:Name="svMain" VerticalScrollBarVisibility="Auto"
                          HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="spCards" Margin="16,14,16,14"/>
            </ScrollViewer>
        </Grid>

        <!-- ══════════════ STATUS BAR ══════════════ -->
        <Border Grid.Row="3" Background="#111111" BorderBrush="#1E1E1E" BorderThickness="0,1,0,0">
            <Grid Margin="18,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="tbStatus" Grid.Column="0"
                           Text="Ready" Foreground="#6B7280"
                           FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="tbCount" Grid.Column="1"
                           Text="0 redirects" Foreground="#4B5563"
                           FontSize="12" VerticalAlignment="Center"/>
            </Grid>
        </Border>

    </Grid>
</Window>
'@

# ─────────────────────────────────────────────────────────────────────────────
#  EDIT / ADD DIALOG XAML
# ─────────────────────────────────────────────────────────────────────────────
[xml]$EditXAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Add Redirect"
    Width="580" Height="310"
    MinWidth="480" MinHeight="280"
    WindowStartupLocation="CenterOwner"
    ResizeMode="CanResizeWithGrip"
    Background="#181818"
    Foreground="#E5E5E5"
    FontFamily="Segoe UI">
    <Window.Resources>

        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#9CA3AF"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="0,0,0,4"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#252525"/>
            <Setter Property="Foreground" Value="#E5E5E5"/>
            <Setter Property="BorderBrush" Value="#383838"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="#E5E5E5"/>
            <Setter Property="SelectionBrush" Value="#0078D4"/>
        </Style>

        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="22,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1488DB"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#252525"/>
            <Setter Property="Foreground" Value="#D0D0D0"/>
            <Setter Property="BorderBrush" Value="#383838"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="20,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#303030"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnBrowse" TargetType="Button">
            <Setter Property="Background" Value="#2E2E2E"/>
            <Setter Property="Foreground" Value="#B0B0B0"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#3C3C3C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

    </Window.Resources>

    <Grid Margin="26">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="14"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="14"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Name -->
        <StackPanel Grid.Row="0">
            <Label Content="Display Name"/>
            <TextBox x:Name="txtName"/>
        </StackPanel>

        <!-- Source -->
        <StackPanel Grid.Row="2">
            <Label Content="Source Path  (where the application looks for its data)"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="txtSource" Grid.Column="0"/>
                <Button x:Name="btnBrowseSource" Grid.Column="2" Content="Browse…"
                        Style="{StaticResource BtnBrowse}" VerticalAlignment="Stretch"/>
            </Grid>
        </StackPanel>

        <!-- Target -->
        <StackPanel Grid.Row="4">
            <Label Content="Target Path  (where the data actually lives, e.g. OneDrive folder)"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="txtTarget" Grid.Column="0"/>
                <Button x:Name="btnBrowseTarget" Grid.Column="2" Content="Browse…"
                        Style="{StaticResource BtnBrowse}" VerticalAlignment="Stretch"/>
            </Grid>
        </StackPanel>

        <!-- Buttons -->
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnCancel" Content="Cancel"
                    Style="{StaticResource BtnSecondary}" Margin="0,0,10,0"/>
            <Button x:Name="btnSave"   Content="Save"
                    Style="{StaticResource BtnPrimary}"/>
        </StackPanel>
    </Grid>
</Window>
'@

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD MAIN WINDOW
# ─────────────────────────────────────────────────────────────────────────────
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$MainXAML.OuterXml)
$script:Window = [System.Windows.Markup.XamlReader]::Load($reader)

$script:btnAddFolder = $script:Window.FindName('btnAddFolder')
$script:btnAddFile   = $script:Window.FindName('btnAddFile')
$script:btnEdit    = $script:Window.FindName('btnEdit')
$script:btnRemove  = $script:Window.FindName('btnRemove')
$script:btnEnable  = $script:Window.FindName('btnEnable')
$script:btnDisable = $script:Window.FindName('btnDisable')
$script:btnRefresh = $script:Window.FindName('btnRefresh')
$script:svMain     = $script:Window.FindName('svMain')
$script:spCards    = $script:Window.FindName('spCards')
$script:tbStatus   = $script:Window.FindName('tbStatus')
$script:tbCount    = $script:Window.FindName('tbCount')
$script:emptyState = $script:Window.FindName('emptyState')

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────
$script:BrushCache = @{}
function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $script:BrushCache[$Hex] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    }
    return $script:BrushCache[$Hex]
}

function Set-Status {
    param([string]$Msg, [string]$Color = "#6B7280")
    $script:tbStatus.Text       = $Msg
    $script:tbStatus.Foreground = Get-Brush $Color
}

function Update-ButtonStates {
    $sel = $script:SelectedItem
    $hasSelection = $null -ne $sel

    $script:btnEdit.IsEnabled   = $hasSelection
    $script:btnRemove.IsEnabled = $hasSelection

    if ($hasSelection) {
        $s = $sel.Status
        $script:btnEnable.IsEnabled  = ($s -ne "Active")
        $script:btnDisable.IsEnabled = ($s -eq "Active" -or $s -eq "Broken" -or $s -eq "WrongTarget")
    } else {
        $script:btnEnable.IsEnabled  = $false
        $script:btnDisable.IsEnabled = $false
    }
}

function New-RedirectCard {
    param($Item)   # PSCustomObject with Status, StatusText, StatusColor, StatusBG, Name, Source, Target, Redirect

    $meta = Get-StatusMeta -Status $Item.Status

    # Outer card border
    $card = New-Object System.Windows.Controls.Border
    $card.Background     = Get-Brush "#1C1C1C"
    $card.CornerRadius   = [System.Windows.CornerRadius]::new(7)
    $card.Margin         = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $card.Padding        = [System.Windows.Thickness]::new(18, 14, 18, 14)
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.BorderBrush    = Get-Brush "#282828"
    $card.Cursor         = [System.Windows.Input.Cursors]::Hand
    $card.Tag            = $Item

    # Hover effects
    $card.Add_MouseEnter({
        $s = $args[0]
        if ($s -ne $script:SelectedBorder) {
            $s.Background = Get-Brush "#222222"
        }
    })
    $card.Add_MouseLeave({
        $s = $args[0]
        if ($s -ne $script:SelectedBorder) {
            $s.Background   = Get-Brush "#1C1C1C"
            $s.BorderBrush  = Get-Brush "#282828"
        }
    })

    # Click to select
    $card.Add_MouseLeftButtonDown({
        $s = $args[0]
        if ($script:SelectedBorder -and $script:SelectedBorder -ne $s) {
            $script:SelectedBorder.Background      = Get-Brush "#1C1C1C"
            $script:SelectedBorder.BorderBrush     = Get-Brush "#282828"
            $script:SelectedBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        }
        $s.Background      = Get-Brush "#1A2E45"
        $s.BorderBrush     = Get-Brush "#0078D4"
        $s.BorderThickness = [System.Windows.Thickness]::new(1)
        $script:SelectedBorder = $s
        $script:SelectedItem   = $s.Tag
        Update-ButtonStates
    })

    # Main grid: left info | right badge
    $grid = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c0)
    $grid.ColumnDefinitions.Add($c1)

    # ── Left: name + paths ──
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = [System.Windows.Controls.Orientation]::Vertical

    # Status dot + name on one line
    $nameRow = New-Object System.Windows.Controls.StackPanel
    $nameRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $nameRow.Margin = [System.Windows.Thickness]::new(0,0,0,6)

    $dot = New-Object System.Windows.Controls.Border
    $dot.Width  = 8; $dot.Height = 8
    $dot.CornerRadius  = [System.Windows.CornerRadius]::new(4)
    $dot.Background    = Get-Brush $meta.Color
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $dot.Margin = [System.Windows.Thickness]::new(0,0,10,0)
    [void]$nameRow.Children.Add($dot)

    $nameTb = New-Object System.Windows.Controls.TextBlock
    $nameTb.Text       = $Item.Name
    $nameTb.FontSize   = 14
    $nameTb.FontWeight = [System.Windows.FontWeights]::SemiBold
    $nameTb.Foreground = Get-Brush "#EFEFEF"
    $nameTb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$nameRow.Children.Add($nameTb)
    [void]$left.Children.Add($nameRow)

    # Source path row (two TextBlocks in a horizontal StackPanel - avoids the Inlines/Run API)
    $srcRow = New-Object System.Windows.Controls.StackPanel
    $srcRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $srcRow.Margin = [System.Windows.Thickness]::new(18, 0, 0, 2)
    $srcLabel = New-Object System.Windows.Controls.TextBlock
    $srcLabel.Text = "Source  "; $srcLabel.FontSize = 11; $srcLabel.Foreground = Get-Brush "#4B5563"
    $srcValue = New-Object System.Windows.Controls.TextBlock
    $srcValue.Text = $Item.Source; $srcValue.FontSize = 11; $srcValue.Foreground = Get-Brush "#6B7280"
    $srcValue.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    [void]$srcRow.Children.Add($srcLabel); [void]$srcRow.Children.Add($srcValue)
    [void]$left.Children.Add($srcRow)

    # Target path row
    $tgtRow = New-Object System.Windows.Controls.StackPanel
    $tgtRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $tgtRow.Margin = [System.Windows.Thickness]::new(18, 0, 0, 0)
    $tgtLabel = New-Object System.Windows.Controls.TextBlock
    $tgtLabel.Text = "Target  "; $tgtLabel.FontSize = 11; $tgtLabel.Foreground = Get-Brush "#4B5563"
    $tgtValue = New-Object System.Windows.Controls.TextBlock
    $tgtValue.Text = $Item.Target; $tgtValue.FontSize = 11; $tgtValue.Foreground = Get-Brush "#6B7280"
    $tgtValue.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    [void]$tgtRow.Children.Add($tgtLabel); [void]$tgtRow.Children.Add($tgtValue)
    [void]$left.Children.Add($tgtRow)

    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    # ── Right: status badge ──
    $badge = New-Object System.Windows.Controls.Border
    $badge.Background       = Get-Brush $meta.BG
    $badge.CornerRadius     = [System.Windows.CornerRadius]::new(20)
    $badge.Padding          = [System.Windows.Thickness]::new(14, 5, 14, 5)
    $badge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $badge.Margin           = [System.Windows.Thickness]::new(16, 0, 0, 0)
    $badgeTb = New-Object System.Windows.Controls.TextBlock
    $badgeTb.Text       = $meta.Text
    $badgeTb.Foreground = Get-Brush $meta.Color
    $badgeTb.FontSize   = 11
    $badgeTb.FontWeight = [System.Windows.FontWeights]::SemiBold
    $badge.Child = $badgeTb

    [System.Windows.Controls.Grid]::SetColumn($badge, 1)
    [void]$grid.Children.Add($badge)

    $card.Child = $grid
    return $card
}

function Update-ListView {
    $script:spCards.Children.Clear()
    $script:SelectedItem   = $null
    $script:SelectedBorder = $null

    if ($script:Redirects.Count -eq 0) {
        $script:emptyState.Visibility = [System.Windows.Visibility]::Visible
        $script:svMain.Visibility     = [System.Windows.Visibility]::Collapsed
        $script:tbCount.Text          = "0 redirects"
    } else {
        $script:emptyState.Visibility = [System.Windows.Visibility]::Collapsed
        $script:svMain.Visibility     = [System.Windows.Visibility]::Visible

        $active = 0
        foreach ($r in $script:Redirects) {
            try {
                $status = Get-RedirectStatus -Source $r.Source -Target $r.Target -Type $r.Type
                if ($status -eq "Active") { $active++ }
                $meta = Get-StatusMeta -Status $status

                $itemData = [PSCustomObject]@{
                    Name        = $r.Name
                    Source      = $r.Source
                    Target      = $r.Target
                    Status      = $status
                    StatusText  = $meta.Text
                    StatusColor = $meta.Color
                    StatusBG    = $meta.BG
                    Redirect    = $r
                }

                $card = New-RedirectCard -Item $itemData
                [void]$script:spCards.Children.Add($card)
            } catch {
                $script:ListViewErrors += "[$($r.Name)] $_`n"
                "$(Get-Date -f 'HH:mm:ss') Card error [$($r.Name)]: $_" | Add-Content (Join-Path $env:TEMP "TheRedirector_debug.log")
            }
        }

        $total = $script:Redirects.Count
        $script:tbCount.Text = "$active / $total active"
    }

    Update-ButtonStates
}

# ─────────────────────────────────────────────────────────────────────────────
#  EDIT / ADD DIALOG
# ─────────────────────────────────────────────────────────────────────────────
function Show-EditDialog {
    param(
        [PSCustomObject]$Existing = $null,   # $null = Add mode
        [string]$Type = "Folder"             # "File" or "Folder"
    )

    $dlgReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$EditXAML.OuterXml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $script:Window
    $effectiveType = if ($Existing) { $Existing.Type } else { $Type }
    $dlg.Title = if ($Existing) { "Edit $effectiveType Redirect - $($Existing.Name)" } else { "Add $effectiveType Redirect" }

    # Add a read-only type label at the top of the dialog
    $dlgGrid = $dlg.Content
    $typeLbl = New-Object System.Windows.Controls.TextBlock
    $typeLbl.Text       = "Type: $effectiveType"
    $typeLbl.FontSize   = 11
    $typeLbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6B7280")
    $typeLbl.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $typeLbl.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    [System.Windows.Controls.Grid]::SetRow($typeLbl, 0)
    [void]$dlgGrid.Children.Add($typeLbl)

    $txtName   = $dlg.FindName('txtName')
    $txtSource = $dlg.FindName('txtSource')
    $txtTarget = $dlg.FindName('txtTarget')
    $btnBS     = $dlg.FindName('btnBrowseSource')
    $btnBT     = $dlg.FindName('btnBrowseTarget')
    $btnSave   = $dlg.FindName('btnSave')
    $btnCan    = $dlg.FindName('btnCancel')

    if ($Existing) {
        $txtName.Text   = $Existing.Name
        $txtSource.Text = $Existing.Source
        $txtTarget.Text = $Existing.Target
    }

    $script:DlgResult = $null

    # Note: .GetNewClosure() is required so WPF event handlers (called from the
    # WPF message loop, outside PowerShell's call stack) can see local variables
    # like $txtSource, $dlg, $Existing that are defined in this function scope.

    $btnBS.Add_Click({
        if ($effectiveType -eq "File") {
            $fd = New-Object System.Windows.Forms.OpenFileDialog
            $fd.Title = "Select Source File"
            $initPath = $txtSource.Text
            if ($initPath -and (Test-Path (Split-Path $initPath -Parent))) {
                $fd.InitialDirectory = Split-Path $initPath -Parent
                $fd.FileName = Split-Path $initPath -Leaf
            }
            if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtSource.Text = $fd.FileName
            }
        } else {
            $fd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fd.Description  = "Select Source Path"
            $fd.SelectedPath = $txtSource.Text
            if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtSource.Text = $fd.SelectedPath
            }
        }
    }.GetNewClosure())

    $btnBT.Add_Click({
        if ($effectiveType -eq "File") {
            $fd = New-Object System.Windows.Forms.OpenFileDialog
            $fd.Title = "Select Target File"
            $fd.CheckFileExists = $false
            $initPath = $txtTarget.Text
            if ($initPath -and (Test-Path (Split-Path $initPath -Parent))) {
                $fd.InitialDirectory = Split-Path $initPath -Parent
                $fd.FileName = Split-Path $initPath -Leaf
            }
            if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtTarget.Text = $fd.FileName
            }
        } else {
            $fd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fd.Description  = "Select Target Path"
            $fd.SelectedPath = $txtTarget.Text
            if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtTarget.Text = $fd.SelectedPath
            }
        }
    }.GetNewClosure())

    $btnSave.Add_Click({
        $n = $txtName.Text.Trim()
        $s = $txtSource.Text.Trim()
        $t = $txtTarget.Text.Trim()

        if (-not $n) {
            [System.Windows.MessageBox]::Show("Please enter a display name.", "Required",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null; return
        }
        if (-not $s) {
            [System.Windows.MessageBox]::Show("Please enter a source path.", "Required",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null; return
        }
        if (-not $t) {
            [System.Windows.MessageBox]::Show("Please enter a target path.", "Required",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null; return
        }

        # Duplicate name check (only for Add, or if name changed)
        $isNameChange = (-not $Existing) -or ($Existing.Name -ne $n)
        if ($isNameChange) {
            $dup = $script:Redirects | Where-Object { $_.Name -ieq $n }
            if ($dup) {
                [System.Windows.MessageBox]::Show("A redirect named '$n' already exists.", "Duplicate Name",
                    [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null; return
            }
        }

        $script:DlgResult = [PSCustomObject]@{ Name = $n; Type = $effectiveType; Source = $s; Target = $t }
        $dlg.DialogResult = $true
        $dlg.Close()
    }.GetNewClosure())

    $btnCan.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())

    # Escape = cancel
    $dlg.Add_KeyDown({
        if ($args[1].Key -eq [System.Windows.Input.Key]::Escape) {
            $dlg.DialogResult = $false; $dlg.Close()
        }
    }.GetNewClosure())

    $dlg.ShowDialog() | Out-Null
    return $script:DlgResult
}

# ─────────────────────────────────────────────────────────────────────────────
#  EVENT HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

# Add Folder
$script:btnAddFolder.Add_Click({
    $r = Show-EditDialog -Type "Folder"
    if ($r) {
        $script:Redirects += [PSCustomObject]@{ Name = $r.Name; Type = $r.Type; Source = $r.Source; Target = $r.Target }
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Added: $($r.Name)" "#4ADE80"
    }
})

# Add File
$script:btnAddFile.Add_Click({
    $r = Show-EditDialog -Type "File"
    if ($r) {
        $script:Redirects += [PSCustomObject]@{ Name = $r.Name; Type = $r.Type; Source = $r.Source; Target = $r.Target }
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Added: $($r.Name)" "#4ADE80"
    }
})

# Edit
$script:btnEdit.Add_Click({
    if (-not $script:SelectedItem) { return }
    $redirect = $script:SelectedItem.Redirect
    $r = Show-EditDialog -Existing $redirect
    if ($r) {
        $redirect.Name   = $r.Name
        $redirect.Source = $r.Source
        $redirect.Target = $r.Target
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Updated: $($r.Name)" "#4ADE80"
    }
})

# Remove
$script:btnRemove.Add_Click({
    if (-not $script:SelectedItem) { return }
    $name     = $script:SelectedItem.Name
    $status   = $script:SelectedItem.Status
    $linkWord = if ($script:SelectedItem.Redirect.Type -eq "File") { "symbolic link" } else { "junction point" }

    $extra = if ($status -eq "Active") {
        "`n`nNote: The $linkWord will NOT be automatically removed. Disable it first if you want to unlink it."
    } else { "" }

    $ans = [System.Windows.MessageBox]::Show(
        "Remove '$name' from the configuration?$extra",
        "Confirm Remove",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)

    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        $redirect = $script:SelectedItem.Redirect
        $script:Redirects = @($script:Redirects | Where-Object { $_ -ne $redirect })
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Removed: $name" "#FBBF24"
    }
})

# Enable
$script:btnEnable.Add_Click({
    if (-not $script:SelectedItem) { return }
    $redirect = $script:SelectedItem.Redirect
    Set-Status "Enabling '$($redirect.Name)'..." "#9CA3AF"
    $ok = Enable-Redirect -Redirect $redirect
    if ($ok) {
        Update-ListView
        Set-Status "Enabled: $($redirect.Name)" "#4ADE80"
    } else {
        Update-ListView
        Set-Status "Enable cancelled or failed." "#FBBF24"
    }
})

# Disable
$script:btnDisable.Add_Click({
    if (-not $script:SelectedItem) { return }
    $redirect  = $script:SelectedItem.Redirect
    $typeWord  = if ($redirect.Type -eq "File") { "symbolic link" } else { "junction" }
    $ans = [System.Windows.MessageBox]::Show(
        "Disable the $typeWord for '$($redirect.Name)'?`n`nThe $typeWord will be removed. Your data remains safely at:`n  $($redirect.Target)",
        "Confirm Disable",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)

    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        Set-Status "Disabling '$($redirect.Name)'..." "#9CA3AF"
        $ok = Disable-Redirect -Redirect $redirect
        Update-ListView
        Set-Status $(if ($ok) { "Disabled: $($redirect.Name)" } else { "Disable failed." }) `
                   $(if ($ok) { "#FBBF24" } else { "#F87171" })
    }
})

# Refresh
$script:btnRefresh.Add_Click({
    Update-ListView
    Set-Status "Refreshed." "#6B7280"
})

# Keyboard shortcuts
$script:Window.Add_KeyDown({
    switch ($args[1].Key) {
        ([System.Windows.Input.Key]::F5) {
            $script:btnRefresh.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        }
        ([System.Windows.Input.Key]::Delete) {
            if ($script:btnRemove.IsEnabled) {
                $script:btnRemove.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            }
        }
        ([System.Windows.Input.Key]::Enter) {
            if ($script:btnEdit.IsEnabled) {
                $script:btnEdit.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            }
        }
    }
})

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
Load-Config
$script:ListViewErrors = ""
Update-ListView
if ($script:LoadError) {
    Set-Status "Config error: $script:LoadError" "#F87171"
} elseif ($script:Redirects.Count -eq 0) {
    Set-Status "No redirects configured. Click Add to create one." "#9CA3AF"
} elseif ($script:ListViewErrors) {
    Set-Status "Render error - check %TEMP%\TheRedirector_debug.log: $($script:ListViewErrors.Trim())" "#F87171"
} else {
    $_lbCount = $script:spCards.Children.Count
    Set-Status "Loaded $($script:Redirects.Count) redirect(s) | $($_lbCount) rendered in list." "#4ADE80"
}
$script:Window.ShowDialog() | Out-Null
