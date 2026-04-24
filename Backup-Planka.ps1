[CmdletBinding()]
param(
  [ValidateSet('Full', 'Incremental')]
  [string]$Mode = 'Full',
  [string]$ComposeFile,
  [string]$EnvFile,
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

if ([string]::IsNullOrWhiteSpace($ComposeFile)) {
  $ComposeFile = Join-Path $scriptRoot 'docker-compose.yml'
}

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
  $EnvFile = Join-Path $scriptRoot '.env'
}

if ([string]::IsNullOrWhiteSpace($LocalBackupRoot)) {
  $LocalBackupRoot = Join-Path $scriptRoot 'backups'
}

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

function Save-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    $Value
  )

  $directory = Split-Path -Path $Path -Parent
  if ($directory) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Save-TextLines {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $directory = Split-Path -Path $Path -Parent
  if ($directory) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $content = if ($Lines.Count -gt 0) {
    (($Lines | ForEach-Object { [string]$_ }) -join "`n") + "`n"
  } else {
    ''
  }

  [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
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

function Get-VolumeFileManifest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$UtilityImage,
    [Parameter(Mandatory = $true)]
    [string]$VolumeName
  )

  $output = Invoke-NativeCommand -FilePath 'docker' -Arguments @(
    'run',
    '--rm',
    '-v',
    ('{0}:/source:ro' -f $VolumeName),
    'alpine',
    'sh',
    '-lc',
    'cd /source && find . -type f | sort | while IFS= read -r file; do rel="${file#./}"; size=$(stat -c%s "$file"); hash=$(sha256sum "$file"); hash=${hash%% *}; printf "%s\t%s\t%s\n" "$rel" "$size" "$hash"; done'
  ) -CaptureOutput

  $entries = @()

  foreach ($line in $output) {
    $text = [string]$line

    if ([string]::IsNullOrWhiteSpace($text)) {
      continue
    }

    $parts = $text -split "`t", 3
    if ($parts.Length -ne 3) {
      continue
    }

    $entries += [ordered]@{
      path = $parts[0]
      size = [long]$parts[1]
      sha256 = $parts[2]
    }
  }

  return $entries | Sort-Object path
}

function Convert-ManifestToLookup {
  param(
    [Parameter(Mandatory = $true)]
    [Object[]]$Entries
  )

  $lookup = @{}

  foreach ($entry in $Entries) {
    $lookup[$entry.path] = $entry
  }

  return $lookup
}

function Export-VolumeDeltaArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$UtilityImage,
    [Parameter(Mandatory = $true)]
    [string]$VolumeName,
    [Parameter(Mandatory = $true)]
    [string[]]$RelativePaths,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePathOnHost
  )

  $archiveDirectory = Split-Path -Path $ArchivePathOnHost -Parent
  $archiveName = Split-Path -Path $ArchivePathOnHost -Leaf
  $listRoot = Join-Path $archiveDirectory '_lists'
  New-Item -ItemType Directory -Path $listRoot -Force | Out-Null

  $listPath = Join-Path $listRoot ([System.IO.Path]::GetFileNameWithoutExtension($archiveName) + '.txt')
  Save-TextLines -Path $listPath -Lines $RelativePaths

  try {
    Invoke-NativeCommand -FilePath 'docker' -Arguments @(
      'run',
      '--rm',
      '-v',
      ('{0}:/source:ro' -f $VolumeName),
      '--mount',
      ('type=bind,source={0},target=/backup' -f $archiveDirectory),
      '--mount',
      ('type=bind,source={0},target=/lists,readonly' -f $listRoot),
      $UtilityImage,
      'sh',
      '-lc',
      ('if [ -s "/lists/{0}" ]; then tar czf "/backup/{1}" -C /source -T "/lists/{0}"; else tar czf "/backup/{1}" -T /dev/null; fi' -f ([System.IO.Path]::GetFileName($listPath)), $archiveName)
    )
  } finally {
    if (Test-Path -LiteralPath $listPath) {
      Remove-Item -LiteralPath $listPath -Force
    }
  }
}

function Load-FullState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateFilePath
  )

  if (!(Test-Path -LiteralPath $StateFilePath)) {
    throw 'No full backup baseline found. Run a full backup first.'
  }

  return Get-Content -LiteralPath $StateFilePath -Raw | ConvertFrom-Json
}

function Remove-ExpiredArchives {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,
    [int]$RetentionMonths = 2
  )

  $cutoff = (Get-Date).AddMonths(-$RetentionMonths)
  $expiredFiles = Get-ChildItem -LiteralPath $ArchiveRoot -File -Filter 'planka-*.tgz' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff }

  foreach ($file in $expiredFiles) {
    Write-Log "Removing expired backup $($file.FullName)"
    Remove-Item -LiteralPath $file.FullName -Force
  }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupTypeToken = if ($Mode -eq 'Full') { 'full' } else { 'incremental' }
