[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$BackupFile,
  [string]$ComposeFile,
  [string]$EnvFile,
  [string]$RestoreWorkspace
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

if ([string]::IsNullOrWhiteSpace($ComposeFile)) {
  $ComposeFile = Join-Path $scriptRoot 'docker-compose.yml'
}

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
  $EnvFile = Join-Path $scriptRoot '.env'
}

if ([string]::IsNullOrWhiteSpace($RestoreWorkspace)) {
  $RestoreWorkspace = Join-Path $scriptRoot 'backups\restore-work'
}

function Write-Log {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  Write-Host ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
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

function Wait-ForContainerHealth {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ContainerName,
    [int]$TimeoutSeconds = 120
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  while ((Get-Date) -lt $deadline) {
    $health = Invoke-NativeCommand -FilePath 'docker' -Arguments @(
      'inspect',
      $ContainerName,
      '--format',
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}'
    ) -CaptureOutput

    $state = (($health -join [Environment]::NewLine).Trim())

    if ($state -in @('healthy', 'running')) {
      return
    }

    Start-Sleep -Seconds 2
  }

  throw "Timed out while waiting for container health: $ContainerName"
}

function Restore-VolumeArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$UtilityImage,
    [Parameter(Mandatory = $true)]
    [string]$VolumeName,
    [Parameter(Mandatory = $true)]
    [string]$ExtractRoot,
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRelativePath
  )

  $archiveRelativePathUnix = $ArchiveRelativePath.Replace('\', '/')

  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'run',
    '--rm',
    '--user',
    'root',
    '-v',
    ('{0}:/target' -f $VolumeName),
    '--mount',
    ('type=bind,source={0},target=/restore,readonly' -f $ExtractRoot),
    $UtilityImage,
    'sh',
    '-lc',
    ('mkdir -p /target && find /target -mindepth 1 -delete && tar xzf "/restore/{0}" -C /target' -f $archiveRelativePathUnix)
  )
}

function Apply-VolumeDelta {
  param(
    [Parameter(Mandatory = $true)]
    [string]$UtilityImage,
    [Parameter(Mandatory = $true)]
    [string]$VolumeName,
    [Parameter(Mandatory = $true)]
    [string]$ExtractRoot,
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRelativePath,
    [Parameter(Mandatory = $true)]
    [string]$DeletionsRelativePath
  )

  $archiveRelativePathUnix = $ArchiveRelativePath.Replace('\', '/')
  $deletionsRelativePathUnix = $DeletionsRelativePath.Replace('\', '/')

  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'run',
    '--rm',
    '--user',
    'root',
    '-v',
    ('{0}:/target' -f $VolumeName),
    '--mount',
    ('type=bind,source={0},target=/restore,readonly' -f $ExtractRoot),
    $UtilityImage,
    'sh',
    '-lc',
    ('mkdir -p /target && tar xzf "/restore/{0}" -C /target && if [ "{1}" != "" ] && [ -f "/restore/{1}" ]; then cd /target && while IFS= read -r path; do [ -z "$path" ] && continue; rm -rf -- "$path"; done < "/restore/{1}"; fi' -f $archiveRelativePathUnix, $deletionsRelativePathUnix)
  )
}

function Extract-BackupArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
  )

  New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

  Invoke-NativeCommand -FilePath 'tar.exe' -Arguments @(
    '-xzf',
    $ArchivePath,
    '-C',
    $DestinationPath
  )
}

