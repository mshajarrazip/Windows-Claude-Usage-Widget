#requires -Version 5.1
<#
  Claude Usage Widget
  A small desktop widget that shows how much of your Claude plan's usage
  limits you have used: the current 5-hour session and the weekly limits,
  the same figures as claude.ai > Settings > Usage.

  It reads the sign-in that Claude Code saved on this PC (read-only; it never
  changes it) and asks Anthropic for your current usage.

  Run:   double-click launch.vbs   (or: powershell -STA -ExecutionPolicy Bypass -File ClaudeUsageWidget.ps1)
  Use:   drag to move, right-click for options.

  Development switches:
    -DemoFile <json>   show usage from a saved JSON response instead of asking Anthropic
    -Snapshot <png>    render the widget once to a PNG file and exit (use with -DemoFile)
#>
param(
    [string]$DemoFile,
    [string]$Snapshot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$AppName      = 'ClaudeUsageWidget'
$DataDir      = Join-Path $env:LOCALAPPDATA $AppName
$SettingsPath = Join-Path $DataDir 'settings.json'
$LogPath      = Join-Path $DataDir 'error.log'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$UsagePageUrl = 'https://claude.ai/settings/usage'
$ClaudeDir    = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$CredPath     = Join-Path $ClaudeDir '.credentials.json'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Write-Log($msg) {
    try { Add-Content -Path $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format s), $msg) } catch {}
}

# ---------- single instance ----------
$mutexName = if ($DemoFile) { "Local\$AppName-demo" } else { "Local\$AppName" }
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit }

# ---------- settings ----------
$script:Settings = [pscustomobject]@{
    Left = $null; Top = $null
    Topmost = $false
    ShowPace = $true
    RefreshSeconds = 120
}
if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            if ($script:Settings.PSObject.Properties[$p.Name]) { $script:Settings.($p.Name) = $p.Value }
        }
    } catch { Write-Log "settings: $_" }
}
function Save-Settings {
    if ($Snapshot) { return }
    try { $script:Settings | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8 } catch { Write-Log "save: $_" }
}

