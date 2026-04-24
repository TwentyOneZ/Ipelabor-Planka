[CmdletBinding()]
param(
  [string]$ComposeFile = (Join-Path $PSScriptRoot 'docker-compose.yml'),
  [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
  [string]$LocalBackupRoot = (Join-Path $PSScriptRoot 'backups'),
  [string]$ArchiveDestinationRoot = 'G:\Meu Drive\Shared\Ipelabor\Planka'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Write-Log {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,
    [ValidateSet('INFO', 'WARN', 'ERROR')]
    [string]$Level = 'INFO'
  )

  $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  Write-Host $line

  if ($script:LogFile) {
    Add-Content -Path $script:LogFile -Value $line
  }
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [switch]$CaptureOutput
  )

  if ($CaptureOutput) {
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
      $joinedOutput = ($output | Out-String).Trim()
      throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')`n$joinedOutput"
    }

    return $output
  }

  & $FilePath @Arguments
  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0) {
    throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
  }
}

function Read-EnvFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (!(Test-Path -LiteralPath $Path)) {
    throw "Environment file not found: $Path"
  }

  $values = @{}

  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmedLine = $line.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
      continue
    }

    $separatorIndex = $trimmedLine.IndexOf('=')

    if ($separatorIndex -lt 1) {
      continue
    }

    $key = $trimmedLine.Substring(0, $separatorIndex).Trim()
    $value = $trimmedLine.Substring($separatorIndex + 1)

    if (
      ($value.StartsWith('"') -and $value.EndsWith('"')) -or
      ($value.StartsWith("'") -and $value.EndsWith("'"))
    ) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $values[$key] = $value
  }

  return $values
}

function Get-ContainerMountMap {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ContainerName
  )

  $mountsJson = Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'inspect',
    $ContainerName,
    '--format',
    '{{json .Mounts}}'
  ) -CaptureOutput

  $mounts = ($mountsJson -join [Environment]::NewLine) | ConvertFrom-Json
  $mountMap = @{}

  foreach ($mount in $mounts) {
    if ($mount.Type -eq 'volume') {
      $mountMap[$mount.Destination] = $mount.Name
    }
  }

  return $mountMap
}

function Get-ContainerImage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ContainerName
  )

  $image = Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'inspect',
    $ContainerName,
    '--format',
    '{{.Config.Image}}'
  ) -CaptureOutput

  return ($image -join [Environment]::NewLine).Trim()
}

function Assert-ContainerRunning {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ContainerName
  )

  $runningState = Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'inspect',
    $ContainerName,
    '--format',
    '{{.State.Running}}'
  ) -CaptureOutput

  if ((($runningState -join [Environment]::NewLine).Trim()) -ne 'true') {
    throw "Container is not running: $ContainerName"
  }
}

function Export-VolumeArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$UtilityImage,
    [Parameter(Mandatory = $true)]
    [string]$VolumeName,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePathOnHost
  )

  $archiveDirectory = Split-Path -Path $ArchivePathOnHost -Parent
  $archiveName = Split-Path -Path $ArchivePathOnHost -Leaf

  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'run',
    '--rm',
    '-v',
    ('{0}:/source:ro' -f $VolumeName),
    '--mount',
    ('type=bind,source={0},target=/backup' -f $archiveDirectory),
    $UtilityImage,
    'sh',
    '-lc',
    ('tar czf "/backup/{0}" -C /source .' -f $archiveName)
  )
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupName = "planka-backup-$timestamp"
$workingRoot = Join-Path $LocalBackupRoot 'working'
$logRoot = Join-Path $LocalBackupRoot 'logs'
$runRoot = Join-Path $workingRoot $backupName
$databaseRoot = Join-Path $runRoot 'database'
$volumesRoot = Join-Path $runRoot 'volumes'
$configRoot = Join-Path $runRoot 'config'
$termsSnapshotRoot = Join-Path $runRoot 'terms'
$archiveLocalPath = Join-Path $LocalBackupRoot "$backupName.tgz"

New-Item -ItemType Directory -Path $workingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
New-Item -ItemType Directory -Path $databaseRoot -Force | Out-Null
New-Item -ItemType Directory -Path $volumesRoot -Force | Out-Null
New-Item -ItemType Directory -Path $configRoot -Force | Out-Null

$script:LogFile = Join-Path $logRoot "$backupName.log"
New-Item -ItemType File -Path $script:LogFile -Force | Out-Null

