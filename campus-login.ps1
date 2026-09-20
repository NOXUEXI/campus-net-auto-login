<#
  CampusNetAutoLogin - campus portal auto login (unified auth portal)
  ------------------------------------------------------------------
  Source is intentionally ASCII-only so that Windows PowerShell 5.1
  reads it correctly regardless of the system ANSI code page.

  Endpoints used (reverse engineered from the portal front-end):
    GET  /api/account/status   -> {code, online{...}, enableDial, dialCode, dialMsg}
    POST /api/account/login    -> {code:0 ok | 1 fail | 2 captcha}
    POST /api/account/redial   -> trigger PPPoE dial
#>
[CmdletBinding()]
param(
    [switch]$Force,       # log even when already online
    [switch]$Status,      # print a status summary and exit
    [switch]$ForceLogin,  # skip the "already online" shortcut and really submit credentials
    [switch]$WifiDiag     # print the wifi / SSID diagnosis and exit (read-only)
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $Root 'config.json'
$CredPath   = Join-Path $Root 'cred.dat'
$StatePath  = Join-Path $Root 'state.json'
$LogPath    = Join-Path $Root 'login.log'
$MaxLogLines = 1000    # every run now writes one line, so keep more history

# ------------------------------------------------------- single instance
$script:Mutex = $null
try {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\CampusNetAutoLogin')
    if (-not $script:Mutex.WaitOne(0)) { exit 0 }
} catch { }

# ------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
        $all = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
        if ($all.Count -gt $MaxLogLines) {
            $all | Select-Object -Last 600 | Set-Content -LiteralPath $LogPath -Encoding UTF8
        }
    } catch { }
}