# ---------- data collection (runs in a background runspace) ----------
# Returns one object: Ok, Usage (the API response), Plan, and on failure Kind + Error.
$Collector = {
    param([string]$CredPath, [string]$DemoFile)
    $ErrorActionPreference = 'Stop'
    $r = [pscustomobject]@{ Ok = $false; Usage = $null; Plan = $null; Kind = $null; Error = $null; RetryAfter = $null }

    if ($DemoFile) {
        try {
            $r.Usage = Get-Content -LiteralPath $DemoFile -Raw | ConvertFrom-Json
            $r.Plan = 'demo'; $r.Ok = $true
        } catch { $r.Kind = 'error'; $r.Error = $_.Exception.Message }
        return $r
    }

    # Claude Code's saved sign-in. Only read here; refreshing it is left to Claude Code.
    $oauth = $null
    try {
        if (Test-Path -LiteralPath $CredPath) {
            $oauth = (Get-Content -LiteralPath $CredPath -Raw | ConvertFrom-Json).claudeAiOauth
        }
    } catch { $oauth = $null }
    if (-not $oauth -or -not $oauth.accessToken) { $r.Kind = 'nocreds'; return $r }
    $r.Plan = $oauth.subscriptionType

    if ($oauth.expiresAt) {
        try {
            $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$oauth.expiresAt)
            if ($exp -lt [DateTimeOffset]::UtcNow) { $r.Kind = 'expired'; return $r }
        } catch {}
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{
            'Authorization'  = 'Bearer ' + $oauth.accessToken
            'anthropic-beta' = 'oauth-2025-04-20'
            'Accept'         = 'application/json'
        }
        $r.Usage = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers `
                       -UserAgent 'claude-usage-widget/1.0' -TimeoutSec 20 -UseBasicParsing
        $r.Ok = $true
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $r.Error = $_.Exception.Message
        $r.Kind = switch ($code) {
            401     { 'unauthorized' }
            403     { 'forbidden' }
            429     { 'ratelimited' }
            0       { 'network' }
            default { 'error' }
        }
        if ($code -eq 429 -and $resp.Headers['Retry-After']) {
            $s = 0; if ([int]::TryParse($resp.Headers['Retry-After'], [ref]$s)) { $r.RetryAfter = $s }
        }
    } catch {
        $r.Kind = 'error'; $r.Error = $_.Exception.Message
    }
    $r
}

# ---------- UI ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False"
        SizeToContent="Height" Width="290" FontFamily="Segoe UI">
  <Border x:Name="Card" Margin="12" CornerRadius="10" Background="#EB1E1F22"
          BorderBrush="#2EFFFFFF" BorderThickness="1" Padding="14,11,14,10">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.5" Color="Black"/>
    </Border.Effect>
    <StackPanel>
      <DockPanel Margin="0,0,0,4">
        <TextBlock x:Name="Updated" DockPanel.Dock="Right" Foreground="#73FFFFFF"
                   FontSize="11" VerticalAlignment="Center"/>
        <TextBlock x:Name="Glyph" FontFamily="Segoe MDL2 Assets" Foreground="#D97757"
                   FontSize="13" VerticalAlignment="Center" Margin="0,0,7,0"/>
        <TextBlock Text="Claude usage" Foreground="#E6FFFFFF" FontSize="12"
                   FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="Plan" Foreground="#73FFFFFF" FontSize="11" Margin="6,0,0,0"
                   VerticalAlignment="Center"/>
      </DockPanel>
      <StackPanel x:Name="Rows"/>
      <TextBlock x:Name="Notice" Foreground="#80FFFFFF" FontSize="12" Margin="0,4,0,2"
                 TextWrapping="Wrap" Text="Loading…"/>
    </StackPanel>
  </Border>
</Window>
'@

$window  = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$Card    = $window.FindName('Card')
$Rows    = $window.FindName('Rows')
$Notice  = $window.FindName('Notice')
$Updated = $window.FindName('Updated')
$PlanTxt = $window.FindName('Plan')
$window.FindName('Glyph').Text = [string][char]0xE9D2   # chart glyph

# The limits shown, in order. Weekly model-specific limits appear only when your plan has them.
$Limits = @(
    @{ Key = 'five_hour';        Label = 'Current session';      Hours = 5;   AlwaysShow = $true }
    @{ Key = 'seven_day';        Label = 'Weekly · all models';  Hours = 168; AlwaysShow = $true }
    @{ Key = 'seven_day_opus';   Label = 'Weekly · Opus';        Hours = 168 }
    @{ Key = 'seven_day_sonnet'; Label = 'Weekly · Sonnet';      Hours = 168 }
)

$RowTemplate = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Margin="0,6,0,4" ToolTip="{TIP}" Background="Transparent">
  <DockPanel>
    <TextBlock DockPanel.Dock="Right" Text="{PCT}%" Foreground="{COLOR}" FontSize="12"
               FontWeight="SemiBold" Margin="8,0,0,0"/>
    <TextBlock Text="{LABEL}" Foreground="#F2FFFFFF" FontSize="12" TextTrimming="CharacterEllipsis"/>
  </DockPanel>
  <Grid Height="10" Margin="0,3,0,0">
    <Border Height="6" CornerRadius="3" Background="#24FFFFFF"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="{P}*"/>
        <ColumnDefinition Width="{Q}*"/>
      </Grid.ColumnDefinitions>
      <Border Height="6" CornerRadius="3" Background="{COLOR}"/>
    </Grid>
    <Grid Visibility="{PACEVIS}">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="{T}*"/>
        <ColumnDefinition Width="{U}*"/>
      </Grid.ColumnDefinitions>
      <Border Width="2" HorizontalAlignment="Right" Margin="0,0,-1,0" CornerRadius="1" Background="#CCFFFFFF"/>
    </Grid>
  </Grid>
  <TextBlock Text="{SUB}" Foreground="#80FFFFFF" FontSize="11" Margin="0,2,0,0"/>
</StackPanel>
'@

function ConvertTo-LocalTime($v) {
    if ($null -eq $v -or '' -eq $v) { return $null }
    if ($v -is [datetime]) { return $v.ToLocalTime() }
    try { return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime }
    catch { return $null }
}

function Format-Reset($t) {
    if (-not $t) { return '' }
    $span = $t - (Get-Date)
    if ($span.TotalSeconds -le 0)   { return 'Resetting…' }
    if ($span.TotalMinutes -lt 60)  { return 'Resets in {0} min' -f [int][Math]::Max(1, [Math]::Ceiling($span.TotalMinutes)) }
    if ($span.TotalHours -lt 24)    { return 'Resets in {0} h {1} min' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
    'Resets ' + $t.ToString('ddd') + ' ' + $t.ToString('t')
}

function New-Row([string]$label, $pctValue, [string]$sub, [string]$tip, $elapsed) {
    $real = [double]$pctValue
    $pct  = [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $real)))
    $color = if ($real -ge 80) { '#FF6B6B' } elseif ($real -ge 50) { '#F5C542' } else { '#5FD068' }
    $showPace = $script:Settings.ShowPace -and $null -ne $elapsed
    $t = if ($showPace) { [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $elapsed * 100))) } else { 0 }
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $x = $RowTemplate.
        Replace('{TIP}', (& $esc $tip)).
        Replace('{PCT}', [string][int][Math]::Round($real)).
        Replace('{COLOR}', $color).
        Replace('{LABEL}', (& $esc $label)).
        Replace('{SUB}', (& $esc $sub)).
        Replace('{P}', $pct).
        Replace('{Q}', (100 - $pct)).
        Replace('{PACEVIS}', $(if ($showPace) { 'Visible' } else { 'Collapsed' })).
        Replace('{T}', $t).
        Replace('{U}', (100 - $t))
    [Windows.Markup.XamlReader]::Parse($x)
}

# ---------- state ----------
$script:LastResult = $null   # most recent fetch, successful or not
$script:LastGood   = $null   # most recent successful fetch
$script:LastGoodAt = $null
$script:SkipUntil  = [datetime]::MinValue

function Get-Problem($res) {
    switch ($res.Kind) {
        'nocreds'      { "Couldn't find a Claude Code sign-in on this PC. Install Claude Code, run claude and sign in with your Claude account." }
        'expired'      { 'Your Claude Code sign-in has expired. Open Claude Code once to renew it; the widget picks it up automatically.' }
        'unauthorized' { 'Claude didn''t accept the saved sign-in. Open Claude Code to renew it, or run /login there.' }
        'forbidden'    { 'This sign-in can''t read usage limits. In Claude Code, run /login and sign in with your Claude account.' }
        'ratelimited'  { 'Anthropic asked the widget to slow down. It will try again in a few minutes.' }
        'network'      { "Can't reach Anthropic right now. Check your internet connection." }
        default        { "Couldn't get usage: $($res.Error)" }
    }
}

function Show-Usage {
    $Rows.Children.Clear()
    $now = Get-Date
    $nextReset = $null

    if ($script:LastGood) {
        $u = $script:LastGood.Usage
        foreach ($l in $Limits) {
            $e = $u.($l.Key)
            if (-not $e -and -not $l.AlwaysShow) { continue }
            $pct = if ($e -and $null -ne $e.utilization) { [double]$e.utilization } else { 0 }
            $reset = if ($e) { ConvertTo-LocalTime $e.resets_at } else { $null }
            $elapsed = $null
            if ($reset) {
                $elapsed = 1 - (($reset - $now).TotalHours / $l.Hours)
                if (-not $nextReset -or $reset -lt $nextReset) { $nextReset = $reset }
            }
            $sub = if ($reset) { Format-Reset $reset }
                   elseif ($l.Key -eq 'five_hour') { 'No active session' }
                   else { '' }
            $tip = '{0}: {1}% used.' -f $l.Label, [Math]::Round($pct)
            if (-not $reset -and $l.Key -eq 'five_hour') { $tip += ' A new 5-hour session starts with your next message.' }
            if ($reset) { $tip += ' Resets ' + $reset.ToString('dddd') + ' at ' + $reset.ToString('t') + '.' }
            if ($null -ne $elapsed -and $script:Settings.ShowPace) {
                $tip += "`nThe white mark shows how much of this window has passed ({0}%). A bar past the mark means you're using it faster than the window refills." -f [Math]::Round([Math]::Max(0, [Math]::Min(1, $elapsed)) * 100)
            }
            try { [void]$Rows.Children.Add((New-Row $l.Label $pct $sub $tip $elapsed)) } catch { Write-Log "row: $_" }
        }

        $x = $u.extra_usage
        if ($x -and $x.is_enabled -and $null -ne $x.utilization) {
            $tip = 'Extra usage: {0}% of your monthly extra-usage limit used.' -f [Math]::Round([double]$x.utilization)
            try { [void]$Rows.Children.Add((New-Row 'Extra usage · this month' $x.utilization 'Billed beyond your plan' $tip $null)) } catch { Write-Log "row: $_" }
        }
    }

    # Plan name and the "last updated" time
    $plan = if ($script:LastResult -and $script:LastResult.Plan) { [string]$script:LastResult.Plan } else { '' }
    $PlanTxt.Text = if ($plan) { [Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($plan.ToLower()) } else { '' }

    $failed = $script:LastResult -and -not $script:LastResult.Ok
    if ($script:LastGoodAt) {
        $Updated.Text = $(if ($failed) { [string][char]0x26A0 + ' ' } else { '' }) + $script:LastGoodAt.ToShortTimeString()
        $Updated.Foreground = $(if ($failed) { '#F5C542' } else { '#73FFFFFF' })
        $Updated.ToolTip = 'Last updated ' + $script:LastGoodAt.ToString('t')
    } else { $Updated.Text = '' }

    if ($failed) {
        $msg = Get-Problem $script:LastResult
        if ($script:LastGood) { $msg = 'Showing figures from ' + $script:LastGoodAt.ToShortTimeString() + '. ' + $msg }
        $Notice.Text = $msg
        $Notice.Visibility = 'Visible'
    } elseif (-not $script:LastResult) {
        $Notice.Text = 'Loading…'; $Notice.Visibility = 'Visible'
    } else {
        $Notice.Visibility = 'Collapsed'
    }

    $script:NextReset = $nextReset
}

