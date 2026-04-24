[CmdletBinding()]
param(
  [string]$DailyTaskName = 'Ipelabor Planka Daily Incremental Backup',
  [string]$WeeklyTaskName = 'Ipelabor Planka Weekly Full Backup',
  [datetime]$DailyAt = (Get-Date '20:00'),
  [datetime]$WeeklyAt = (Get-Date '21:00'),
  [string]$LocalBackupRoot,
  [string]$ArchiveDestinationRoot = 'G:\Meu Drive\Shared\Ipelabor\Planka'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
  $PSScriptRoot
} elseif ($PSCommandPath) {
  Split-Path -Path $PSCommandPath -Parent
} else {
  (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($LocalBackupRoot)) {
  $LocalBackupRoot = Join-Path $scriptRoot 'backups'
}

$backupScriptPath = Join-Path $scriptRoot 'Backup-Planka.ps1'

if (!(Test-Path -LiteralPath $backupScriptPath)) {
  throw "Backup script not found: $backupScriptPath"
}

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function New-BackupTaskAction {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Full', 'Incremental')]
    [string]$Mode
  )

  $taskArguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ('"{0}"' -f $backupScriptPath),
    '-Mode',
    $Mode,
    '-LocalBackupRoot',
    ('"{0}"' -f $LocalBackupRoot),
    '-ArchiveDestinationRoot',
    ('"{0}"' -f $ArchiveDestinationRoot)
  ) -join ' '

  return New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArguments
}

function Register-BackupTask {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TaskName,
    [Parameter(Mandatory = $true)]
    $Trigger,
    [Parameter(Mandatory = $true)]
    $Action,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType InteractiveToken -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries

  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $principal `
    -Settings $settings `
    -Description $Description `
    -Force | Out-Null
}

$legacyTaskName = 'Ipelabor Planka Daily Backup'
if (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
}

$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$weeklyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $WeeklyAt

Register-BackupTask `
  -TaskName $DailyTaskName `
  -Trigger $dailyTrigger `
  -Action (New-BackupTaskAction -Mode 'Incremental') `
  -Description 'Creates a daily incremental Planka backup at 20:00 and moves it to Google Drive.'

Register-BackupTask `
  -TaskName $WeeklyTaskName `
  -Trigger $weeklyTrigger `
  -Action (New-BackupTaskAction -Mode 'Full') `
  -Description 'Creates a weekly full Planka backup on Sundays at 21:00 and moves it to Google Drive.'

Write-Host "Scheduled task '$DailyTaskName' registered for daily execution at $($DailyAt.ToString('HH:mm'))."
Write-Host "Scheduled task '$WeeklyTaskName' registered for Sundays at $($WeeklyAt.ToString('HH:mm'))."
Write-Host 'Note: the tasks run under the current interactive user so the mapped G: drive remains available.'
