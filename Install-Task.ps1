<#
  CampusNetAutoLogin - register the scheduled task.
  Triggers : at logon (+20s), at unlock, and every 5 minutes as a watchdog.
  Action   : wscript.exe launcher.vbs  -> fully hidden, no console flash.
#>
$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$TaskName = 'CampusNetAutoLogin'
$User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Vbs      = Join-Path $Root 'launcher.vbs'
$Start    = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss')

if (-not (Test-Path -LiteralPath $Vbs)) { throw "launcher.vbs not found at $Vbs" }

$xml = @"
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$User</Author>
    <Description>Campus network auto login - signs in to the portal at logon, on unlock and every 5 minutes.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$User</UserId>
      <Delay>PT20S</Delay>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <UserId>$User</UserId>
      <StateChange>SessionUnlock</StateChange>
    </SessionStateChangeTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>$Start</StartBoundary>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$User</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>"$Vbs"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host ("Task registered : " + $t.TaskName)
Write-Host ("State           : " + $t.State)
Write-Host ("Triggers        : " + $t.Triggers.Count)
Write-Host ("Action          : " + $t.Actions[0].Execute + ' ' + $t.Actions[0].Arguments)
