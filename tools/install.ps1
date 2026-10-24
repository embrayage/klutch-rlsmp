param([Parameter(Mandatory=$true)][string]$ServerRoot)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$serverPath = (Resolve-Path -LiteralPath $ServerRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $serverPath 'BeamMP-Server.exe'))) { throw 'BeamMP-Server.exe missing.' }
$running = Get-Process -Name 'BeamMP-Server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $serverPath 'BeamMP-Server.exe') }
if ($running) { throw 'Stop this BeamMP server before installing.' }
$buildRoot = Join-Path $sourceRoot 'build'
$manifestPath = Join-Path $buildRoot 'build-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$zipRelative = 'Resources\Client\rls_career_overhaul_rlsmp_teamx.zip'
$pluginRelative = 'Resources\Server\rlsmpTeamx'
$builtZip = Join-Path $buildRoot $zipRelative
if ((Get-FileHash -LiteralPath $builtZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.zipSha256) { throw 'Build archive hash mismatch.' }
$builtConfig = Join-Path (Join-Path $buildRoot $pluginRelative) 'config.json'
$nextConfig = Get-Content -LiteralPath $builtConfig -Raw | ConvertFrom-Json
if ($nextConfig.level -ne 'rls_west_coast') { throw 'Expected the RLS West Coast map for this release.' }
$serverConfigPath = Join-Path $serverPath 'ServerConfig.toml'
$serverConfigText = [IO.File]::ReadAllText($serverConfigPath)
$mapPattern = '(?m)^(\s*Map\s*=\s*)"/levels/(?:west_coast_usa|rls_west_coast)/info\.json"'
if ([regex]::Matches($serverConfigText,$mapPattern).Count -ne 1) { throw 'Unexpected server map; refusing to replace another map automatically.' }
$nextServerConfig = [regex]::Replace($serverConfigText,$mapPattern,'${1}"/levels/rls_west_coast/info.json"')
$targetConfig = Join-Path (Join-Path $serverPath $pluginRelative) 'config.json'
if (Test-Path -LiteralPath $targetConfig) {
  $existing = Get-Content -LiteralPath $targetConfig -Raw | ConvertFrom-Json
  if ($existing.serverId -ne $manifest.serverId) { throw 'Existing serverId differs. Preserve its config.json in build/Resources/Server/rlsmpTeamx and rebuild first.' }
}
$targetZip = Join-Path $serverPath $zipRelative
$targetPlugin = Join-Path $serverPath $pluginRelative
$backup = Join-Path (Join-Path $serverPath 'RLSMP-backups') (Get-Date -Format 'yyyyMMdd-HHmmss-ffff')
foreach ($item in @($targetZip, $targetPlugin, $serverConfigPath)) {
  if (Test-Path -LiteralPath $item) {
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Copy-Item -LiteralPath $item -Destination $backup -Recurse
  }
}
New-Item -ItemType Directory -Path (Split-Path -Parent $targetZip),$targetPlugin -Force | Out-Null
Copy-Item -LiteralPath $builtZip -Destination $targetZip -Force
& (Join-Path $PSScriptRoot 'isolate-rls.ps1') -ServerRoot $serverPath
foreach ($script in @('tradeWire.lua','trade.lua','main.lua')) {
  Copy-Item -LiteralPath (Join-Path (Join-Path $buildRoot $pluginRelative) $script) -Destination (Join-Path $targetPlugin $script) -Force
}
Copy-Item -LiteralPath $builtConfig -Destination $targetConfig -Force
[IO.File]::WriteAllText($serverConfigPath,$nextServerConfig,[Text.UTF8Encoding]::new($false))
$devTarget = Join-Path $serverPath 'RLSMP-dev'
if ($sourceRoot -ne [IO.Path]::GetFullPath($devTarget)) {
  New-Item -ItemType Directory -Path $devTarget -Force | Out-Null
  foreach ($name in @('src','tests','tools','build.py','README.md')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $devTarget -Recurse -Force
  }
  $devBuild = Join-Path $devTarget 'build'
  New-Item -ItemType Directory -Path $devBuild -Force | Out-Null
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $devBuild 'build-manifest.json') -Force
  Copy-Item -LiteralPath (Join-Path $buildRoot 'patched-lua') -Destination $devBuild -Recurse -Force
  $devServer = Join-Path $devBuild $pluginRelative
  New-Item -ItemType Directory -Path $devServer -Force | Out-Null
  Copy-Item -LiteralPath $targetConfig -Destination (Join-Path $devServer 'config.json') -Force
}
if ((Get-FileHash -LiteralPath $targetZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.zipSha256) { throw 'Installed archive hash mismatch.' }
Write-Output ('Installed RLSMP ' + $manifest.version + '. Server ID: ' + $manifest.serverId)
Write-Output ('Guide: ' + (Join-Path $devTarget 'README.md'))
