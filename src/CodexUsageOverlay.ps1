$ErrorActionPreference = 'Stop'
$installDirectory = $PSScriptRoot
$startScript = Join-Path $installDirectory 'Start-CodexUsageOverlay.vbs'
$watcherScript = Join-Path $installDirectory 'CodexOverlayWatcher.ps1'
$restartScript = Join-Path $installDirectory 'Restart-CodexUsageOverlay.vbs'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    if (Test-Path -LiteralPath $startScript -PathType Leaf) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"{0}"' -f $startScript) -WindowStyle Hidden
        exit 0
    }
    throw 'Codex Usage Overlay must run in an STA PowerShell process.'
}

$createdNew = $false
$instanceMutex = [Threading.Mutex]::new($true, 'Local\CodexUsageOverlay', [ref]$createdNew)
if (-not $createdNew) {
    $instanceMutex.Dispose()
    exit 0
}

$configPath = Join-Path $installDirectory 'config.json'
$positionPath = Join-Path $installDirectory 'position.json'
$statePath = Join-Path $installDirectory 'warning-state.json'
$runtimeStatusPath = Join-Path $installDirectory 'runtime-status.json'
$logDirectory = Join-Path $installDirectory 'logs'
$logPath = Join-Path $logDirectory 'overlay.log'
$accountsReaderPath = Join-Path $installDirectory 'Get-CodexAccounts.ps1'
$accountSwitchPath = Join-Path $installDirectory 'Switch-CodexAccount.ps1'
$accountRemovePath = Join-Path $installDirectory 'Remove-CodexAccount.ps1'
$newLoginPath = Join-Path $installDirectory 'Start-CodexAuthLogin.ps1'
$startupLink = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'Codex Usage Overlay.lnk'
$autostartTaskName = 'Codex Usage Overlay'
$null = New-Item -ItemType Directory -Path $logDirectory -Force

function Write-SafeLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    try {
        $cleanMessage = ($Message -replace '[\r\n]+', ' ').Trim()
        if ($cleanMessage.Length -gt 220) { $cleanMessage = $cleanMessage.Substring(0, 220) }
        $line = '{0} {1} {2}{3}' -f [DateTime]::UtcNow.ToString('o'), $Level, $cleanMessage, [Environment]::NewLine
        [IO.File]::AppendAllText($logPath, $line, [Text.UTF8Encoding]::new($false))
    } catch {
        # Logging is best effort. Account labels and command output are never logged.
    }
}

function Get-OverlayConfig {
    $settings = [ordered]@{
        refreshSeconds = 60
        opacity = 0.92
        alwaysOnTop = $true
        clickThrough = $false
        rightMargin = 18
        topMargin = 18
        bottomMargin = 18
        warningThresholds = @(20, 10, 5)
        apiUsageConsent = $false
        codexAuthExecutable = ''
        accountExpiryDates = [pscustomobject]@{}
    }

    try {
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $loaded = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
            foreach ($property in $loaded.PSObject.Properties) {
                if ($settings.Contains($property.Name)) { $settings[$property.Name] = $property.Value }
            }
        }
    } catch {
        Write-SafeLog -Level 'ERROR' -Message 'Configuration could not be parsed; safe defaults are active.'
    }

    $settings.refreshSeconds = [Math]::Max(30, [Math]::Min(3600, [int]$settings.refreshSeconds))
    $settings.opacity = [Math]::Max(0.55, [Math]::Min(1.0, [double]$settings.opacity))
    $settings.rightMargin = [Math]::Max(0, [Math]::Min(500, [int]$settings.rightMargin))
    $settings.topMargin = [Math]::Max(0, [Math]::Min(500, [int]$settings.topMargin))
    $settings.bottomMargin = [Math]::Max(0, [Math]::Min(500, [int]$settings.bottomMargin))
    $settings.apiUsageConsent = [bool]$settings.apiUsageConsent
    $thresholds = @($settings.warningThresholds | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 99 } | Sort-Object -Unique -Descending)
    if ($thresholds.Count -eq 0) { $thresholds = @(20, 10, 5) }
    $settings.warningThresholds = $thresholds
    return [pscustomobject]$settings
}

$config = Get-OverlayConfig

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('CodexUsageOverlay.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexUsageOverlay
{
    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    }
}
'@
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Usage Overlay &amp; Multi-Account Manager"
        Width="379" Height="38"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <Style x:Key="OverlayScrollBarStyle" TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="7"/>
            <Setter Property="Background" Value="#FF172033"/>
            <Setter Property="Foreground" Value="#FF52637B"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid Width="7" Background="{TemplateBinding Background}">
                            <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="{x:Type RepeatButton}">
                                                <Border Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Background="{TemplateBinding Foreground}" MinHeight="28" Margin="1,1" Focusable="False">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="{x:Type Thumb}">
                                                <Border Background="{TemplateBinding Background}" CornerRadius="3"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="{x:Type RepeatButton}">
                                                <Border Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Margin="3">
        <Grid.RowDefinitions>
            <RowDefinition Height="32"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border x:Name="TopShell" Grid.Row="0" CornerRadius="9" Background="#EE111827"
                BorderBrush="#3FFFFFFF" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="10" ShadowDepth="1" Opacity="0.42" Color="#000000"/>
            </Border.Effect>
            <Grid x:Name="TopGrid" Margin="7,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="58"/>
                    <ColumnDefinition Width="1"/>
                    <ColumnDefinition Width="126"/>
                    <ColumnDefinition Width="1"/>
                    <ColumnDefinition Width="147"/>
                    <ColumnDefinition Width="18"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="CodexButton" Grid.Column="0" Background="Transparent" Cursor="Hand"
                        ToolTip="Show accounts" Focusable="False">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="CODEX" Foreground="#F8FAFC" FontFamily="Segoe UI"
                                   FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <TextBlock x:Name="MenuChevron" Text="&#x25BE;" Foreground="#94A3B8"
                                   FontSize="9" Margin="4,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                </Border>
                <Border Grid.Column="1" Background="#28FFFFFF" Margin="0,8"/>

                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,4,0">
                    <TextBlock Text="5h" Foreground="#94A3B8" FontFamily="Segoe UI"
                               FontSize="10" VerticalAlignment="Center"/>
                    <TextBlock x:Name="FivePercent" Text="--%" Foreground="#E2E8F0"
                               FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold"
                               Margin="5,0,0,0" VerticalAlignment="Center"/>
                    <TextBlock Text="&#x00B7;" Foreground="#475569" FontSize="11" Margin="4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="FiveReset" Text="--:--:--" Foreground="#94A3B8"
                               FontFamily="Cascadia Mono, Consolas" FontSize="9.5" VerticalAlignment="Center"/>
                </StackPanel>

                <Border Grid.Column="3" Background="#28FFFFFF" Margin="0,8"/>

                <StackPanel x:Name="WeeklySummary" Grid.Column="4" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,4,0">
                    <TextBlock Text="7d" Foreground="#94A3B8" FontFamily="Segoe UI"
                               FontSize="10" VerticalAlignment="Center"/>
                    <TextBlock x:Name="WeeklyPercent" Text="--%" Foreground="#E2E8F0"
                               FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold"
                               Margin="5,0,0,0" VerticalAlignment="Center"/>
                    <TextBlock Text="&#x00B7;" Foreground="#475569" FontSize="11" Margin="4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="WeeklyReset" Text="--d --h" Foreground="#94A3B8"
                               FontFamily="Cascadia Mono, Consolas" FontSize="9.5" VerticalAlignment="Center"/>
                </StackPanel>

                <Border x:Name="DragHandle" Grid.Column="5" Background="Transparent" Cursor="SizeAll"
                        ToolTip="Drag to move" Focusable="False">
                    <TextBlock Text="&#x28FF;" Foreground="#64748B" FontSize="14"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
            </Grid>
        </Border>

        <Border x:Name="AccountsPanel" Grid.Row="1" Visibility="Collapsed" Margin="0,4,0,4"
                CornerRadius="10" Background="#FF111827" BorderBrush="#8064748B" BorderThickness="1"
                Padding="7">
            <Border.Effect>
                <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.46" Color="#000000"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="30"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="1"/>
                    <RowDefinition Height="40"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="4,0,2,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="AccountsTitle" Text="ACCOUNTS" Foreground="#E2E8F0"
                               FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="PanelStatus" Grid.Column="1" Foreground="#64748B"
                               FontFamily="Segoe UI" FontSize="9.5" VerticalAlignment="Center"
                               HorizontalAlignment="Right" TextAlignment="Right"
                               TextTrimming="CharacterEllipsis" MaxWidth="190" ToolTip="Latest overlay status"/>
                </Grid>

                <ScrollViewer x:Name="AccountsScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto"
                              HorizontalScrollBarVisibility="Disabled" MaxHeight="520">
                    <ScrollViewer.Resources>
                        <Style TargetType="{x:Type ScrollBar}" BasedOn="{StaticResource OverlayScrollBarStyle}"/>
                    </ScrollViewer.Resources>
                    <StackPanel x:Name="AccountsHost"/>
                </ScrollViewer>

                <Border Grid.Row="2" Background="#24FFFFFF" Margin="2,0"/>

                <Grid Grid.Row="3" Margin="3,5,2,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border x:Name="RefreshButton" Grid.Column="0" Background="#263B82F6" BorderBrush="#4D60A5FA"
                            BorderThickness="1" CornerRadius="6" Width="84" Height="30" Padding="0" Cursor="Hand"
                            HorizontalAlignment="Left" VerticalAlignment="Center"
                            ToolTip="Refresh usage now" Focusable="False">
                        <TextBlock Text="Refresh" Foreground="#DBEAFE" FontFamily="Segoe UI"
                                   FontSize="10.5" FontWeight="SemiBold" TextAlignment="Center"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <Border x:Name="NewLoginButton" Grid.Column="1" Background="#263B82F6" BorderBrush="#4D60A5FA"
                            BorderThickness="1" CornerRadius="6" Width="84" Height="30" Padding="0" Cursor="Hand"
                            HorizontalAlignment="Right" VerticalAlignment="Center"
                            ToolTip="Add an account with device authorization" Focusable="False">
                        <TextBlock Text="+ New login" Foreground="#DBEAFE" FontFamily="Segoe UI"
                                   FontSize="10.5" FontWeight="SemiBold" TextAlignment="Center"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$xmlReader = [Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)