try {
  Write-Log "Starting Planka backup in $runRoot"

  if (!(Test-Path -LiteralPath $ComposeFile)) {
    throw "Compose file not found: $ComposeFile"
  }

  $envValues = Read-EnvFile -Path $EnvFile

  foreach ($requiredKey in @(
      'PLANKA_PROD_DATABASE_USER',
      'PLANKA_PROD_DATABASE_PASSWORD',
      'PLANKA_PROD_DATABASE_DB'
    )) {
    if (![string]::IsNullOrWhiteSpace($envValues[$requiredKey])) {
      continue
    }

    throw "Required setting missing in .env: $requiredKey"
  }

  Assert-ContainerRunning -ContainerName 'postgres_server'
  Assert-ContainerRunning -ContainerName 'planka'

  $utilityImage = Get-ContainerImage -ContainerName 'postgres_server'
  $plankaMountMap = Get-ContainerMountMap -ContainerName 'planka'

  $databaseDumpPath = Join-Path $databaseRoot 'planka.dump'
  $databaseDumpInContainer = "/tmp/$backupName.dump"

  Write-Log 'Exporting PostgreSQL database'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'exec',
    '-e',
    ('PGPASSWORD={0}' -f $envValues['PLANKA_PROD_DATABASE_PASSWORD']),
    'postgres_server',
    'pg_dump',
    '-U',
    $envValues['PLANKA_PROD_DATABASE_USER'],
    '-d',
    $envValues['PLANKA_PROD_DATABASE_DB'],
    '-Fc',
    '-f',
    $databaseDumpInContainer
  )
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'cp',
    ('postgres_server:{0}' -f $databaseDumpInContainer),
    $databaseDumpPath
  )
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'exec',
    'postgres_server',
    'rm',
    '-f',
    $databaseDumpInContainer
  )

  $volumeDefinitions = @(
    @{ Destination = '/app/data'; Archive = 'data.tgz' },
    @{ Destination = '/app/data/protected/favicons'; Archive = 'favicons.tgz' },
    @{ Destination = '/app/data/protected/user-avatars'; Archive = 'user-avatars.tgz' },
    @{ Destination = '/app/data/protected/background-images'; Archive = 'background-images.tgz' },
    @{ Destination = '/app/data/private/attachments'; Archive = 'attachments.tgz' }
  )

  foreach ($volumeDefinition in $volumeDefinitions) {
    $destination = $volumeDefinition.Destination
    $archiveName = $volumeDefinition.Archive
    $volumeName = $plankaMountMap[$destination]

    if ([string]::IsNullOrWhiteSpace($volumeName)) {
      Write-Log "Skipping missing volume mount for $destination" 'WARN'
      continue
    }

    Write-Log "Exporting volume $volumeName from $destination"
    Export-VolumeArchive -UtilityImage $utilityImage -VolumeName $volumeName -ArchivePathOnHost (
      Join-Path $volumesRoot $archiveName
    )
  }

  Write-Log 'Saving compose and environment snapshots'
  Copy-Item -LiteralPath $ComposeFile -Destination (Join-Path $configRoot 'docker-compose.yml') -Force

  if (Test-Path -LiteralPath $EnvFile) {
    Copy-Item -LiteralPath $EnvFile -Destination (Join-Path $configRoot '.env.snapshot') -Force
  }

  if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'terms')) {
    Write-Log 'Saving custom terms snapshot'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'terms') -Destination $termsSnapshotRoot -Recurse -Force
  }

  $manifest = [ordered]@{
    backupVersion = 1
    createdAt = (Get-Date).ToString('o')
    machineName = $env:COMPUTERNAME
    composeFile = 'config/docker-compose.yml'
    database = [ordered]@{
      file = 'database/planka.dump'
      format = 'pg_dump_custom'
      database = $envValues['PLANKA_PROD_DATABASE_DB']
      user = $envValues['PLANKA_PROD_DATABASE_USER']
    }
    volumes = @(
      [ordered]@{ destination = '/app/data'; file = 'volumes/data.tgz' }
      [ordered]@{ destination = '/app/data/protected/favicons'; file = 'volumes/favicons.tgz' }
      [ordered]@{ destination = '/app/data/protected/user-avatars'; file = 'volumes/user-avatars.tgz' }
      [ordered]@{ destination = '/app/data/protected/background-images'; file = 'volumes/background-images.tgz' }
      [ordered]@{ destination = '/app/data/private/attachments'; file = 'volumes/attachments.tgz' }
    )
    includesTerms = (Test-Path -LiteralPath $termsSnapshotRoot)
    destinationRoot = $ArchiveDestinationRoot
  }

  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'manifest.json')

  Write-Log "Creating archive $archiveLocalPath"
  Invoke-NativeCommand -FilePath 'tar.exe' -Arguments @(
    '-czf',
    $archiveLocalPath,
    '-C',
    $runRoot,
    '.'
  )

  Write-Log "Moving archive to $ArchiveDestinationRoot"
  New-Item -ItemType Directory -Path $ArchiveDestinationRoot -Force | Out-Null
  $finalArchivePath = Join-Path $ArchiveDestinationRoot ([System.IO.Path]::GetFileName($archiveLocalPath))
  Move-Item -LiteralPath $archiveLocalPath -Destination $finalArchivePath -Force

  Write-Log "Backup completed successfully: $finalArchivePath"
}
catch {
  Write-Log $_.Exception.Message 'ERROR'
  throw
}
finally {
  if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
  }
}