function Get-ManifestFromExtractedBackup {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ExtractRoot
  )

  $manifestPath = Join-Path $ExtractRoot 'manifest.json'

  if (!(Test-Path -LiteralPath $manifestPath)) {
    throw "Invalid backup archive. manifest.json not found in $ExtractRoot"
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

$resolvedBackupFile = (Resolve-Path -LiteralPath $BackupFile).Path

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

$restoreName = 'restore-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$extractRoot = Join-Path $RestoreWorkspace $restoreName
$requestedExtractRoot = Join-Path $extractRoot 'requested'
$baseExtractRoot = Join-Path $extractRoot 'base-full'

New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

try {
  Write-Log "Extracting backup archive $resolvedBackupFile"
  Extract-BackupArchive -ArchivePath $resolvedBackupFile -DestinationPath $requestedExtractRoot
  $requestedManifest = Get-ManifestFromExtractedBackup -ExtractRoot $requestedExtractRoot

  $requestedBackupType = if ($requestedManifest.backupType) {
    [string]$requestedManifest.backupType
  } else {
    'full'
  }

  Write-Log 'Ensuring containers and volumes exist'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @('compose', '-f', $ComposeFile, 'up', '-d', 'postgres_server', 'planka', 'ssh_tunnel')
  Invoke-NativeCommand -FilePath 'docker' -Arguments @('compose', '-f', $ComposeFile, 'stop', 'planka', 'ssh_tunnel', 'postgres_server')

  $utilityImage = Get-ContainerImage -ContainerName 'postgres_server'
  $plankaMountMap = Get-ContainerMountMap -ContainerName 'planka'

  if ($requestedBackupType -eq 'incremental') {
    if ([string]::IsNullOrWhiteSpace($requestedManifest.baseFullBackupName)) {
      throw 'Incremental backup is missing baseFullBackupName in manifest.'
    }

    $backupDirectory = Split-Path -Path $resolvedBackupFile -Parent
    $baseFullArchivePath = Join-Path $backupDirectory $requestedManifest.baseFullBackupName

    if (!(Test-Path -LiteralPath $baseFullArchivePath)) {
      throw "Base full backup not found next to incremental backup: $baseFullArchivePath"
    }

    Write-Log "Extracting base full backup $baseFullArchivePath"
    Extract-BackupArchive -ArchivePath $baseFullArchivePath -DestinationPath $baseExtractRoot
    $baseManifest = Get-ManifestFromExtractedBackup -ExtractRoot $baseExtractRoot

    foreach ($volumeEntry in $baseManifest.volumes) {
      $volumeName = $plankaMountMap[$volumeEntry.destination]

      if ([string]::IsNullOrWhiteSpace($volumeName)) {
        throw "Unable to find volume mounted at $($volumeEntry.destination)"
      }

      $archivePath = Join-Path $baseExtractRoot $volumeEntry.file

      if (!(Test-Path -LiteralPath $archivePath)) {
        throw "Volume archive not found in base full backup: $archivePath"
      }

      Write-Log "Restoring base volume $volumeName for $($volumeEntry.destination)"
      Restore-VolumeArchive -UtilityImage $utilityImage -VolumeName $volumeName -ExtractRoot $baseExtractRoot -ArchiveRelativePath $volumeEntry.file
    }

    foreach ($volumeEntry in $requestedManifest.volumes) {
      $volumeName = $plankaMountMap[$volumeEntry.destination]

      if ([string]::IsNullOrWhiteSpace($volumeName)) {
        throw "Unable to find volume mounted at $($volumeEntry.destination)"
      }

      $archivePath = Join-Path $requestedExtractRoot $volumeEntry.file
      $deletionsFile = if ($volumeEntry.PSObject.Properties.Name -contains 'deletionsFile') {
        [string]$volumeEntry.deletionsFile
      } else {
        ''
      }

      if (!(Test-Path -LiteralPath $archivePath)) {
        throw "Delta volume archive not found: $archivePath"
      }

      Write-Log "Applying volume delta for $volumeName at $($volumeEntry.destination)"
      Apply-VolumeDelta -UtilityImage $utilityImage -VolumeName $volumeName -ExtractRoot $requestedExtractRoot -ArchiveRelativePath $volumeEntry.file -DeletionsRelativePath $deletionsFile
    }
  } else {
    foreach ($volumeEntry in $requestedManifest.volumes) {
      $volumeName = $plankaMountMap[$volumeEntry.destination]

      if ([string]::IsNullOrWhiteSpace($volumeName)) {
        throw "Unable to find volume mounted at $($volumeEntry.destination)"
      }

      $archivePath = Join-Path $requestedExtractRoot $volumeEntry.file

      if (!(Test-Path -LiteralPath $archivePath)) {
        throw "Volume archive not found: $archivePath"
      }

      Write-Log "Restoring volume $volumeName for $($volumeEntry.destination)"
      Restore-VolumeArchive -UtilityImage $utilityImage -VolumeName $volumeName -ExtractRoot $requestedExtractRoot -ArchiveRelativePath $volumeEntry.file
    }
  }

  $termsSourceRoot = if (Test-Path -LiteralPath (Join-Path $requestedExtractRoot 'terms')) {
    $requestedExtractRoot
  } elseif (Test-Path -LiteralPath (Join-Path $baseExtractRoot 'terms')) {
    $baseExtractRoot
  } else {
    $null
  }

  if ($termsSourceRoot) {
    $termsSnapshot = Join-Path $termsSourceRoot 'terms'
    $termsDestination = Join-Path $scriptRoot 'terms'

    Write-Log 'Restoring custom terms files'
    if (Test-Path -LiteralPath $termsDestination) {
      Get-ChildItem -LiteralPath $termsDestination -Force | Remove-Item -Recurse -Force
    } else {
      New-Item -ItemType Directory -Path $termsDestination -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $termsSnapshot '*') -Destination $termsDestination -Recurse -Force
  }

  Write-Log 'Starting PostgreSQL for database restore'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @('compose', '-f', $ComposeFile, 'up', '-d', 'postgres_server')
  Wait-ForContainerHealth -ContainerName 'postgres_server'

  $databaseDumpPath = Join-Path $requestedExtractRoot $requestedManifest.database.file
  $databaseDumpInContainer = '/tmp/planka-restore.dump'

  if (!(Test-Path -LiteralPath $databaseDumpPath)) {
    throw "Database dump not found: $databaseDumpPath"
  }

  Write-Log 'Copying database dump into PostgreSQL container'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'cp',
    $databaseDumpPath,
    ('postgres_server:{0}' -f $databaseDumpInContainer)
  )

  $dbUser = $envValues['PLANKA_PROD_DATABASE_USER']
  $dbPassword = $envValues['PLANKA_PROD_DATABASE_PASSWORD']
  $dbName = $envValues['PLANKA_PROD_DATABASE_DB']

  Write-Log 'Dropping and recreating the target database'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'exec',
    '-e',
    ('PGPASSWORD={0}' -f $dbPassword),
    'postgres_server',
    'psql',
    '-U',
    $dbUser,
    '-d',
    'postgres',
    '-v',
    'ON_ERROR_STOP=1',
    '-c',
    ('DROP DATABASE IF EXISTS "{0}" WITH (FORCE);' -f $dbName)
  )
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'exec',
    '-e',
    ('PGPASSWORD={0}' -f $dbPassword),
    'postgres_server',
    'psql',
    '-U',
    $dbUser,
    '-d',
    'postgres',
    '-v',
    'ON_ERROR_STOP=1',
    '-c',
    ('CREATE DATABASE "{0}";' -f $dbName)
  )

  Write-Log 'Restoring PostgreSQL backup'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'exec',
    '-e',
    ('PGPASSWORD={0}' -f $dbPassword),
    'postgres_server',
    'pg_restore',
    '-U',
    $dbUser,
    '-d',
    $dbName,
    '--clean',
    '--if-exists',
    '--no-owner',
    '--no-privileges',
    $databaseDumpInContainer
  )
  Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'exec',
    'postgres_server',
    'rm',
    '-f',
    $databaseDumpInContainer
  )

  Write-Log 'Starting Planka and SSH tunnel'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @('compose', '-f', $ComposeFile, 'up', '-d', 'planka', 'ssh_tunnel')

  Write-Log 'Restore completed successfully'
}
finally {
  if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
  }
}