$topShell = $window.FindName('TopShell')
$codexButton = $window.FindName('CodexButton')
$menuChevron = $window.FindName('MenuChevron')
$fivePercent = $window.FindName('FivePercent')
$fiveReset = $window.FindName('FiveReset')
$weeklyPercent = $window.FindName('WeeklyPercent')
$weeklyReset = $window.FindName('WeeklyReset')
$topGrid = $window.FindName('TopGrid')
$weeklySummary = $window.FindName('WeeklySummary')
$dragHandle = $window.FindName('DragHandle')
$accountsPanel = $window.FindName('AccountsPanel')
$accountsTitle = $window.FindName('AccountsTitle')
$accountsScroll = $window.FindName('AccountsScroll')
$accountsHost = $window.FindName('AccountsHost')
$panelStatus = $window.FindName('PanelStatus')
$refreshButton = $window.FindName('RefreshButton')
$newLoginButton = $window.FindName('NewLoginButton')
$window.Opacity = 1.0
$topShell.Opacity = $config.opacity
$window.Topmost = [bool]$config.alwaysOnTop

$brushConverter = [Windows.Media.BrushConverter]::new()
function Get-Brush([string]$Color) { return $brushConverter.ConvertFromString($Color) }
$brushNormal = Get-Brush '#A7F3D0'
$brushWarning20 = Get-Brush '#FBBF24'
$brushWarning10 = Get-Brush '#FB923C'
$brushWarning5 = Get-Brush '#F87171'
$brushError = Get-Brush '#C084FC'
$brushUnavailable = Get-Brush '#94A3B8'
$brushBorderNormal = Get-Brush '#3FFFFFFF'
$brushActiveRow = Get-Brush '#263B82F6'
$brushHoverRow = Get-Brush '#16FFFFFF'
$brushTransparent = [Windows.Media.Brushes]::Transparent

$script:collapsedHeight = 38.0
$script:fullWindowWidth = 379.0
$script:fullWeeklyColumnWidth = 147.0
$script:fullDragColumnWidth = 18.0
$script:compactMinimumWeeklyColumnWidth = 76.0
$script:menuExpanded = $false
$script:accounts = @()
$script:fiveHourUsage = $null
$script:weeklyUsage = $null
$script:activeRowNumber = $null
$script:lastSuccessfulRefreshUtc = $null
$script:lastLoggedUsage = ''
$script:lastErrorCode = ''
$script:lastErrorLoggedUtc = [DateTime]::MinValue
$script:refreshProcess = $null
$script:refreshOutputTask = $null
$script:refreshErrorTask = $null
$script:refreshStartedUtc = $null
$script:refreshTimedOut = $false
$script:switchProcess = $null
$script:switchOutputTask = $null
$script:switchErrorTask = $null
$script:switchStartedUtc = $null
$script:removeProcess = $null
$script:removeOutputTask = $null
$script:removeErrorTask = $null
$script:removeStartedUtc = $null
$script:allowExit = $false
$script:overlayHandle = [IntPtr]::Zero
$script:outsideClickMouseDown = $false
$script:outsideClickTimer = $null
$script:outsideClickIgnoreUntilUtc = [DateTime]::MinValue
$script:removalPanelWasExpanded = $false

function Get-SavedOverlayPosition {
    try {
        if (-not (Test-Path -LiteralPath $positionPath -PathType Leaf)) { return $null }
        $saved = Get-Content -Raw -LiteralPath $positionPath | ConvertFrom-Json
        $left = [double]$saved.left
        $top = [double]$saved.top
        if ([double]::IsNaN($left) -or [double]::IsInfinity($left) -or [double]::IsNaN($top) -or [double]::IsInfinity($top)) { return $null }
        return [pscustomobject]@{ left = $left; top = $top }
    } catch {
        return $null
    }
}