$backupName = "planka-$backupTypeToken-$timestamp"
$workingRoot = Join-Path $LocalBackupRoot 'working'
$logRoot = Join-Path $LocalBackupRoot 'logs'
$stateRoot = Join-Path $LocalBackupRoot 'state'
$latestFullStatePath = Join-Path $stateRoot 'latest-full.json'
$latestFullManifestRoot = Join-Path $stateRoot 'latest-full-manifests'
$runRoot = Join-Path $workingRoot $backupName
$databaseRoot = Join-Path $runRoot 'database'
$volumesRoot = Join-Path $runRoot 'volumes'
$configRoot = Join-Path $runRoot 'config'
$termsSnapshotRoot = Join-Path $runRoot 'terms'
$manifestsRoot = Join-Path $runRoot 'manifests'
$volumeManifestRoot = Join-Path $manifestsRoot 'volumes'
$archiveLocalPath = Join-Path $LocalBackupRoot "$backupName.tgz"

New-Item -ItemType Directory -Path $workingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $databaseRoot -Force | Out-Null
New-Item -ItemType Directory -Path $volumesRoot -Force | Out-Null
New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
New-Item -ItemType Directory -Path $volumeManifestRoot -Force | Out-Null

$script:LogFile = Join-Path $logRoot "$backupName.log"
New-Item -ItemType File -Path $script:LogFile -Force | Out-Null

$volumeDefinitions = @(
  [ordered]@{ Alias = 'data'; Destination = '/app/data'; FullArchive = 'data.tgz'; DeltaArchive = 'data.delta.tgz'; DeletionsFile = 'data.deleted.txt' }
  [ordered]@{ Alias = 'favicons'; Destination = '/app/data/protected/favicons'; FullArchive = 'favicons.tgz'; DeltaArchive = 'favicons.delta.tgz'; DeletionsFile = 'favicons.deleted.txt' }
  [ordered]@{ Alias = 'user-avatars'; Destination = '/app/data/protected/user-avatars'; FullArchive = 'user-avatars.tgz'; DeltaArchive = 'user-avatars.delta.tgz'; DeletionsFile = 'user-avatars.deleted.txt' }
  [ordered]@{ Alias = 'background-images'; Destination = '/app/data/protected/background-images'; FullArchive = 'background-images.tgz'; DeltaArchive = 'background-images.delta.tgz'; DeletionsFile = 'background-images.deleted.txt' }
  [ordered]@{ Alias = 'attachments'; Destination = '/app/data/private/attachments'; FullArchive = 'attachments.tgz'; DeltaArchive = 'attachments.delta.tgz'; DeletionsFile = 'attachments.deleted.txt' }
)

$incrementalSummary = @{}

