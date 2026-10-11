# Registers the logon-triggered reverse-tunnel scheduled task and starts it (no admin needed).
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 reads BOM-less files as ANSI.
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Cmd)
$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$Cmd`""
$t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
     -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $Name -Action $a -Trigger $t -Settings $s -Force | Out-Null
Start-ScheduledTask -TaskName $Name
(Get-ScheduledTask $Name).State