function Save-OverlayPosition {
    try {
        $payload = [ordered]@{
            left = [Math]::Round([double]$window.Left, 1)
            top = [Math]::Round([double]$window.Top, 1)
            savedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $temporaryPath = $positionPath + '.tmp'
        [IO.File]::WriteAllText($temporaryPath, ($payload | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $positionPath -Force
        $script:savedPosition = [pscustomobject]@{ left = $payload.left; top = $payload.top }
        Write-SafeLog -Level 'INFO' -Message ('Overlay moved: left={0} top={1}.' -f $payload.left, $payload.top)
    } catch {
        Write-SafeLog -Level 'WARN' -Message 'Overlay position could not be saved.'
    }
}

function Position-Overlay {
    $virtualLeft = [double][Windows.SystemParameters]::VirtualScreenLeft
    $virtualTop = [double][Windows.SystemParameters]::VirtualScreenTop
    $virtualRight = $virtualLeft + [double][Windows.SystemParameters]::VirtualScreenWidth
    $virtualBottom = $virtualTop + [double][Windows.SystemParameters]::VirtualScreenHeight
    $maximumLeft = [Math]::Max($virtualLeft, $virtualRight - $window.Width)
    $maximumTop = [Math]::Max($virtualTop, $virtualBottom - $window.Height)

    if ($script:savedPosition) {
        $window.Left = [Math]::Max($virtualLeft, [Math]::Min($maximumLeft, [double]$script:savedPosition.left))
        $window.Top = [Math]::Max($virtualTop, [Math]::Min($maximumTop, [double]$script:savedPosition.top))
        return
    }

    $workArea = [Windows.SystemParameters]::WorkArea
    $window.Left = $workArea.Right - $window.Width - $config.rightMargin
    $window.Top = $workArea.Top + $config.topMargin
}

function Reset-OverlayPosition {
    if (Test-Path -LiteralPath $positionPath -PathType Leaf) { Remove-Item -LiteralPath $positionPath -Force }
    $script:savedPosition = $null
    Position-Overlay
}

function Set-FullCollapsedBarWidth {
    $topGrid.ColumnDefinitions[4].Width = [Windows.GridLength]::new($script:fullWeeklyColumnWidth)
    $topGrid.ColumnDefinitions[5].Width = [Windows.GridLength]::new($script:fullDragColumnWidth)
    $window.Width = $script:fullWindowWidth
}

function Update-CollapsedBarWidth {
    if ($script:menuExpanded) { Set-FullCollapsedBarWidth; return }
    try {
        # Measure the weekly summary without the fixed grid-column constraint so
        # short values such as "N/A" do not leave a large trailing void.
        $infiniteSize = [Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)
        $weeklySummary.Measure($infiniteSize)
        $desiredWeeklyWidth = [Math]::Ceiling([double]$weeklySummary.DesiredSize.Width) + 2.0
    } catch {
        $desiredWeeklyWidth = $script:compactMinimumWeeklyColumnWidth
    }
    $desiredWeeklyWidth = [Math]::Max($script:compactMinimumWeeklyColumnWidth, [Math]::Min($script:fullWeeklyColumnWidth, $desiredWeeklyWidth))
    $topGrid.ColumnDefinitions[4].Width = [Windows.GridLength]::new($desiredWeeklyWidth)
    $topGrid.ColumnDefinitions[5].Width = [Windows.GridLength]::new($script:fullDragColumnWidth)
    $window.Width = $script:fullWindowWidth - ($script:fullWeeklyColumnWidth - $desiredWeeklyWidth)
    $window.UpdateLayout()
}

$script:savedPosition = Get-SavedOverlayPosition

function Get-ExpandedWindowHeight {
    $workAreaHeight = [double][Windows.SystemParameters]::WorkArea.Height
    $rowHeight = [Math]::Min(520.0, [Math]::Max(62.0, [double]$script:accounts.Count * 56.0))
    # Four extra pixels keep the bottom border and shadow inside the window at
    # every display scale instead of letting them blend into the window edge.
    return [Math]::Min([Math]::Max(177.0, $script:collapsedHeight + 94.0 + $rowHeight), [Math]::Max(220.0, $workAreaHeight - 12.0))
}

function Update-ExpandedWindowSize {
    if (-not $script:menuExpanded) { return }
    $availableScrollHeight = [Math]::Max(58.0, [double][Windows.SystemParameters]::WorkArea.Height - 150.0)
    $accountsScroll.MaxHeight = [Math]::Min(520.0, $availableScrollHeight)
    $window.Height = Get-ExpandedWindowHeight
    Position-Overlay
}

$window.add_SourceInitialized({
    $helper = [Windows.Interop.WindowInteropHelper]::new($window)
    $handle = $helper.Handle
    $GWL_EXSTYLE = -20
    $WS_EX_TOOLWINDOW = 0x00000080
    $WS_EX_NOACTIVATE = 0x08000000
    $WS_EX_TRANSPARENT = 0x00000020
    $style = [CodexUsageOverlay.NativeMethods]::GetWindowLong($handle, $GWL_EXSTYLE)
    $style = $style -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE
    if ([bool]$config.clickThrough) { $style = $style -bor $WS_EX_TRANSPARENT }
    $null = [CodexUsageOverlay.NativeMethods]::SetWindowLong($handle, $GWL_EXSTYLE, $style)
    $script:overlayHandle = $handle
})
$window.add_ContentRendered({ Position-Overlay })

function New-TrayIcon {
    $bitmap = [Drawing.Bitmap]::new(32, 32)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $backgroundBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 16, 24, 39))
    $foregroundBrush = [Drawing.SolidBrush]::new([Drawing.Color]::White)
    $font = [Drawing.Font]::new('Segoe UI', 17, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $format = [Drawing.StringFormat]::new()
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    $graphics.FillEllipse($backgroundBrush, 1, 1, 30, 30)
    $graphics.DrawString('C', $font, $foregroundBrush, [Drawing.RectangleF]::new(0, 0, 32, 31), $format)
    $iconHandle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($iconHandle).Clone()
    $null = [CodexUsageOverlay.NativeMethods]::DestroyIcon($iconHandle)
    $format.Dispose(); $font.Dispose(); $foregroundBrush.Dispose(); $backgroundBrush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    return $icon
}

function Test-Autostart {
    $scheduler = $null
    $rootFolder = $null
    $task = $null
    try {
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder('\')
        $task = $rootFolder.GetTask($autostartTaskName)
        return [bool]$task.Enabled
    } catch {
        return $false
    } finally {
        foreach ($item in @($task, $rootFolder, $scheduler)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
}

function Enable-Autostart {
    $scheduler = $null
    $rootFolder = $null
    $definition = $null
    $trigger = $null
    $action = $null
    $registeredTask = $null
    try {
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder('\')
        $definition = $scheduler.NewTask(0)
        $definition.RegistrationInfo.Description = 'Watch for the Codex desktop app and start the usage overlay when Codex opens.'
        $definition.Settings.Enabled = $true
        $definition.Settings.AllowDemandStart = $true
        $definition.Settings.StartWhenAvailable = $true
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        $definition.Settings.ExecutionTimeLimit = 'PT0S'
        $definition.Settings.MultipleInstances = 2

        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $definition.Principal.UserId = $userId
        $definition.Principal.LogonType = 3
        $definition.Principal.RunLevel = 0

        $trigger = $definition.Triggers.Create(9)
        $trigger.Enabled = $true
        $trigger.UserId = $userId

        $action = $definition.Actions.Create(0)
        $action.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $watcherScript
        $action.WorkingDirectory = $installDirectory

        $registeredTask = $rootFolder.RegisterTaskDefinition($autostartTaskName, $definition, 6, $userId, $null, 3, $null)
        if (Test-Path -LiteralPath $startupLink -PathType Leaf) { Remove-Item -LiteralPath $startupLink -Force }
    } finally {
        foreach ($item in @($registeredTask, $action, $trigger, $definition, $rootFolder, $scheduler)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
}

function Disable-Autostart {
    $scheduler = $null
    $rootFolder = $null
    try {
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder('\')
        try { $rootFolder.DeleteTask($autostartTaskName, 0) } catch { }
    } finally {
        foreach ($item in @($rootFolder, $scheduler)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
    if (Test-Path -LiteralPath $startupLink -PathType Leaf) { Remove-Item -LiteralPath $startupLink -Force }
}

$notifyIcon = [Windows.Forms.NotifyIcon]::new()
$trayIcon = New-TrayIcon
$notifyIcon.Icon = $trayIcon
$notifyIcon.Text = 'Codex usage: loading'
$notifyIcon.Visible = $true

$contextMenu = [Windows.Forms.ContextMenuStrip]::new()
$showItem = [Windows.Forms.ToolStripMenuItem]::new('Hide overlay')
$accountsItem = [Windows.Forms.ToolStripMenuItem]::new('Show accounts')
$refreshItem = [Windows.Forms.ToolStripMenuItem]::new('Refresh now')
$resetPositionItem = [Windows.Forms.ToolStripMenuItem]::new('Move to top-right')
$autostartItem = [Windows.Forms.ToolStripMenuItem]::new('Start automatically with Codex')
$restartItem = [Windows.Forms.ToolStripMenuItem]::new('Restart')
$exitItem = [Windows.Forms.ToolStripMenuItem]::new('Exit')
$autostartItem.Checked = Test-Autostart
$null = $contextMenu.Items.Add($showItem)
$null = $contextMenu.Items.Add($accountsItem)
$null = $contextMenu.Items.Add($refreshItem)
$null = $contextMenu.Items.Add($resetPositionItem)
$null = $contextMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$null = $contextMenu.Items.Add($autostartItem)
$null = $contextMenu.Items.Add($restartItem)
$null = $contextMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$null = $contextMenu.Items.Add($exitItem)
$notifyIcon.ContextMenuStrip = $contextMenu

function Get-WarningState {
    $state = @{
        fiveHour = @{ cycle = ''; warned = @() }
        weekly = @{ cycle = ''; warned = @() }
    }
    try {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $loaded = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            foreach ($key in @('fiveHour', 'weekly')) {
                $entry = $loaded.$key
                if ($entry) { $state[$key] = @{ cycle = [string]$entry.cycle; warned = @($entry.warned) } }
            }
        }
    } catch {
        Write-SafeLog -Level 'WARN' -Message 'Warning state was unreadable and has been reset.'
    }
    return $state
}

$script:warningState = Get-WarningState

function Save-WarningState {
    try {
        $temporaryPath = $statePath + '.tmp'
        [IO.File]::WriteAllText($temporaryPath, ($script:warningState | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force
    } catch {
        Write-SafeLog -Level 'WARN' -Message 'Warning state could not be saved.'
    }
}

function Write-RuntimeStatus {
    param([bool]$Running, [string]$State = 'running')
    try {
        $payload = [ordered]@{
            running = $Running
            processId = $PID
            state = $State
            source = 'codex-auth list --api'
            accountCount = $script:accounts.Count
            activeRow = $script:activeRowNumber
            lastRefreshUtc = if ($script:lastSuccessfulRefreshUtc) { $script:lastSuccessfulRefreshUtc.ToString('o') } else { $null }
            fiveHour = $script:fiveHourUsage
            weekly = $script:weeklyUsage
        }
        $temporaryPath = $runtimeStatusPath + '.tmp'
        [IO.File]::WriteAllText($temporaryPath, ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $runtimeStatusPath -Force
    } catch {
        # Runtime status contains no account labels or command output.
    }
}

function Convert-SafeUsage {
    param($InputUsage)
    if ($null -eq $InputUsage) { return $null }
    $status = [string]$InputUsage.status
    if ($status -eq 'ok') {
        try {
            $remaining = [int]$InputUsage.remainingPercent
            if ($remaining -lt 0 -or $remaining -gt 100) { return $null }
            $resetEpoch = if ($null -ne $InputUsage.resetEpochSeconds) { [long]$InputUsage.resetEpochSeconds } else { $null }
            $resetText = ([string]$InputUsage.resetText -replace '[\x00-\x1F]', '').Trim()
            if ($resetText.Length -gt 40) { $resetText = $resetText.Substring(0, 40) }
            return [pscustomobject]@{
                status = 'ok'
                remainingPercent = $remaining
                resetText = $resetText
                resetEpochSeconds = $resetEpoch
            }
        } catch { return $null }
    }
    if ($status -eq 'http_error') {
        $statusCode = [string]$InputUsage.statusCode
        if ($statusCode -notmatch '^\d{3}$') { $statusCode = 'error' }
        return [pscustomobject]@{ status = 'http_error'; statusCode = $statusCode; remainingPercent = $null; resetText = ''; resetEpochSeconds = $null }
    }
    if ($status -eq 'api_error') {
        $errorName = [string]$InputUsage.errorName
        if ($errorName -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') { $errorName = 'ApiError' }
        return [pscustomobject]@{ status = 'api_error'; errorName = $errorName; remainingPercent = $null; resetText = ''; resetEpochSeconds = $null }
    }
    return [pscustomobject]@{ status = 'unavailable'; remainingPercent = $null; resetText = ''; resetEpochSeconds = $null }
}

function Convert-SafeAccount {
    param($InputAccount)
    try {
        $rowNumber = [int]$InputAccount.rowNumber
        if ($rowNumber -lt 1 -or $rowNumber -gt 999) { return $null }
        $label = ([string]$InputAccount.accountLabel -replace '[\x00-\x1F]', '').Trim()
        $email = ([string]$InputAccount.email -replace '[\x00-\x1F]', '').Trim()
        $plan = ([string]$InputAccount.plan -replace '[\x00-\x1F]', '').Trim()
        if ([string]::IsNullOrWhiteSpace($label) -or $label.Length -gt 180) { return $null }
        if ($email.Length -gt 180) { $email = $email.Substring(0, 180) }
        if ($plan.Length -gt 32) { $plan = $plan.Substring(0, 32) }
        return [pscustomobject]@{
            rowNumber = $rowNumber
            active = [bool]$InputAccount.active
            accountLabel = $label
            email = $email
            plan = $plan
            fiveHour = Convert-SafeUsage $InputAccount.fiveHour
            weekly = Convert-SafeUsage $InputAccount.weekly
        }
    } catch { return $null }
}

function Get-AccountExpiryText {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email) -or $null -eq $config.accountExpiryDates) { return '' }
    try {
        $entry = $config.accountExpiryDates.PSObject.Properties | Where-Object { $_.Name -ieq $Email } | Select-Object -First 1
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) { return '' }
        $expiry = [DateTime]::ParseExact([string]$entry.Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).Date
        $days = [int][Math]::Ceiling(($expiry - [DateTime]::Today).TotalDays)
        if ($days -lt 0) { return 'Expired' }
        if ($days -eq 0) { return 'Ends today' }
        if ($days -eq 1) { return '1 day left' }
        return ('{0} days left' -f $days)
    } catch {
        return ''
    }
}

function Format-Countdown {
    param($Usage, [ValidateSet('fiveHour', 'weekly')][string]$Kind)
    if ($null -eq $Usage -or $Usage.status -ne 'ok' -or $null -eq $Usage.resetEpochSeconds) { return 'N/A' }
    $remainingSeconds = [long]$Usage.resetEpochSeconds - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($remainingSeconds -le 0) { return 'due now' }
    $span = [TimeSpan]::FromSeconds($remainingSeconds)
    if ($Kind -eq 'weekly' -and $span.TotalDays -ge 1) { return ('{0}d {1:00}h' -f [Math]::Floor($span.TotalDays), $span.Hours) }
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Get-UsageBrush {
    param($Usage)
    if ($null -eq $Usage) { return $brushUnavailable }
    if ($Usage.status -eq 'http_error' -or $Usage.status -eq 'api_error') { return $brushError }
    if ($Usage.status -ne 'ok') { return $brushUnavailable }
    $remaining = [int]$Usage.remainingPercent
    if ($remaining -le 5) { return $brushWarning5 }
    if ($remaining -le 10) { return $brushWarning10 }
    if ($remaining -le 20) { return $brushWarning20 }
    return $brushNormal
}

function Get-UsageBarText {
    param($Usage)
    if ($null -eq $Usage) { return '--%' }
    if ($Usage.status -eq 'ok') { return ('{0}%' -f [int]$Usage.remainingPercent) }
    if ($Usage.status -eq 'http_error' -or $Usage.status -eq 'api_error') { return 'error' }
    return '--%'
}

function Update-CountdownDisplay {
    $fiveReset.Text = Format-Countdown -Usage $script:fiveHourUsage -Kind 'fiveHour'
    $weeklyReset.Text = Format-Countdown -Usage $script:weeklyUsage -Kind 'weekly'
}

function Update-UsageDisplay {
    $fivePercent.Text = Get-UsageBarText $script:fiveHourUsage
    $weeklyPercent.Text = Get-UsageBarText $script:weeklyUsage
    $fivePercent.Foreground = Get-UsageBrush $script:fiveHourUsage
    $weeklyPercent.Foreground = Get-UsageBrush $script:weeklyUsage

    $availablePercentages = @()
    if ($script:fiveHourUsage -and $script:fiveHourUsage.status -eq 'ok') { $availablePercentages += [int]$script:fiveHourUsage.remainingPercent }
    if ($script:weeklyUsage -and $script:weeklyUsage.status -eq 'ok') { $availablePercentages += [int]$script:weeklyUsage.remainingPercent }
    if ($availablePercentages.Count -gt 0) {
        $minimum = ($availablePercentages | Measure-Object -Minimum).Minimum
        if ($minimum -le 5) { $topShell.BorderBrush = $brushWarning5 }
        elseif ($minimum -le 10) { $topShell.BorderBrush = $brushWarning10 }
        elseif ($minimum -le 20) { $topShell.BorderBrush = $brushWarning20 }
        else { $topShell.BorderBrush = $brushBorderNormal }
    } else { $topShell.BorderBrush = $brushBorderNormal }

    Update-CountdownDisplay
    Update-CollapsedBarWidth
    $fiveText = if ($script:fiveHourUsage -and $script:fiveHourUsage.status -eq 'ok') { [string][int]$script:fiveHourUsage.remainingPercent } else { '--' }
    $weeklyText = if ($script:weeklyUsage -and $script:weeklyUsage.status -eq 'ok') { [string][int]$script:weeklyUsage.remainingPercent } else { '--' }
    $tooltip = 'Codex: 5h {0}% | weekly {1}%' -f $fiveText, $weeklyText
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
    $notifyIcon.Text = $tooltip
}

function Check-UsageWarning {
    param([ValidateSet('fiveHour', 'weekly')][string]$Kind, $Usage)
    if ($null -eq $Usage -or $Usage.status -ne 'ok') { return }
    $cycleReset = if ($null -ne $Usage.resetEpochSeconds) { [string]$Usage.resetEpochSeconds } else { 'unknown' }
    $cycle = '{0}:{1}' -f $script:activeRowNumber, $cycleReset
    if ([string]$script:warningState[$Kind].cycle -ne $cycle) { $script:warningState[$Kind] = @{ cycle = $cycle; warned = @() } }
    $remaining = [int]$Usage.remainingPercent
    $breached = @($config.warningThresholds | Where-Object { $remaining -le [int]$_ })
    if ($breached.Count -eq 0) { return }
    $alertThreshold = ($breached | Measure-Object -Minimum).Minimum
    $warned = @($script:warningState[$Kind].warned | ForEach-Object { [int]$_ })
    if ($warned -contains [int]$alertThreshold) { return }
    $script:warningState[$Kind].warned = @($warned + $breached | Sort-Object -Unique)
    Save-WarningState
    $label = if ($Kind -eq 'fiveHour') { '5-hour' } else { 'Weekly' }
    $notifyIcon.ShowBalloonTip(7000, 'Codex usage warning', ('{0} usage has {1}% remaining. Reset in {2}.' -f $label, $remaining, (Format-Countdown -Usage $Usage -Kind $Kind)), [Windows.Forms.ToolTipIcon]::Warning)
    Write-SafeLog -Level 'WARN' -Message ('Warning shown: {0} remaining={1}% threshold={2}%.' -f $Kind, $remaining, $alertThreshold)
}

function Get-AccountUsageSummary {
    param($Usage, [string]$Label)
    if ($null -eq $Usage -or $Usage.status -eq 'unavailable') {
        return [pscustomobject]@{ text = ('{0} unavailable' -f $Label); brush = $brushUnavailable }
    }
    if ($Usage.status -eq 'http_error') {
        return [pscustomobject]@{ text = ('{0} error' -f $Label.ToUpperInvariant()); brush = $brushError }
    }
    if ($Usage.status -eq 'api_error') {
        return [pscustomobject]@{ text = ('{0} error' -f $Label.ToUpperInvariant()); brush = $brushError }
    }
    $reset = if ([string]::IsNullOrWhiteSpace([string]$Usage.resetText)) {
        '--'
    } else {
        # Keep the complete reset value but shorten "21:44 on 3 Sep" to
        # "21:44 3 Sep" so weekly resets remain visible in the compact panel.
        ([string]$Usage.resetText -replace '\s+on\s+', ' ').Trim()
    }
    return [pscustomobject]@{
        text = ('{0} {1}% left | {2}' -f $Label.ToUpperInvariant(), [int]$Usage.remainingPercent, $reset)
        brush = Get-UsageBrush $Usage
    }
}

function New-AccountRow {
    param($Account)
    $row = [Windows.Controls.Border]::new()
    $row.Tag = $Account
    $row.Margin = [Windows.Thickness]::new(0, 1, 0, 1)
    $row.Padding = [Windows.Thickness]::new(7, 7, 7, 7)
    $row.CornerRadius = [Windows.CornerRadius]::new(7)
    $row.Background = if ($Account.active) { $brushActiveRow } else { $brushTransparent }
    $row.Cursor = [Windows.Input.Cursors]::Hand
    $row.Focusable = $false
    $row.ToolTip = if ($Account.active) { 'Active account' } else { 'Click to switch to this account' }

    $rowMenu = [Windows.Controls.ContextMenu]::new()
    $rowMenu.Background = Get-Brush '#FF172033'
    $rowMenu.Foreground = Get-Brush '#F8FAFC'
    $rowMenu.BorderBrush = Get-Brush '#FF172033'
    $rowMenu.BorderThickness = [Windows.Thickness]::new(0)
    $rowMenu.Padding = [Windows.Thickness]::new(0)
    $rowMenu.HasDropShadow = $false
    $rowMenu.add_Opened({ $script:outsideClickIgnoreUntilUtc = [DateTime]::UtcNow.AddMilliseconds(250) })
    $rowMenu.add_Closed({ $script:outsideClickIgnoreUntilUtc = [DateTime]::UtcNow.AddMilliseconds(700) })
    if ($null -eq $script:accountMenuItemTemplate) {
        $menuItemTemplateXaml = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type MenuItem}">
  <Border x:Name="Root" Background="{TemplateBinding Background}" Padding="6,4">
    <StackPanel Orientation="Horizontal">
      <ContentPresenter ContentSource="Icon" VerticalAlignment="Center" />
      <ContentPresenter ContentSource="Header" VerticalAlignment="Center" Margin="6,0,0,0" />
    </StackPanel>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Root" Property="Background" Value="#FF263A58" /></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5" /></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@
        $script:accountMenuItemTemplate = [Windows.Markup.XamlReader]::Parse($menuItemTemplateXaml)
    }
    $removeMenuItem = [Windows.Controls.MenuItem]::new()
    $removeMenuItem.Header = 'Log out & remove'
    $removeMenuItem.Foreground = Get-Brush '#FCA5A5'
    $removeMenuItem.Background = Get-Brush '#FF172033'
    $logoutArrow = [Windows.Shapes.Path]::new()
    $logoutArrow.Width = 16; $logoutArrow.Height = 16; $logoutArrow.Margin = [Windows.Thickness]::new(0, 0, 0, 0)
    $logoutArrow.Data = [Windows.Media.Geometry]::Parse('M1,6 L8,6 L5,3 L7,1 L15,8 L7,15 L5,13 L8,10 L1,10 Z')
    $logoutArrow.Fill = Get-Brush '#FCA5A5'
    $removeMenuItem.Icon = $logoutArrow
    $removeMenuItem.Template = $script:accountMenuItemTemplate
    $removeMenuItem.Tag = $Account
    $removeMenuItem.ToolTip = 'Remove this local login from codex-auth'
    $removeMenuItem.add_Click({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        $script:outsideClickIgnoreUntilUtc = [DateTime]::UtcNow.AddSeconds(2)
        Start-AccountRemoval -Account $sender.Tag
    })
    $null = $rowMenu.Items.Add($removeMenuItem)
    $row.ContextMenu = $rowMenu

    $grid = [Windows.Controls.Grid]::new()
    $columnActive = [Windows.Controls.ColumnDefinition]::new(); $columnActive.Width = [Windows.GridLength]::new(4)
    $columnMain = [Windows.Controls.ColumnDefinition]::new(); $columnMain.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $columnPlan = [Windows.Controls.ColumnDefinition]::new(); $columnPlan.Width = [Windows.GridLength]::Auto
    $null = $grid.ColumnDefinitions.Add($columnActive); $null = $grid.ColumnDefinitions.Add($columnMain); $null = $grid.ColumnDefinitions.Add($columnPlan)
    $rowTop = [Windows.Controls.RowDefinition]::new(); $rowTop.Height = [Windows.GridLength]::Auto
    $rowUsage = [Windows.Controls.RowDefinition]::new(); $rowUsage.Height = [Windows.GridLength]::Auto
    $null = $grid.RowDefinitions.Add($rowTop); $null = $grid.RowDefinitions.Add($rowUsage)

    if ($Account.active) {
        $activeMark = [Windows.Controls.Border]::new()
        $activeMark.Width = 2; $activeMark.CornerRadius = [Windows.CornerRadius]::new(1); $activeMark.Background = Get-Brush '#60A5FA'
        $activeMark.Margin = [Windows.Thickness]::new(0, 2, 2, 2)
        [Windows.Controls.Grid]::SetRowSpan($activeMark, 2)
        $null = $grid.Children.Add($activeMark)
    }

    $email = [Windows.Controls.TextBlock]::new()
    $email.Text = [string]$Account.email
    $email.ToolTip = [string]$Account.accountLabel
    $email.Foreground = Get-Brush '#F8FAFC'
    $email.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI')
    $email.FontSize = 12; $email.FontWeight = [Windows.FontWeights]::SemiBold
    $email.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $email.VerticalAlignment = [Windows.VerticalAlignment]::Center
    [Windows.Controls.Grid]::SetColumn($email, 1)
    $null = $grid.Children.Add($email)

    $planParts = @([string]$Account.plan)
    $expiryText = Get-AccountExpiryText -Email ([string]$Account.email)
    if ($expiryText) { $planParts += $expiryText }
    if ($Account.active) { $planParts += 'ACTIVE' }
    $planText = $planParts -join ' | '
    $plan = [Windows.Controls.TextBlock]::new()
    $plan.Text = $planText; $plan.Foreground = if ($Account.active) { Get-Brush '#BFDBFE' } else { Get-Brush '#94A3B8' }
    $plan.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI'); $plan.FontSize = 9.5; $plan.FontWeight = [Windows.FontWeights]::Medium
    $plan.VerticalAlignment = [Windows.VerticalAlignment]::Center; $plan.Margin = [Windows.Thickness]::new(7, 0, 0, 0)
    [Windows.Controls.Grid]::SetColumn($plan, 2)
    $null = $grid.Children.Add($plan)

    $usageGrid = [Windows.Controls.Grid]::new()
    $fiveColumn = [Windows.Controls.ColumnDefinition]::new(); $fiveColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $dividerColumn = [Windows.Controls.ColumnDefinition]::new(); $dividerColumn.Width = [Windows.GridLength]::new(1)
    $weekColumn = [Windows.Controls.ColumnDefinition]::new(); $weekColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $null = $usageGrid.ColumnDefinitions.Add($fiveColumn); $null = $usageGrid.ColumnDefinitions.Add($dividerColumn); $null = $usageGrid.ColumnDefinitions.Add($weekColumn)
    $usageGrid.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
    [Windows.Controls.Grid]::SetColumn($usageGrid, 1); [Windows.Controls.Grid]::SetColumnSpan($usageGrid, 2); [Windows.Controls.Grid]::SetRow($usageGrid, 1)

    $fiveSummary = Get-AccountUsageSummary -Usage $Account.fiveHour -Label '5H'
    $five = [Windows.Controls.TextBlock]::new()
    $five.Text = $fiveSummary.text; $five.ToolTip = $fiveSummary.text; $five.Foreground = $fiveSummary.brush
    $five.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI'); $five.FontSize = 10.5; $five.FontWeight = [Windows.FontWeights]::Medium
    $five.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis; $five.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    $null = $usageGrid.Children.Add($five)

    $usageDivider = [Windows.Controls.Border]::new()
    $usageDivider.Background = Get-Brush '#24FFFFFF'; $usageDivider.Margin = [Windows.Thickness]::new(0, 1, 0, 1)
    [Windows.Controls.Grid]::SetColumn($usageDivider, 1)
    $null = $usageGrid.Children.Add($usageDivider)

    $weekSummary = Get-AccountUsageSummary -Usage $Account.weekly -Label '7D'
    $week = [Windows.Controls.TextBlock]::new()
    $week.Text = $weekSummary.text; $week.ToolTip = $weekSummary.text; $week.Foreground = $weekSummary.brush
    $week.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI'); $week.FontSize = 10.5; $week.FontWeight = [Windows.FontWeights]::Medium
    $week.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis; $week.Margin = [Windows.Thickness]::new(7, 0, 0, 0)
    [Windows.Controls.Grid]::SetColumn($week, 2)
    $null = $usageGrid.Children.Add($week)
    $null = $grid.Children.Add($usageGrid)

    $row.Child = $grid
    $row.add_MouseEnter({ param($sender, $eventArgs) if (-not [bool]$sender.Tag.active) { $sender.Background = $brushHoverRow } })
    $row.add_MouseLeave({ param($sender, $eventArgs) $sender.Background = if ([bool]$sender.Tag.active) { $brushActiveRow } else { $brushTransparent } })
    $row.add_MouseLeftButtonUp({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        Start-AccountSwitch -Account $sender.Tag
    })
    return $row
}

function Close-AccountContextMenus {
    foreach ($child in @($accountsHost.Children)) {
        try {
            $contextMenu = $child.ContextMenu
            if ($contextMenu -and $contextMenu.IsOpen) { $contextMenu.IsOpen = $false }
        } catch {
            # Context-menu cleanup is best effort during panel teardown.
        }
    }
}

function Test-AccountContextMenuOpen {
    foreach ($child in @($accountsHost.Children)) {
        try {
            if ($child.ContextMenu -and $child.ContextMenu.IsOpen) { return $true }
        } catch {
            # Context-menu inspection is best effort during click-away handling.
        }
    }
    return $false
}

function Render-Accounts {
    Close-AccountContextMenus
    $accountsHost.Children.Clear()
    if ($script:accounts.Count -eq 0) {
        $empty = [Windows.Controls.TextBlock]::new()
        $empty.Text = 'No accounts available yet.'; $empty.Foreground = $brushUnavailable; $empty.FontSize = 10
        $empty.Margin = [Windows.Thickness]::new(7, 14, 7, 14); $empty.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $null = $accountsHost.Children.Add($empty)
        $accountsTitle.Text = 'ACCOUNTS'
        return
    }
    foreach ($account in $script:accounts) { $null = $accountsHost.Children.Add((New-AccountRow -Account $account)) }
    $accountsTitle.Text = 'ACCOUNTS  {0}' -f $script:accounts.Count
}

function Set-AccountsPanelExpanded {
    param([bool]$Expanded)
    if ([bool]$config.clickThrough) { return }
    $script:menuExpanded = $Expanded
    if ($Expanded) {
        Set-FullCollapsedBarWidth
        Render-Accounts
        $accountsPanel.Visibility = [Windows.Visibility]::Visible
        $menuChevron.Text = [char]0x25B4
        $codexButton.ToolTip = 'Hide accounts'
        $accountsItem.Text = 'Hide accounts'
        Update-ExpandedWindowSize
        if ($null -ne $script:outsideClickTimer) {
            $script:outsideClickMouseDown = $false
            $script:outsideClickTimer.Start()
        }
    } else {
        Close-AccountContextMenus
        $accountsPanel.Visibility = [Windows.Visibility]::Collapsed
        $menuChevron.Text = [char]0x25BE
        $codexButton.ToolTip = 'Show accounts'
        $accountsItem.Text = 'Show accounts'
        $window.Height = $script:collapsedHeight
        if ($null -ne $script:outsideClickTimer) { $script:outsideClickTimer.Stop() }
        Update-CollapsedBarWidth
        Position-Overlay
    }
}

function Apply-RefreshError {
    param([string]$ErrorCode)
    $allowedCodes = @('api_consent_required', 'codex_auth_not_found', 'codex_auth_list_failed', 'unexpected_output', 'no_accounts_parsed', 'reader_failed', 'reader_timeout', 'invalid_response')
    if ($allowedCodes -notcontains $ErrorCode) { $ErrorCode = 'reader_failed' }
    $topShell.BorderBrush = $brushWarning10
    $panelStatus.Text = if ($ErrorCode -eq 'api_consent_required') {
        'API usage consent required | see README'
    } elseif ($script:lastSuccessfulRefreshUtc) {
        'Update failed | showing last result'
    } else {
        'Usage unavailable | retrying'
    }
    $nowUtc = [DateTime]::UtcNow
    if ($ErrorCode -ne $script:lastErrorCode -or ($nowUtc - $script:lastErrorLoggedUtc).TotalMinutes -ge 15) {
        Write-SafeLog -Level 'ERROR' -Message ('Refresh failed: {0}.' -f $ErrorCode)
        $script:lastErrorCode = $ErrorCode; $script:lastErrorLoggedUtc = $nowUtc
    }
    Write-RuntimeStatus -Running $true -State ('error:' + $ErrorCode)
}

function Get-AccountSortBucket {
    param($Account)
    $fiveOk = $Account.fiveHour -and $Account.fiveHour.status -eq 'ok'
    $weeklyOk = $Account.weekly -and $Account.weekly.status -eq 'ok'
    if (-not $fiveOk -or -not $weeklyOk) { return 0 }
    if ([int]$Account.fiveHour.remainingPercent -le 0 -or [int]$Account.weekly.remainingPercent -le 0) { return 1 }
    return 2
}

function Get-AccountUsageRank {
    param($Usage)
    if ($Usage -and $Usage.status -eq 'ok') { return [int]$Usage.remainingPercent }
    return -1
}

function Apply-AccountsResult {
    param($Result)
    if (-not $Result.ok) { Apply-RefreshError -ErrorCode ([string]$Result.errorCode); return }

    $safeAccounts = @($Result.accounts | ForEach-Object { Convert-SafeAccount $_ } | Where-Object { $null -ne $_ } | Sort-Object rowNumber)
    $activeAccounts = @($safeAccounts | Where-Object active)
    if ($safeAccounts.Count -eq 0 -or $activeAccounts.Count -ne 1) { Apply-RefreshError -ErrorCode 'invalid_response'; return }

    # Keep healthy accounts first, then accounts at 0% in either cycle, then
    # errors/unavailable data. Within each group, rank by the lower of the two
    # usable percentages so both 5-hour and weekly capacity are considered.
    $script:accounts = @($safeAccounts | Sort-Object `
        @{ Expression = { Get-AccountSortBucket $_ }; Descending = $true },
        @{ Expression = { [Math]::Min((Get-AccountUsageRank $_.fiveHour), (Get-AccountUsageRank $_.weekly)) }; Descending = $true },
        @{ Expression = { Get-AccountUsageRank $_.fiveHour }; Descending = $true },
        @{ Expression = { Get-AccountUsageRank $_.weekly }; Descending = $true },
        @{ Expression = { [int]$_.rowNumber }; Descending = $false })
    $active = $activeAccounts[0]
    $script:activeRowNumber = [int]$active.rowNumber
    $script:fiveHourUsage = $active.fiveHour
    $script:weeklyUsage = $active.weekly
    $script:lastSuccessfulRefreshUtc = [DateTime]::UtcNow
    $script:lastErrorCode = ''
    $panelStatus.Text = '{0} accounts | updated {1}' -f $script:accounts.Count, [DateTime]::Now.ToString('HH:mm:ss')
    Update-UsageDisplay
    Render-Accounts
    Update-ExpandedWindowSize
    Check-UsageWarning -Kind 'fiveHour' -Usage $script:fiveHourUsage
    Check-UsageWarning -Kind 'weekly' -Usage $script:weeklyUsage

    $signature = '{0}/{1}/{2}/{3}/{4}' -f $script:activeRowNumber,
        $(if ($script:fiveHourUsage -and $script:fiveHourUsage.status -eq 'ok') { $script:fiveHourUsage.remainingPercent } else { 'NA' }),
        $(if ($script:fiveHourUsage) { $script:fiveHourUsage.resetEpochSeconds } else { 'NA' }),
        $(if ($script:weeklyUsage -and $script:weeklyUsage.status -eq 'ok') { $script:weeklyUsage.remainingPercent } else { 'NA' }),
        $(if ($script:weeklyUsage) { $script:weeklyUsage.resetEpochSeconds } else { 'NA' })
    if ($signature -ne $script:lastLoggedUsage) {
        $script:lastLoggedUsage = $signature
        $fiveLog = if ($script:fiveHourUsage -and $script:fiveHourUsage.status -eq 'ok') { [string]$script:fiveHourUsage.remainingPercent } else { 'NA' }
        $weeklyLog = if ($script:weeklyUsage -and $script:weeklyUsage.status -eq 'ok') { [string]$script:weeklyUsage.remainingPercent } else { 'NA' }
        Write-SafeLog -Level 'INFO' -Message ('Usage changed: activeRow={0} fiveHour={1}% weekly={2}%.' -f $script:activeRowNumber, $fiveLog, $weeklyLog)
    }
    Write-RuntimeStatus -Running $true -State 'ok'
}

function Start-UsageRefresh {
    if (-not [bool]$config.apiUsageConsent) { Apply-RefreshError -ErrorCode 'api_consent_required'; return }
    if ($script:switchProcess -and -not $script:switchProcess.HasExited) { return }
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { return }
    if (-not (Test-Path -LiteralPath $accountsReaderPath -PathType Leaf)) { Apply-RefreshError -ErrorCode 'reader_failed'; return }
    try {
        $powerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powerShellPath
        if ($accountsReaderPath.Contains('"')) { throw 'invalid-path' }
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $accountsReaderPath
        if ([string]$config.codexAuthExecutable) {
            $cli = [string]$config.codexAuthExecutable
            if ($cli.Contains('"')) { throw 'invalid-path' }
            $arguments += ' -CodexAuthExecutable "{0}"' -f $cli
        }
        $startInfo.Arguments = $arguments
        $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $script:refreshProcess = [Diagnostics.Process]::new(); $script:refreshProcess.StartInfo = $startInfo
        if (-not $script:refreshProcess.Start()) { throw 'start' }
        $script:refreshOutputTask = $script:refreshProcess.StandardOutput.ReadToEndAsync()
        $script:refreshErrorTask = $script:refreshProcess.StandardError.ReadToEndAsync()
        $script:refreshStartedUtc = [DateTime]::UtcNow; $script:refreshTimedOut = $false
        if (-not $script:lastSuccessfulRefreshUtc) { $panelStatus.Text = 'Refreshing all accounts...' }
    } catch {
        if ($script:refreshProcess) { $script:refreshProcess.Dispose() }
        $script:refreshProcess = $null
        Apply-RefreshError -ErrorCode 'reader_failed'
    }
}

function Complete-UsageRefreshIfReady {
    if (-not $script:refreshProcess) { return }
    if (-not $script:refreshProcess.HasExited) {
        if (-not $script:refreshTimedOut -and $script:refreshStartedUtc -and ([DateTime]::UtcNow - $script:refreshStartedUtc).TotalSeconds -gt 55) {
            $script:refreshTimedOut = $true
            Apply-RefreshError -ErrorCode 'reader_timeout'
        }
        return
    }
    try {
        $output = $script:refreshOutputTask.GetAwaiter().GetResult()
        $null = $script:refreshErrorTask.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($output) -or $output.Length -gt 262144) { throw 'invalid' }
        Apply-AccountsResult -Result ($output | ConvertFrom-Json)
    } catch {
        Apply-RefreshError -ErrorCode 'reader_failed'
    } finally {
        $script:refreshProcess.Dispose(); $script:refreshProcess = $null
        $script:refreshOutputTask = $null; $script:refreshErrorTask = $null; $script:refreshStartedUtc = $null; $script:refreshTimedOut = $false
    }
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Start-AccountSwitch {
    param($Account)
    if ($Account.active) { $panelStatus.Text = 'This account is already active.'; return }
    if ($script:switchProcess -and -not $script:switchProcess.HasExited) { $panelStatus.Text = 'An account switch is already running.'; return }
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { $panelStatus.Text = 'Refresh in progress | try again in a moment.'; return }
    if (-not (Test-Path -LiteralPath $accountSwitchPath -PathType Leaf)) { $panelStatus.Text = 'Switch helper is unavailable.'; return }

    try {
        $rowNumber = [int]$Account.rowNumber
        $labelHash = Get-Sha256Hex -Text ([string]$Account.accountLabel)
        $powerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo = [Diagnostics.ProcessStartInfo]::new(); $startInfo.FileName = $powerShellPath
        if ($accountSwitchPath.Contains('"')) { throw 'invalid-path' }
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RowNumber {1} -ExpectedLabelHash {2}' -f $accountSwitchPath, $rowNumber, $labelHash
        if ([string]$config.codexAuthExecutable) {
            $cli = [string]$config.codexAuthExecutable
            if ($cli.Contains('"')) { throw 'invalid-path' }
            $arguments += ' -CodexAuthExecutable "{0}"' -f $cli
        }
        $startInfo.Arguments = $arguments; $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $script:switchProcess = [Diagnostics.Process]::new(); $script:switchProcess.StartInfo = $startInfo
        if (-not $script:switchProcess.Start()) { throw 'start' }
        $script:switchOutputTask = $script:switchProcess.StandardOutput.ReadToEndAsync()
        $script:switchErrorTask = $script:switchProcess.StandardError.ReadToEndAsync()
        $script:switchStartedUtc = [DateTime]::UtcNow
        $accountsHost.IsEnabled = $false
        $panelStatus.Text = 'Switching account...'
    } catch {
        if ($script:switchProcess) { $script:switchProcess.Dispose() }
        $script:switchProcess = $null; $accountsHost.IsEnabled = $true
        $panelStatus.Text = 'Switch could not be started.'
        Write-SafeLog -Level 'ERROR' -Message 'Account switch could not be started.'
    }
}

function Start-AccountRemoval {
    param($Account)
    if ($null -eq $Account) { return }
    if ($script:removeProcess -and -not $script:removeProcess.HasExited) { $panelStatus.Text = 'A logout is already running.'; return }
    if ($script:switchProcess -and -not $script:switchProcess.HasExited) { $panelStatus.Text = 'Account switch in progress | try again in a moment.'; return }
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { $panelStatus.Text = 'Refresh in progress | try again in a moment.'; return }
    if (-not (Test-Path -LiteralPath $accountRemovePath -PathType Leaf)) { $panelStatus.Text = 'Logout helper is unavailable.'; return }

    $email = [string]$Account.email
    if ([string]::IsNullOrWhiteSpace($email) -or $email -notmatch '(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$') {
        $panelStatus.Text = 'This account has no safe email identifier.'
        return
    }

    $warning = "Remove the local login for:`n`n$email`n`nThis uses codex-auth's exact local account removal command. It cannot be undone by the overlay, and you may need to restart Codex. Continue?"
    $script:removalPanelWasExpanded = [bool]$script:menuExpanded
    $answer = [Windows.MessageBox]::Show($window, $warning, 'Confirm logout and removal', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { $script:removalPanelWasExpanded = $false; return }

    try {
        $rowNumber = [int]$Account.rowNumber
        $labelHash = Get-Sha256Hex -Text ([string]$Account.accountLabel)
        $powerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo = [Diagnostics.ProcessStartInfo]::new(); $startInfo.FileName = $powerShellPath
        if ($accountRemovePath.Contains('"')) { throw 'invalid-path' }
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RowNumber {1} -ExpectedLabelHash {2} -ExpectedEmail "{3}"' -f $accountRemovePath, $rowNumber, $labelHash, $email
        if ([string]$config.codexAuthExecutable) {
            $cli = [string]$config.codexAuthExecutable
            if ($cli.Contains('"')) { throw 'invalid-path' }
            $arguments += ' -CodexAuthExecutable "{0}"' -f $cli
        }
        $startInfo.Arguments = $arguments; $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $script:removeProcess = [Diagnostics.Process]::new(); $script:removeProcess.StartInfo = $startInfo
        if (-not $script:removeProcess.Start()) { throw 'start' }
        $script:removeOutputTask = $script:removeProcess.StandardOutput.ReadToEndAsync()
        $script:removeErrorTask = $script:removeProcess.StandardError.ReadToEndAsync()
        $script:removeStartedUtc = [DateTime]::UtcNow
        $accountsHost.IsEnabled = $false
        $panelStatus.Text = 'Logging out and removing account...'
        Write-SafeLog -Level 'INFO' -Message 'User confirmed local account logout/removal.'
    } catch {
        if ($script:removeProcess) { $script:removeProcess.Dispose() }
        $script:removeProcess = $null; $script:removalPanelWasExpanded = $false; $accountsHost.IsEnabled = $true
        $panelStatus.Text = 'Logout could not be started.'
        Write-SafeLog -Level 'ERROR' -Message 'Logout helper could not be started.'
    }
}

function Complete-AccountRemovalIfReady {
    if (-not $script:removeProcess) { return }
    if (-not $script:removeProcess.HasExited) {
        if ($script:removeStartedUtc -and ([DateTime]::UtcNow - $script:removeStartedUtc).TotalSeconds -gt 30) {
            $panelStatus.Text = 'Logout is taking longer than expected...'
        }
        return
    }
    try {
        $null = $script:removeOutputTask.GetAwaiter().GetResult()
        $null = $script:removeErrorTask.GetAwaiter().GetResult()
        $exitCode = $script:removeProcess.ExitCode
        if ($exitCode -eq 0) {
            $panelStatus.Text = 'Logged out and removed | restart Codex to apply'
            $notifyIcon.ShowBalloonTip(7000, 'Codex account removed', 'The local login was removed. Restart Codex to apply the change.', [Windows.Forms.ToolTipIcon]::Info)
            Write-SafeLog -Level 'INFO' -Message 'Local account logout/removal completed successfully.'
        } elseif ($exitCode -eq 12) {
            $panelStatus.Text = 'Account list changed | refresh and try again'
            Write-SafeLog -Level 'WARN' -Message 'Logout cancelled because the account row changed.'
        } elseif ($exitCode -eq 15) {
            $panelStatus.Text = 'Logout did not remove the account | try again'
            Write-SafeLog -Level 'ERROR' -Message 'Removal returned without removing the account from the local list.'
        } else {
            $panelStatus.Text = 'Logout failed safely | no account was removed'
            Write-SafeLog -Level 'ERROR' -Message ('Logout failed with safe code {0}.' -f $exitCode)
        }
    } catch {
        $panelStatus.Text = 'Logout result could not be read.'
        Write-SafeLog -Level 'ERROR' -Message 'Logout result could not be read.'
    } finally {
        $keepPanelExpanded = [bool]$script:removalPanelWasExpanded
        $script:removalPanelWasExpanded = $false
        $script:outsideClickIgnoreUntilUtc = [DateTime]::UtcNow.AddSeconds(1)
        $script:removeProcess.Dispose(); $script:removeProcess = $null
        $script:removeOutputTask = $null; $script:removeErrorTask = $null; $script:removeStartedUtc = $null
        $accountsHost.IsEnabled = $true
        Start-UsageRefresh
        if ($keepPanelExpanded -and -not $script:menuExpanded) { Set-AccountsPanelExpanded -Expanded $true }
    }
}

function Complete-AccountSwitchIfReady {
    if (-not $script:switchProcess) { return }
    if (-not $script:switchProcess.HasExited) {
        if ($script:switchStartedUtc -and ([DateTime]::UtcNow - $script:switchStartedUtc).TotalSeconds -gt 30) { $panelStatus.Text = 'Account switch is taking longer than expected...' }
        return
    }
    try {
        $null = $script:switchOutputTask.GetAwaiter().GetResult()
        $null = $script:switchErrorTask.GetAwaiter().GetResult()
        $exitCode = $script:switchProcess.ExitCode
        if ($exitCode -eq 0) {
            $panelStatus.Text = 'Switched | restart Codex to apply'
            $notifyIcon.ShowBalloonTip(6500, 'Codex account switched', 'Restart the Codex desktop app to apply the selected account.', [Windows.Forms.ToolTipIcon]::Info)
            Write-SafeLog -Level 'INFO' -Message 'Account switch completed successfully.'
        } elseif ($exitCode -eq 12) {
            $panelStatus.Text = 'Account list changed | refresh and try again'
            Write-SafeLog -Level 'WARN' -Message 'Account switch was cancelled because the row changed.'
        } else {
            $panelStatus.Text = 'Switch failed safely | no account was removed'
            Write-SafeLog -Level 'ERROR' -Message ('Account switch failed with safe code {0}.' -f $exitCode)
        }
    } catch {
        $panelStatus.Text = 'Switch result could not be read.'
        Write-SafeLog -Level 'ERROR' -Message 'Account switch result could not be read.'
    } finally {
        $script:switchProcess.Dispose(); $script:switchProcess = $null
        $script:switchOutputTask = $null; $script:switchErrorTask = $null; $script:switchStartedUtc = $null
        $accountsHost.IsEnabled = $true
        Start-UsageRefresh
    }
}

function Start-NewLogin {
    if (-not (Test-Path -LiteralPath $newLoginPath -PathType Leaf)) { $panelStatus.Text = 'Login helper is unavailable.'; return }
    try {
        $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ($newLoginPath.Contains('"')) { throw 'invalid-path' }
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $newLoginPath
        if ([string]$config.codexAuthExecutable) {
            $cli = [string]$config.codexAuthExecutable
            if ($cli.Contains('"')) { throw 'invalid-path' }
            $arguments += ' -CodexAuthExecutable "{0}"' -f $cli
        }
        Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $installDirectory -WindowStyle Normal
        $panelStatus.Text = 'Login window opened | refresh after completion'
        Write-SafeLog -Level 'INFO' -Message 'New login window opened by user request.'
    } catch {
        $panelStatus.Text = 'Login window could not be opened.'
        Write-SafeLog -Level 'ERROR' -Message 'New login window could not be opened.'
    }
}

$application = [Windows.Application]::new()
$application.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown

$dragHandle.add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ([bool]$config.clickThrough -or $eventArgs.ChangedButton -ne [Windows.Input.MouseButton]::Left) { return }
    $eventArgs.Handled = $true
    try { $window.DragMove(); Save-OverlayPosition } catch { }
})
$codexButton.add_MouseLeftButtonUp({ param($sender, $eventArgs) $eventArgs.Handled = $true; Set-AccountsPanelExpanded -Expanded (-not $script:menuExpanded) })
$refreshButton.add_MouseLeftButtonUp({ param($sender, $eventArgs) $eventArgs.Handled = $true; $panelStatus.Text = 'Refreshing all accounts...'; Start-UsageRefresh })
$newLoginButton.add_MouseLeftButtonUp({ param($sender, $eventArgs) $eventArgs.Handled = $true; Start-NewLogin })
    $refreshButton.add_MouseEnter({ $refreshButton.Background = Get-Brush '#334F8EF7' })
    $refreshButton.add_MouseLeave({ $refreshButton.Background = Get-Brush '#263B82F6' })
$newLoginButton.add_MouseEnter({ $newLoginButton.Background = Get-Brush '#334F8EF7' })
$newLoginButton.add_MouseLeave({ $newLoginButton.Background = Get-Brush '#263B82F6' })

$showItem.add_Click({
    if ($window.IsVisible) { $window.Hide(); $showItem.Text = 'Show overlay' }
    else { $window.Show(); Position-Overlay; $showItem.Text = 'Hide overlay' }
})
$accountsItem.add_Click({
    if (-not $window.IsVisible) { $window.Show(); $showItem.Text = 'Hide overlay' }
    Set-AccountsPanelExpanded -Expanded (-not $script:menuExpanded)
})
$notifyIcon.add_MouseClick({ param($sender, $eventArgs) if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) { $showItem.PerformClick() } })
$refreshItem.add_Click({ $panelStatus.Text = 'Refreshing all accounts...'; Start-UsageRefresh })
$resetPositionItem.add_Click({
    try { Reset-OverlayPosition; Write-SafeLog -Level 'INFO' -Message 'Overlay position reset to top-right.' }
    catch { Write-SafeLog -Level 'ERROR' -Message 'Overlay position could not be reset.' }
})
$autostartItem.add_Click({
    try {
        if (Test-Autostart) { Disable-Autostart } else { Enable-Autostart }
        $autostartItem.Checked = Test-Autostart
        Write-SafeLog -Level 'INFO' -Message ('Autostart enabled={0}.' -f $autostartItem.Checked)
    } catch { Write-SafeLog -Level 'ERROR' -Message 'Autostart setting could not be changed.' }
})
$restartItem.add_Click({
    Write-SafeLog -Level 'INFO' -Message 'Restart requested from tray.'
    if (Test-Path -LiteralPath $restartScript -PathType Leaf) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"{0}"' -f $restartScript) -WindowStyle Hidden }
    $script:allowExit = $true; $application.Shutdown()
})
$exitItem.add_Click({ Write-SafeLog -Level 'INFO' -Message 'Exit requested from tray.'; $script:allowExit = $true; $application.Shutdown() })
$window.add_Closing({ param($sender, $eventArgs) if (-not $script:allowExit) { $eventArgs.Cancel = $true; $window.Hide(); $showItem.Text = 'Show overlay' } })

$uiTimer = [Windows.Threading.DispatcherTimer]::new()
$uiTimer.Interval = [TimeSpan]::FromSeconds(1)
$uiTimer.add_Tick({ Update-CountdownDisplay; Complete-UsageRefreshIfReady; Complete-AccountSwitchIfReady; Complete-AccountRemovalIfReady })
$refreshTimer = [Windows.Threading.DispatcherTimer]::new()
$refreshTimer.Interval = [TimeSpan]::FromSeconds($config.refreshSeconds)
$refreshTimer.add_Tick({ Start-UsageRefresh })
$script:outsideClickTimer = [Windows.Threading.DispatcherTimer]::new()
$script:outsideClickTimer.Interval = [TimeSpan]::FromMilliseconds(30)
$script:outsideClickTimer.add_Tick({
    if (-not $script:menuExpanded -or $script:overlayHandle -eq [IntPtr]::Zero) {
        $script:outsideClickTimer.Stop()
        $script:outsideClickMouseDown = $false
        return
    }
    if ([DateTime]::UtcNow -lt $script:outsideClickIgnoreUntilUtc -or (Test-AccountContextMenuOpen)) {
        $script:outsideClickMouseDown = $false
        return
    }
    try {
        $leftState = [int][CodexUsageOverlay.NativeMethods]::GetAsyncKeyState(0x01)
        $rightState = [int][CodexUsageOverlay.NativeMethods]::GetAsyncKeyState(0x02)
        $middleState = [int][CodexUsageOverlay.NativeMethods]::GetAsyncKeyState(0x04)
        $mouseDownNow = (($leftState -band 0x8000) -ne 0) -or (($rightState -band 0x8000) -ne 0) -or (($middleState -band 0x8000) -ne 0)
        $pressedSinceLastTick = (($leftState -band 1) -ne 0) -or (($rightState -band 1) -ne 0) -or (($middleState -band 1) -ne 0)
        $newPress = $pressedSinceLastTick -or ($mouseDownNow -and -not $script:outsideClickMouseDown)
        $script:outsideClickMouseDown = $mouseDownNow
        if (-not $newPress) { return }

        $point = [CodexUsageOverlay.NativeMethods+POINT]::new()
        $rect = [CodexUsageOverlay.NativeMethods+RECT]::new()
        if (-not [CodexUsageOverlay.NativeMethods]::GetCursorPos([ref]$point)) { return }
        if (-not [CodexUsageOverlay.NativeMethods]::GetWindowRect($script:overlayHandle, [ref]$rect)) { return }
        $inside = $point.X -ge $rect.Left -and $point.X -lt $rect.Right -and $point.Y -ge $rect.Top -and $point.Y -lt $rect.Bottom
        if (-not $inside) { Set-AccountsPanelExpanded -Expanded $false }
    } catch {
        # Click-away behavior is best effort and never logs cursor data.
    }
})

try {
    Write-SafeLog -Level 'INFO' -Message ('Overlay started; source=codex-auth-list-api refresh={0}s.' -f $config.refreshSeconds)
    Write-RuntimeStatus -Running $true -State 'starting'
    $uiTimer.Start(); $refreshTimer.Start(); Start-UsageRefresh
    $null = $application.Run($window)
} finally {
    $uiTimer.Stop(); $refreshTimer.Stop(); $script:outsideClickTimer.Stop()
    if ($script:refreshProcess -and $script:refreshProcess.HasExited) { $script:refreshProcess.Dispose() }
    if ($script:switchProcess -and $script:switchProcess.HasExited) { $script:switchProcess.Dispose() }
    if ($script:removeProcess -and $script:removeProcess.HasExited) { $script:removeProcess.Dispose() }
    Write-RuntimeStatus -Running $false -State 'stopped'
    $notifyIcon.Visible = $false; $notifyIcon.Dispose(); $contextMenu.Dispose(); $trayIcon.Dispose()
    Write-SafeLog -Level 'INFO' -Message 'Overlay stopped.'
    try { $instanceMutex.ReleaseMutex() } catch { }
    $instanceMutex.Dispose()
}