function Get-State {
    if (Test-Path -LiteralPath $StatePath) {
        try { return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Set-State {
    param([hashtable]$Values)
    $cur = @{}
    $old = Get-State
    if ($old) { foreach ($p in $old.PSObject.Properties) { $cur[$p.Name] = $p.Value } }
    foreach ($k in $Values.Keys) { $cur[$k] = $Values[$k] }
    try { ($cur | ConvertTo-Json) | Set-Content -LiteralPath $StatePath -Encoding UTF8 } catch { }
}

# throttle repeated warnings so the log does not explode when off-campus
function Test-Throttle {
    param([string]$Key, [int]$Minutes)
    $st = Get-State
    if ($st -and $st.$Key) {
        try {
            if (((Get-Date) - [datetime]$st.$Key).TotalMinutes -lt $Minutes) { return $false }
        } catch { }
    }
    Set-State @{ $Key = (Get-Date).ToString('s') }
    return $true
}

# ------------------------------------------------------------ http core
$script:BaseUrl = ''

function Invoke-Portal {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Body,
        [int]$TimeoutSec = 8
    )
    $url = $script:BaseUrl.TrimEnd('/') + $Path
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
    $req.Method             = $Method
    $req.Timeout            = $TimeoutSec * 1000
    $req.ReadWriteTimeout   = $TimeoutSec * 1000
    $req.Proxy              = $null          # bypass any system / session proxy
    $req.KeepAlive          = $false
    $req.AllowAutoRedirect  = $false
    $req.UserAgent          = 'Mozilla/5.0 CampusAutoLogin/1.0'

    if ($Body -and $Body.Count -gt 0) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($k in $Body.Keys) {
            if ($null -eq $Body[$k]) { continue }
            if ($sb.Length -gt 0) { [void]$sb.Append('&') }
            [void]$sb.Append([Uri]::EscapeDataString($k))
            [void]$sb.Append('=')
            [void]$sb.Append([Uri]::EscapeDataString([string]$Body[$k]))
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $req.ContentType   = 'application/x-www-form-urlencoded; charset=UTF-8'
        $req.ContentLength = $bytes.Length
        $ws = $req.GetRequestStream()
        $ws.Write($bytes, 0, $bytes.Length)
        $ws.Close()
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }

    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()

    if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty response from portal' }
    return ($text | ConvertFrom-Json)
}

function Get-Status {
    return (Invoke-Portal -Method GET -Path '/api/account/status')
}

# wait for the operator/PPPoE dial to settle, mirroring the portal page
function Wait-Dial {
    param($Cfg, $Initial)
    $tries = 12; $gap = 3
    if ($Cfg.dialMaxTries)    { $tries = [int]$Cfg.dialMaxTries }
    if ($Cfg.dialWaitSeconds) { $gap   = [int]$Cfg.dialWaitSeconds }
    $s = $Initial
    for ($i = 1; $i -le $tries; $i++) {
        if ($s -and $s.enableDial -ne $true) { return $s }
        if ($s -and $s.dialCode -eq 'ok:dialup') { return $s }
        if ($s -and $s.dialCode -ne '' -and $s.dialCode -ne $null) { return $s }
        Start-Sleep -Seconds $gap
        try { $s = Get-Status } catch { return $s }
    }
    return $s
}

# ----------------------------------------------------------- credential
function Get-PlainPassword {
    # [IO.File]::ReadAllText + Trim: a trailing newline in cred.dat would make
    # ConvertTo-SecureString fail with a format error.
    $sec  = ConvertTo-SecureString ([IO.File]::ReadAllText($CredPath).Trim())
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Show-Notify {
    param([string]$Title, [string]$Text)
    try {
        $st = Get-State
        if ($st -and $st.lastNotify) {
            if (((Get-Date) - [datetime]$st.lastNotify).TotalMinutes -lt 30) { return }
        }
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.Visible = $true
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText  = $Text
        $ni.ShowBalloonTip(15000)
        Start-Sleep -Seconds 8
        $ni.Dispose()
        Set-State @{ lastNotify = (Get-Date).ToString('s') }
    } catch { }
}

# The portal sometimes demands a captcha (login answer code 2). Nothing can be
# automated past that point, but we can put the login page in front of the user
# so it takes two clicks instead of remembering the URL. Throttled hard so it
# never turns into a window spam.
function Show-PortalPage {
    param([int]$CooldownMinutes = 30)
    if (-not (Test-Throttle 'lastOpenPortal' $CooldownMinutes)) { return }
    try {
        Start-Process $script:BaseUrl | Out-Null
        Write-Log ('opened portal page in browser: ' + $script:BaseUrl)
    } catch { }
}

# ------------------------------------------------------------------ wifi
# The other classic way this tool "breaks": Windows also has autoconnect on
# for a phone hotspot or some other familiar network, so the laptop boots
# straight onto that one. There IS internet, the portal is simply not there,
# and the machine never comes back to the campus SSID on its own.
#
# Fix: check the SSID before probing the portal. Switching is guarded by four
# conditions, because this laptop also travels (hotel / library / phone
# hotspots are all saved profiles) and blindly forcing the campus SSID would
# kill a perfectly good connection somewhere else:
#   1. wifiAutoSwitch is on
#   2. we are still inside the boot window (default 15 min)
#   3. the campus profile is actually saved
#   4. the campus SSID is currently visible, i.e. we really are on campus
function Get-BootMinutes {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [double]((Get-Date) - $os.LastBootUpTime).TotalMinutes
    } catch { return -1 }
}

function Get-CurrentSsid {
    try { $out = @(& netsh wlan show interfaces 2>$null) } catch { return '' }
    foreach ($l in $out) {
        if ($l -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Test-WlanAdapter {
    try {
        $a = @(Get-NetAdapter -Physical -ErrorAction Stop |
               Where-Object { $_.MediaType.ToString() -like '*802*' })
        return ($a.Count -gt 0)
    } catch { return $false }
}

function Test-SsidProfile {
    param([string]$Name)
    # Exact value comparison after the colon. A substring test would happily
    # match "C" against "Campus-A" and report a profile that does not exist.
    try {
        $out = @(& netsh wlan show profiles 2>$null)
        foreach ($l in $out) {
            if ($l -match ':\s*([^:]+?)\s*$') {
                if ($Matches[1] -eq $Name) { return $true }
            }
        }
    } catch { }
    return $false
}

function Test-SsidVisible {
    param([string]$Name)
    try {
        $out = @(& netsh wlan show networks 2>$null)
        foreach ($l in $out) {
            if ($l -match '^\s*SSID\s+\d+\s*:\s*(.+?)\s*$') {
                if ($Matches[1] -eq $Name) { return $true }
            }
        }
    } catch { }
    return $false
}

function Connect-Ssid {
    param([string]$Name, [int]$WaitSeconds = 25)
    $arg = 'name="' + $Name + '"'
    try { & netsh wlan connect $arg | Out-Null } catch { }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if ((Get-CurrentSsid) -eq $Name) { return $true }
    }
    return $false
}

# One throttled channel for all wifi warnings: this runs every 5 minutes and
# a laptop parked off campus would otherwise fill the log.
function Write-WifiWarn {
    param([string]$Message, [int]$Minutes = 30)
    if (Test-Throttle 'lastWifiWarn' $Minutes) { Write-Log $Message 'WARN' }
}

function Ensure-Wifi {
    param($Cfg)

    # NOTE: build this with an explicit loop, never a pipeline. A pipeline that
    # yields exactly one item collapses to a scalar string, and $want[0] would
    # then return the first *character* - "C" out of "Campus-A". That bug is
    # invisible while the expected SSID is already connected, and only shows up
    # the moment a switch is actually needed.
    $want = @()
    foreach ($w in @($Cfg.wifiSsid)) {
        if (-not [string]::IsNullOrWhiteSpace($w)) { $want += [string]$w }
    }
    if ($want.Count -eq 0) { return }

    $cur = Get-CurrentSsid
    if ($want -contains $cur) { return }

    $where = 'none'
    if (-not [string]::IsNullOrEmpty($cur)) { $where = $cur }
    $list  = $want -join ', '

    if (-not (Test-WlanAdapter)) {
        Write-WifiWarn ('wifi: on "' + $where + '", expected one of [' + $list + '] - no WLAN adapter, skipping')
        return
    }

    $auto = $true
    if ($null -ne $Cfg.wifiAutoSwitch) { $auto = [bool]$Cfg.wifiAutoSwitch }
    if (-not $auto) {
        Write-WifiWarn ('wifi: on "' + $where + '", expected one of [' + $list + '] - auto switching disabled')
        return
    }

    $window = 15
    if ($Cfg.wifiFixWindowMinutes) { $window = [int]$Cfg.wifiFixWindowMinutes }
    $boot = Get-BootMinutes
    if ($boot -lt 0 -or $boot -gt $window) {
        $b = 'unknown'
        if ($boot -ge 0) { $b = [string][int]$boot }
        Write-WifiWarn ('wifi: on "' + $where + '", expected one of [' + $list + ']; boot +' + $b + ' min is outside the ' + $window + ' min fix window - not switching')
        return
    }

    $target = [string]$want[0]
    if (-not (Test-SsidProfile $target)) {
        Write-WifiWarn ('wifi: no saved profile for "' + $target + '" - cannot switch')
        return
    }
    if (-not (Test-SsidVisible $target)) {
        Write-WifiWarn ('wifi: "' + $target + '" is not in range - not switching (off campus?)')
        return
    }

    $wait = 25
    if ($Cfg.wifiWaitSeconds) { $wait = [int]$Cfg.wifiWaitSeconds }
    Write-Log ('wifi: on "' + $where + '", switching to "' + $target + '"')
    if (Connect-Ssid -Name $target -WaitSeconds $wait) {
        Write-Log ('wifi: connected to "' + $target + '"')
    } else {
        Write-Log ('wifi: could not connect to "' + $target + '" within ' + $wait + 's') 'WARN'
    }
}

# ================================================================ main
try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log 'config.json not found - aborting' 'ERROR'
        exit 2
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $script:BaseUrl = [string]$cfg.portal

    # --- wifi diagnosis (read-only) ----------------------------------------
    # Deliberately placed before Ensure-Wifi so that -WifiDiag never touches
    # the network. Answers "why is it not switching?" in one command.
    if ($WifiDiag) {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        $want = @()
        foreach ($w in @($cfg.wifiSsid)) {
            if (-not [string]::IsNullOrWhiteSpace($w)) { $want += [string]$w }
        }
        Write-Host ('current ssid  : [' + (Get-CurrentSsid) + ']')
        Write-Host ('expected ssid : [' + ($want -join ', ') + ']')
        Write-Host ('wlan adapter  : ' + (Test-WlanAdapter))
        Write-Host ('boot minutes  : ' + [int](Get-BootMinutes))
        Write-Host ('auto switch   : ' + $cfg.wifiAutoSwitch)
        Write-Host ('fix window    : ' + $cfg.wifiFixWindowMinutes + ' min')
        Write-Host ('wait seconds  : ' + $cfg.wifiWaitSeconds)
        if ($want.Count -eq 0) {
            Write-Host 'note          : wifiSsid is empty - wifi checking is disabled'
        } else {
            foreach ($w in $want) {
                Write-Host ('  profile "' + $w + '" saved   : ' + (Test-SsidProfile $w))
                Write-Host ('  profile "' + $w + '" visible : ' + (Test-SsidVisible $w))
            }
        }
        exit 0
    }

    # --- wifi sanity -------------------------------------------------------
    # Must run BEFORE the reachability probe: on the wrong SSID the portal is
    # unreachable by definition, and spending 150s waiting for it would only
    # burn the boot window. Skipped under -Status so that a pure "show me"
    # invocation never changes the machine's network state.
    if (-not $Status) { Ensure-Wifi -Cfg $cfg }

    # --- reachability ------------------------------------------------------
    # A cold boot can take well over a minute before the portal answers: Wi-Fi
    # association, DHCP and the PPPoE dial all have to settle first. The old
    # 6 x 5s window was too short, so the logon-time run gave up and the
    # machine sat offline until the next 5 minute watchdog tick. Probe for
    # about 150s instead.
    $reachTries = 30
    $reachGap   = 5
    if ($cfg.reachRetries)    { $reachTries = [int]$cfg.reachRetries }
    if ($cfg.reachGapSeconds) { $reachGap   = [int]$cfg.reachGapSeconds }
    $st = $null
    $lastErr = ''
    for ($i = 1; $i -le $reachTries; $i++) {
        try { $st = Get-Status; break }
        catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds $reachGap }
    }
    if (-not $st) {
        if (Test-Throttle 'lastUnreachable' 30) {
            Write-Log ("portal unreachable after " + $reachTries + " tries x " + $reachGap + "s: " + $lastErr) 'WARN'
        }
        Write-Log ('run: portal unreachable, gave up after ' + $reachTries + ' tries') 'WARN'
        exit 3
    }

    if ($Status) {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        Write-Host ('portal      : ' + $script:BaseUrl)
        Write-Host ('code        : ' + $st.code)
        Write-Host ('msg         : ' + $st.msg)
        Write-Host ('enableDial  : ' + $st.enableDial)
        Write-Host ('dialCode    : ' + $st.dialCode)
        Write-Host ('dialMsg     : ' + $st.dialMsg)
        if ($st.online) {
            Write-Host ('username    : ' + $st.online.Username)
            Write-Host ('name        : ' + $st.online.Name)
            Write-Host ('ip          : ' + $st.online.UserIpv4)
            Write-Host ('since       : ' + $st.online.AddTime)
        }
        exit 0
    }

    # --- already authenticated? ------------------------------------
    $onlineNow = ($st.code -eq 0 -and $st.online -and $st.online.UserIpv4)

    if ($onlineNow -and -not $ForceLogin) {
        if ($st.enableDial -eq $true -and $st.dialCode -ne 'ok:dialup') {
            Write-Log ('authenticated but dial=' + $st.dialCode + ' msg=' + $st.dialMsg) 'WARN'
            if ([string]::IsNullOrEmpty($st.dialCode)) { $st = Wait-Dial -Cfg $cfg -Initial $st }
            if ($st.dialCode -ne 'ok:dialup') {
                Write-Log 'sending redial'
                try { Invoke-Portal -Method POST -Path '/api/account/redial' | Out-Null } catch { }
                $st = Wait-Dial -Cfg $cfg -Initial $null
            }
            if ($st -and $st.dialCode -eq 'ok:dialup') { Write-Log 'dial OK'; exit 0 }
            Write-Log ('dial still failing: ' + $st.dialCode + ' ' + $st.dialMsg) 'WARN'
            exit 0
        }
        if ($Force) { Write-Log 'already online - nothing to do' }
        else { Write-Log ('run: online, dial=' + $st.dialCode + ', ip=' + $st.online.UserIpv4) }
        exit 0
    }

    # --- need to log in -------------------------------------------
    if ($onlineNow) { Write-Log 'ForceLogin: currently online, submitting credentials anyway (test mode)' }

    if (-not (Test-Path -LiteralPath $CredPath)) {
        if (Test-Throttle 'lastNoCred' 30) {
            Write-Log 'offline and no stored credential (run Setup-Password.cmd)' 'ERROR'
        }
        Show-Notify 'Campus network: password not set' 'Run Setup-Password.cmd in the CampusNetAutoLogin folder.'
        exit 4
    }

    $pwd = $null
    try { $pwd = Get-PlainPassword }
    catch {
        Write-Log 'cannot decrypt cred.dat (Windows profile changed?)' 'ERROR'
        Show-Notify 'Campus network: credential broken' 'Please run Setup-Password.cmd again.'
        exit 4
    }

    $body = @{
        username = [string]$cfg.username
        password = $pwd
        nasId    = [string]$cfg.nasId
    }
    if ($cfg.switchip) { $body['switchip'] = [string]$cfg.switchip }

    # optional pre-check, same as the portal page does
    try {
        $chk = Invoke-Portal -Method POST -Path '/api/account/check' -Body $body
        if ($chk.code -eq 0 -and $chk.isChangePwd -eq 1) {
            Write-Log 'account requires password change - manual login needed' 'ERROR'
            Show-Notify 'Campus network' 'Your password must be changed. Please log in manually once.'
            $pwd = $null
            exit 5
        }
    } catch { }

    try { $res = Invoke-Portal -Method POST -Path '/api/account/login' -Body $body }
    finally { $pwd = $null }

    switch ([int]$res.code) {
        0 {
            Write-Log ('login OK as ' + $cfg.username)
            $st2 = Wait-Dial -Cfg $cfg -Initial $null
            if ($st2 -and $st2.dialCode -eq 'ok:dialup') { Write-Log 'dial OK' }
            elseif ($st2 -and $st2.enableDial -eq $true) {
                Write-Log ('dial not confirmed: ' + $st2.dialCode + ' ' + $st2.dialMsg) 'WARN'
                try { Invoke-Portal -Method POST -Path '/api/account/redial' | Out-Null; Write-Log 'redial sent' } catch { }
            }
            $dialNow = 'unknown'
            if ($st2) { $dialNow = [string]$st2.dialCode }
            Write-Log ('run: logged in, dial=' + $dialNow)
            exit 0
        }
        1 {
            Write-Log ('login FAILED: ' + $res.msg) 'ERROR'
            Show-Notify 'Campus network login failed' ([string]$res.msg)
            exit 5
        }
        2 {
            Write-Log 'login requires a captcha - manual login needed' 'ERROR'
            Show-Notify 'Campus network' 'Portal is asking for a captcha. The login page has been opened - please finish it by hand.'
            Show-PortalPage
            exit 6
        }
        default {
            Write-Log ('unexpected login response: ' + ($res | ConvertTo-Json -Compress)) 'ERROR'
            exit 7
        }
    }
}
catch {
    Write-Log ('UNHANDLED: ' + $_.Exception.Message) 'ERROR'
    exit 1
}
finally {
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
}
