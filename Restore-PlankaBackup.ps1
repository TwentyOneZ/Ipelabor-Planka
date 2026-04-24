[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$BackupFile,
  [string]$ComposeFile = (Join-Path $PSScriptRoot 'docker-compose.yml'),
  [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
  [string]$RestoreWorkspace = (Join-Path $PSScriptRoot 'backups\restore-work')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$resolvedBackupFile = Resolve-Path -LiteralPath $BackupFile

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

New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

try {
  Write-Log "Extracting backup archive $resolvedBackupFile"
  Invoke-NativeCommand -FilePath 'tar.exe' -Arguments @(
    '-xzf',
    $resolvedBackupFile,
    '-C',
    $extractRoot
  )

  $manifestPath = Join-Path $extractRoot 'manifest.json'

  if (!(Test-Path -LiteralPath $manifestPath)) {
    throw "Invalid backup archive. manifest.json not found in $resolvedBackupFile"
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

  Write-Log 'Ensuring containers and volumes exist'
  Invoke-NativeCommand -FilePath 'docker' -Arguments @('compose', '-f', $ComposeFile, 'up', '-d', 'postgres_server', 'planka', 'ssh_tunnel')
  Invoke-NativeCommand -FilePath 'docker' -Arguments @('compose', '-f', $ComposeFile, 'stop', 'planka', 'ssh_tunnel', 'postgres_server')

  $utilityImage = Get-ContainerImage -ContainerName 'postgres_server'
  $plankaMountMap = Get-ContainerMountMap -ContainerName 'planka'

  foreach ($volumeEntry in $manifest.volumes) {
    $volumeName = $plankaMountMap[$volumeEntry.destination]

    if ([string]::IsNullOrWhiteSpace($volumeName)) {
      throw "Unable to find volume mounted at $($volumeEntry.destination)"
    }

    $archivePath = Join-Path $extractRoot $volumeEntry.file

    if (!(Test-Path -LiteralPath $archivePath)) {
      throw "Volume archive not found: $archivePath"
    }

    Write-Log "Restoring volume $volumeName for $($volumeEntry.destination)"
    Restore-VolumeArchive -UtilityImage $utilityImage -VolumeName $volumeName -ExtractRoot $extractRoot -ArchiveRelativePath $volumeEntry.file
  }

  $termsSnapshot = Join-Path $extractRoot 'terms'

  if (Test-Path -LiteralPath $termsSnapshot) {
    $termsDestination = Join-Path $PSScriptRoot 'terms'

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

  $databaseDumpPath = Join-Path $extractRoot $manifest.database.file
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
