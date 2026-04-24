[CmdletBinding()]
param(
  [string]$TaskName = 'Ipelabor Planka Daily Backup',
  [datetime]$DailyAt = (Get-Date '20:00'),
  [string]$LocalBackupRoot = (Join-Path $PSScriptRoot 'backups'),
  [string]$ArchiveDestinationRoot = 'G:\Meu Drive\Shared\Ipelabor\Planka'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backupScriptPath = Join-Path $PSScriptRoot 'Backup-Planka.ps1'

if (!(Test-Path -LiteralPath $backupScriptPath)) {
  throw "Backup script not found: $backupScriptPath"
}

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskArguments = @(
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  ('"{0}"' -f $backupScriptPath),
  '-LocalBackupRoot',
  ('"{0}"' -f $LocalBackupRoot),
  '-ArchiveDestinationRoot',
  ('"{0}"' -f $ArchiveDestinationRoot)
) -join ' '

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArguments
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType InteractiveToken -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Principal $principal `
  -Settings $settings `
  -Description 'Creates a daily Planka backup at 20:00 and moves it to Google Drive.' `
  -Force | Out-Null

Write-Host "Scheduled task '$TaskName' registered for daily execution at $($DailyAt.ToString('HH:mm'))."
Write-Host 'Note: the task runs under the current interactive user so the mapped G: drive remains available.'