# ---------- background refresh ----------
$iss = [initialsessionstate]::CreateDefault()
$script:Runspace = [runspacefactory]::CreateRunspace($iss)
$script:Runspace.Open()
$script:PS = [powershell]::Create()
$script:PS.Runspace = $script:Runspace
$script:Pending = $null

function Start-Refresh([switch]$Manual) {
    if ($script:Pending) { return }
    if (-not $Manual -and (Get-Date) -lt $script:SkipUntil) { return }
    $script:PS.Commands.Clear()
    [void]$script:PS.AddScript($Collector).AddArgument($CredPath).AddArgument($DemoFile)
    $script:Pending = $script:PS.BeginInvoke()
}

$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(400)
$poll.Add_Tick({
    if ($script:Pending -and $script:Pending.IsCompleted) {
        try {
            $res = @($script:PS.EndInvoke($script:Pending)) | Where-Object { $_ } | Select-Object -Last 1
            if (-not $res) { $res = [pscustomobject]@{ Ok = $false; Kind = 'error'; Error = 'no response'; Plan = $null } }
            $script:LastResult = $res
            if ($res.Ok) {
                $script:LastGood = $res; $script:LastGoodAt = Get-Date
                $script:SkipUntil = [datetime]::MinValue
            } elseif ($res.Kind -eq 'ratelimited') {
                $wait = if ($res.RetryAfter) { [Math]::Max(60, [int]$res.RetryAfter) } else { 300 }
                $script:SkipUntil = (Get-Date).AddSeconds($wait)
            } else {
                Write-Log ("fetch: {0} {1}" -f $res.Kind, $res.Error)
            }
            Show-Usage
        } catch { Write-Log "refresh: $_" }
        finally { $script:Pending = $null }
        if ($Snapshot) { Save-Snapshot }
    }
})
$poll.Start()

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(60, [int]$script:Settings.RefreshSeconds))
$timer.Add_Tick({ Start-Refresh })
$timer.Start()

