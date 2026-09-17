<#
  CampusNetAutoLogin - set / update the portal password.
  The password is encrypted with Windows DPAPI (user scope) and stored in cred.dat.
#>
$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CredPath   = Join-Path $Root 'cred.dat'
$ConfigPath = Join-Path $Root 'config.json'

Write-Host ''
Write-Host '========================================================='
Write-Host '  Campus network auto login : password setup'
Write-Host '========================================================='
Write-Host ''

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Write-Host ('  Portal   : ' + $cfg.portal)
Write-Host ('  Username : ' + $cfg.username)
Write-Host ''

$u = Read-Host ('  Username [Enter = keep ' + $cfg.username + ']')
if (-not [string]::IsNullOrWhiteSpace($u)) {
    $cfg.username = $u.Trim()
    ($cfg | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Host ('  -> username updated to ' + $cfg.username)
}

$s1 = Read-Host '  Password (hidden)'
$s2 = Read-Host '  Password again  '

$a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2)
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($a)
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)

if ([string]::IsNullOrEmpty($p1)) {
    Write-Host '  ERROR: empty password, nothing saved.' -ForegroundColor Red
    exit 1
}
if ($p1 -ne $p2) {
    Write-Host '  ERROR: the two entries do not match, nothing saved.' -ForegroundColor Red
    exit 1
}
$p1 = $null; $p2 = $null

$s1 | ConvertFrom-SecureString | ForEach-Object { [IO.File]::WriteAllText($CredPath, $_) }
$s1 = $null; $s2 = $null

Write-Host ''
Write-Host '  OK - password encrypted with Windows DPAPI and saved to:' -ForegroundColor Green
Write-Host ('       ' + $CredPath) -ForegroundColor Green
Write-Host '  Only this Windows user on this machine can decrypt it.' -ForegroundColor Green
Write-Host ''
exit 0