try {
  Write-Log "Starting $Mode Planka backup in $runRoot"

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
  $currentVolumeManifests = @{}

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

  foreach ($volumeDefinition in $volumeDefinitions) {
    $destination = $volumeDefinition.Destination
    $alias = $volumeDefinition.Alias
    $volumeName = $plankaMountMap[$destination]

    if ([string]::IsNullOrWhiteSpace($volumeName)) {
      Write-Log "Skipping missing volume mount for $destination" 'WARN'
      continue
    }

    Write-Log "Building file manifest for $volumeName from $destination"
    $manifestEntries = @(Get-VolumeFileManifest -UtilityImage $utilityImage -VolumeName $volumeName)
    $currentVolumeManifests[$alias] = [ordered]@{
      alias = $alias
      destination = $destination
      volume = $volumeName
      files = $manifestEntries
    }

    Save-JsonFile -Path (Join-Path $volumeManifestRoot "$alias.json") -Value $currentVolumeManifests[$alias]

    if ($Mode -eq 'Full') {
      Write-Log "Exporting full volume $volumeName from $destination"
      Export-VolumeArchive -UtilityImage $utilityImage -VolumeName $volumeName -ArchivePathOnHost (
        Join-Path $volumesRoot $volumeDefinition.FullArchive
      )

      continue
    }

    $fullState = Load-FullState -StateFilePath $latestFullStatePath
    $baselineManifestPath = Join-Path $latestFullManifestRoot "$alias.json"

    if (!(Test-Path -LiteralPath $baselineManifestPath)) {
      throw "Missing full baseline manifest for volume alias '$alias'. Run a full backup first."
    }

    $baselineManifest = Get-Content -LiteralPath $baselineManifestPath -Raw | ConvertFrom-Json
    $baselineLookup = Convert-ManifestToLookup -Entries @($baselineManifest.files)
    $currentLookup = Convert-ManifestToLookup -Entries @($manifestEntries)
    $changedPaths = New-Object System.Collections.Generic.List[string]
    $deletedPaths = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $manifestEntries) {
      $baselineEntry = $baselineLookup[$entry.path]

      if ($null -eq $baselineEntry -or $baselineEntry.sha256 -ne $entry.sha256) {
        $changedPaths.Add($entry.path)
      }
    }

    foreach ($baselinePath in $baselineLookup.Keys) {
      if (!$currentLookup.ContainsKey($baselinePath)) {
        $deletedPaths.Add($baselinePath)
      }
    }

    Write-Log "Exporting incremental volume $volumeName from $destination with $($changedPaths.Count) changed files and $($deletedPaths.Count) deletions"

    Export-VolumeDeltaArchive -UtilityImage $utilityImage -VolumeName $volumeName -RelativePaths $changedPaths.ToArray() -ArchivePathOnHost (
      Join-Path $volumesRoot $volumeDefinition.DeltaArchive
    )

    Save-TextLines -Path (Join-Path $volumesRoot $volumeDefinition.DeletionsFile) -Lines $deletedPaths.ToArray()
    $incrementalSummary[$volumeDefinition.Alias] = [ordered]@{
      changedFileCount = $changedPaths.Count
      deletedFileCount = $deletedPaths.Count
    }
  }

  Write-Log 'Saving compose and environment snapshots'
  Copy-Item -LiteralPath $ComposeFile -Destination (Join-Path $configRoot 'docker-compose.yml') -Force

  if (Test-Path -LiteralPath $EnvFile) {
    Copy-Item -LiteralPath $EnvFile -Destination (Join-Path $configRoot '.env.snapshot') -Force
  }

  if (Test-Path -LiteralPath (Join-Path $scriptRoot 'terms')) {
    Write-Log 'Saving custom terms snapshot'
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'terms') -Destination $termsSnapshotRoot -Recurse -Force
  }

  $manifest = [ordered]@{
    backupVersion = 2
    backupType = $backupTypeToken
    createdAt = (Get-Date).ToString('o')
    machineName = $env:COMPUTERNAME
    composeFile = 'config/docker-compose.yml'
    database = [ordered]@{
      file = 'database/planka.dump'
      format = 'pg_dump_custom'
      database = $envValues['PLANKA_PROD_DATABASE_DB']
      user = $envValues['PLANKA_PROD_DATABASE_USER']
    }
    volumes = @()
    includesTerms = (Test-Path -LiteralPath $termsSnapshotRoot)
    destinationRoot = $ArchiveDestinationRoot
  }

  if ($Mode -eq 'Incremental') {
    $fullState = Load-FullState -StateFilePath $latestFullStatePath
    $manifest.baseFullBackupName = $fullState.backupName
  }

  foreach ($volumeDefinition in $volumeDefinitions) {
    $destination = $volumeDefinition.Destination
    $volumeName = $plankaMountMap[$destination]

    if ([string]::IsNullOrWhiteSpace($volumeName)) {
      continue
    }

    if ($Mode -eq 'Full') {
      $manifest.volumes += [ordered]@{
        alias = $volumeDefinition.Alias
        destination = $destination
        file = ('volumes/{0}' -f $volumeDefinition.FullArchive)
        mode = 'full'
        manifestFile = ('manifests/volumes/{0}.json' -f $volumeDefinition.Alias)
      }

      continue
    }

    $changedArchivePath = Join-Path $volumesRoot $volumeDefinition.DeltaArchive
    $deletionsPath = Join-Path $volumesRoot $volumeDefinition.DeletionsFile
    $summary = $incrementalSummary[$volumeDefinition.Alias]

    $manifest.volumes += [ordered]@{
      alias = $volumeDefinition.Alias
      destination = $destination
      file = ('volumes/{0}' -f $volumeDefinition.DeltaArchive)
      mode = 'delta'
      deletionsFile = ('volumes/{0}' -f $volumeDefinition.DeletionsFile)
      changedFileCount = $summary.changedFileCount
      deletedFileCount = $summary.deletedFileCount
      manifestFile = ('manifests/volumes/{0}.json' -f $volumeDefinition.Alias)
    }
  }

  Save-JsonFile -Path (Join-Path $runRoot 'manifest.json') -Value $manifest

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

  if ([System.IO.Path]::GetFullPath($archiveLocalPath) -ne [System.IO.Path]::GetFullPath($finalArchivePath)) {
    Move-Item -LiteralPath $archiveLocalPath -Destination $finalArchivePath -Force
  } else {
    Write-Log 'Archive destination is the local backup root; keeping archive in place'
  }

  if ($Mode -eq 'Full') {
    Write-Log 'Updating full backup baseline state'
    if (Test-Path -LiteralPath $latestFullManifestRoot) {
      Remove-Item -LiteralPath $latestFullManifestRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $latestFullManifestRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $volumeManifestRoot '*') -Destination $latestFullManifestRoot -Recurse -Force

    Save-JsonFile -Path $latestFullStatePath -Value ([ordered]@{
        backupName = [System.IO.Path]::GetFileName($finalArchivePath)
        backupPath = $finalArchivePath
        createdAt = (Get-Date).ToString('o')
      })
  }

  Remove-ExpiredArchives -ArchiveRoot $ArchiveDestinationRoot -RetentionMonths 2

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
