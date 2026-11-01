<#
.SYNOPSIS
  Registers the SMC Cloud Watchdog as an automatic Windows Startup Task.
  Runs automatically on machine reboot or logon without having to manually start anything.
#>

$scriptPath = "C:\Users\Administrator\.gemini\antigravity\scratch\smc-synthetics-terminal\cloud_watchdog.ps1"
$taskName = "SMC_Auto_Cloud_Watchdog"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)

try {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "24/7 SMC Auto-Desk Trading Engine Watchdog" -User $env:USERNAME
  Write-Output "SUCCESS: Registered scheduled task '$taskName' to run 24/7 on boot."
} catch {
  Write-Output "Notice: Scheduled task requires administrator elevation. Creating shell startup shortcut instead..."
  $startupFolder = [Environment]::GetFolderPath("Startup")
  $shortcutFile = Join-Path $startupFolder "SMC_Auto_Watchdog.lnk"
  $wscript = New-Object -ComObject WScript.Shell
  $shortcut = $wscript.CreateShortcut($shortcutFile)
  $shortcut.TargetPath = "powershell.exe"
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
  $shortcut.WorkingDirectory = "C:\Users\Administrator\.gemini\antigravity\scratch\smc-synthetics-terminal"
  $shortcut.Save()
  Write-Output "SUCCESS: Created auto-start shortcut in Windows Startup folder: $shortcutFile"
}