# Keep the countdowns current between fetches, and fetch right after a limit resets
$script:NextReset = $null
$clock = New-Object System.Windows.Threading.DispatcherTimer
$clock.Interval = [TimeSpan]::FromSeconds(30)
$clock.Add_Tick({
    if ($script:NextReset -and (Get-Date) -gt $script:NextReset.AddSeconds(20)) {
        $script:NextReset = $null; Start-Refresh
    }
    if ($script:LastGood) { Show-Usage }
})
$clock.Start()

# ---------- snapshot (development) ----------
function Save-Snapshot {
    $window.Dispatcher.BeginInvoke([Action]{
        try {
            $el = $window.Content
            $el.UpdateLayout()
            $w = [int][Math]::Ceiling($el.ActualWidth + 24); $h = [int][Math]::Ceiling($el.ActualHeight + 24)
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ($w * 2), ($h * 2), 192, 192, ([System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($window)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
        } catch { Write-Log "snapshot: $_" }
        $window.Close()
    }, [System.Windows.Threading.DispatcherPriority]::ContextIdle) | Out-Null
}

# ---------- start with Windows ----------
function Set-Startup([bool]$enable) {
    if (-not $enable) { Remove-Item -LiteralPath $StartupLnk -ErrorAction SilentlyContinue; return }
    # Keep a stable copy under %LOCALAPPDATA% so startup doesn't depend on where this file lives
    $srcDir = Split-Path -Parent $PSCommandPath
    if ($srcDir -ne $DataDir) {
        foreach ($f in 'ClaudeUsageWidget.ps1', 'launch.vbs', 'icon.ico') {
            $src = Join-Path $srcDir $f
            if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $DataDir $f) -Force }
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartupLnk)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $DataDir 'launch.vbs') + '"'
    $lnk.WorkingDirectory = $DataDir
    $icon = Join-Path $DataDir 'icon.ico'
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Description = 'How much of your Claude usage limits you have used'
    $lnk.Save()
}

