<#
  CampusNetAutoLogin - campus portal auto login (WUST unified auth)
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
    [switch]$ForceLogin   # skip the "already online" shortcut and really submit credentials
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $Root 'config.json'
$CredPath   = Join-Path $Root 'cred.dat'
$StatePath  = Join-Path $Root 'state.json'
$LogPath    = Join-Path $Root 'login.log'
$MaxLogLines = 400

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
            $all | Select-Object -Last 250 | Set-Content -LiteralPath $LogPath -Encoding UTF8
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
    # [IO.File]::ReadAllText + Trim: cred.dat 结尾若带换行，ConvertTo-SecureString 会报格式错误
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

# ================================================================ main
try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log 'config.json not found - aborting' 'ERROR'
        exit 2
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $script:BaseUrl = [string]$cfg.portal

    # --- reachability, with a few retries (Wi-Fi may still be coming up) ---
    $st = $null
    $lastErr = ''
    for ($i = 1; $i -le 6; $i++) {
        try { $st = Get-Status; break }
        catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 5 }
    }
    if (-not $st) {
        if (Test-Throttle 'lastUnreachable' 30) {
            Write-Log ("portal unreachable: " + $lastErr) 'WARN'
        }
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
            exit 0
        }
        1 {
            Write-Log ('login FAILED: ' + $res.msg) 'ERROR'
            Show-Notify 'Campus network login failed' ([string]$res.msg)
            exit 5
        }
        2 {
            Write-Log 'login requires a captcha - manual login needed' 'ERROR'
            Show-Notify 'Campus network' 'Portal is asking for a captcha. Please log in manually once.'
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
