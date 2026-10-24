param([Parameter(Mandatory=$true)][string]$ServerRoot)
$ErrorActionPreference = 'Stop'
$serverPath = (Resolve-Path -LiteralPath $ServerRoot).Path
$clientPath = (Resolve-Path -LiteralPath (Join-Path $serverPath 'Resources\Client')).Path
$bridgePath = Join-Path $clientPath 'rls_career_overhaul_rlsmp_teamx.zip'
if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { throw 'Install the RLSMP archive before isolating conflicting RLS versions.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$conflicts = @()
foreach ($file in Get-ChildItem -LiteralPath $clientPath -File -Filter '*.zip') {
  if ($file.FullName -eq $bridgePath) { continue }
  $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
  try {
    # Identify the RLS package by both its shared bootstrap and its career core.
    # Other vehicle mods and archives in subdirectories are left alone.
    if ($archive.GetEntry('scripts/rls_career_overhaul/modScript.lua') -and
        $archive.GetEntry('lua/ge/extensions/overhaul/career/career.lua')) {
      $conflicts += $file
    }
  } finally { $archive.Dispose() }
}
if ($conflicts.Count -eq 0) { Write-Output 'RLS isolation: only the RLSMP package is distributed.'; return }
$backupRoot = [IO.Path]::GetFullPath((Join-Path $serverPath 'RLSMP-backups'))
$backupPath = [IO.Path]::GetFullPath((Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-ffff') + '-rls-conflicts')))
if (-not $backupPath.StartsWith($backupRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected backup path.' }
New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
foreach ($file in $conflicts) {
  $sourcePath = [IO.Path]::GetFullPath($file.FullName)
  $destinationPath = [IO.Path]::GetFullPath((Join-Path $backupPath $file.Name))
  if ([IO.Path]::GetDirectoryName($sourcePath) -ne $clientPath -or
      [IO.Path]::GetDirectoryName($destinationPath) -ne $backupPath) { throw 'Unexpected archive path.' }
  $expectedHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
  Move-Item -LiteralPath $sourcePath -Destination $destinationPath
  if ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Backup verification failed.' }
  Write-Output ('Conflicting RLS archived: ' + $destinationPath)
}