# ---------- context menu ----------
function New-MenuItem($header, [bool]$checkable = $false, [bool]$checked = $false) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    $mi.IsCheckable = $checkable
    $mi.IsChecked = $checked
    $mi
}
$menu = New-Object System.Windows.Controls.ContextMenu
$miRefresh = New-MenuItem 'Refresh now'
$miOpen    = New-MenuItem 'Open usage page on claude.ai'
$miPace    = New-MenuItem 'Show time markers' $true ([bool]$script:Settings.ShowPace)
$miTopmost = New-MenuItem 'Always on top' $true ([bool]$script:Settings.Topmost)
$miStartup = New-MenuItem 'Start with Windows' $true (Test-Path $StartupLnk)
$miExit    = New-MenuItem 'Close widget'
foreach ($i in $miRefresh, $miOpen) { [void]$menu.Items.Add($i) }
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
foreach ($i in $miPace, $miTopmost, $miStartup) { [void]$menu.Items.Add($i) }
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($miExit)
$Card.ContextMenu = $menu

$miRefresh.Add_Click({ $Updated.Text = '…'; Start-Refresh -Manual })
$miOpen.Add_Click({ try { Start-Process $UsagePageUrl } catch { Write-Log "open: $_" } })
$miPace.Add_Click({
    $script:Settings.ShowPace = $miPace.IsChecked; Save-Settings; Show-Usage
})
$miTopmost.Add_Click({
    $script:Settings.Topmost = $miTopmost.IsChecked; $window.Topmost = $miTopmost.IsChecked; Save-Settings
})
$miStartup.Add_Click({
    try { Set-Startup $miStartup.IsChecked }
    catch {
        Write-Log "startup: $_"
        $miStartup.IsChecked = (Test-Path $StartupLnk)
        [System.Windows.MessageBox]::Show("Couldn't update the startup setting:`n$_", 'Claude Usage') | Out-Null
    }
})
$miExit.Add_Click({ $window.Close() })

# ---------- window behaviour ----------
$Card.Add_MouseLeftButtonDown({
    try { $window.DragMove() } catch {}
    $script:Settings.Left = [int]$window.Left
    $script:Settings.Top  = [int]$window.Top
    Save-Settings
})

# Hide from Alt+Tab (tool window style)
if (-not ('CUW.Native' -as [type])) {
    Add-Type -Namespace CUW -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@
}
$window.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $ex = [CUW.Native]::GetWindowLong($h, -20)
    [void][CUW.Native]::SetWindowLong($h, -20, ($ex -bor 0x80))   # WS_EX_TOOLWINDOW
})

# Initial position: saved spot if it's still on screen, else top-right of the work area
$vs = [System.Windows.SystemParameters]
$wa = $vs::WorkArea
$window.WindowStartupLocation = 'Manual'
$left = $script:Settings.Left; $top = $script:Settings.Top
if ($null -ne $left -and $null -ne $top -and
    $left -ge $vs::VirtualScreenLeft - 50 -and $left -le ($vs::VirtualScreenLeft + $vs::VirtualScreenWidth - 80) -and
    $top  -ge $vs::VirtualScreenTop - 20  -and $top  -le ($vs::VirtualScreenTop + $vs::VirtualScreenHeight - 60)) {
    $window.Left = $left; $window.Top = $top
} else {
    $window.Left = $wa.Right - $window.Width - 8
    $window.Top  = $wa.Top + 8
}
$window.Topmost = [bool]$script:Settings.Topmost
if ($Snapshot) { $window.Left = $vs::VirtualScreenLeft - 2000; $window.ShowActivated = $false }

$window.Add_Closed({
    $poll.Stop(); $timer.Stop(); $clock.Stop()
    try { $script:PS.Dispose(); $script:Runspace.Dispose() } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
})

Start-Refresh -Manual
try {
    [void]$window.ShowDialog()
} catch {
    Write-Log "fatal: $_"
    throw
}
