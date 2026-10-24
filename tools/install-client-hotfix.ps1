param([Parameter(Mandatory=$true)][string]$ServerRoot, [switch]$IncludeServer)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$serverPath = (Resolve-Path -LiteralPath $ServerRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $serverPath 'BeamMP-Server.exe'))) { throw 'BeamMP server missing.' }
$buildRoot = Join-Path $sourceRoot 'build'
$manifestPath = Join-Path $buildRoot 'build-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$configuration = Get-Content -LiteralPath (Join-Path $serverPath 'Resources\Server\rlsmpTeamx\config.json') -Raw | ConvertFrom-Json
if ($manifest.serverId -ne $configuration.serverId) { throw 'Server identity mismatch.' }
$relative = 'Resources\Client\rls_career_overhaul_rlsmp_teamx.zip'
$sourceZip = Join-Path $buildRoot $relative
$targetZip = Join-Path $serverPath $relative
if ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.zipSha256) { throw 'Build ZIP hash mismatch.' }
$pluginPath = Join-Path $serverPath 'Resources\Server\rlsmpTeamx'
$builtPlugin = Join-Path $buildRoot 'Resources\Server\rlsmpTeamx'
if ($IncludeServer) {
  foreach ($name in @('tradeWire.lua','trade.lua','main.lua')) {
    if ((Get-FileHash -LiteralPath (Join-Path $builtPlugin $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.serverFiles.$name) { throw ('Server script hash mismatch: ' + $name) }
  }
}
$backup = Join-Path (Join-Path $serverPath 'RLSMP-backups') ((Get-Date -Format 'yyyyMMdd-HHmmss-ffff') + '-client-hotfix')
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$configurationPath = Join-Path $serverPath 'Resources\Server\rlsmpTeamx\config.json'
Copy-Item -LiteralPath $configurationPath -Destination (Join-Path $backup 'config.json') -Force
if ($IncludeServer) { Copy-Item -LiteralPath $pluginPath -Destination (Join-Path $backup 'rlsmpTeamx') -Recurse -Force }
$temporary = $targetZip + '.rlsmp-new'
Copy-Item -LiteralPath $sourceZip -Destination $temporary -Force
[IO.File]::Replace($temporary,$targetZip,(Join-Path $backup 'rls_career_overhaul_rlsmp_teamx.zip'))
& (Join-Path $PSScriptRoot 'isolate-rls.ps1') -ServerRoot $serverPath
# Keep the displayed release in sync while preserving the installed server identity and options.
$configuration.version = $manifest.version
[IO.File]::WriteAllText($configurationPath,($configuration | ConvertTo-Json -Depth 20) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
if ($IncludeServer) {
  # The coordinator is installed last; helpers contain no top-level registrations or mutations.
  foreach ($name in @('tradeWire.lua','trade.lua','main.lua')) {
    $destination = Join-Path $pluginPath $name
    $staged = $destination + '.rlsmp-new'
    Copy-Item -LiteralPath (Join-Path $builtPlugin $name) -Destination $staged -Force
    if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($staged,$destination,(Join-Path $backup ('previous-' + $name))) }
    else { Move-Item -LiteralPath $staged -Destination $destination }
  }
}
$devTarget = Join-Path $serverPath 'RLSMP-dev'
foreach ($name in @('src','tests','tools','build.py','README.md')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $devTarget -Recurse -Force
}
# Retire the former vehicle-only reset from the source mirror as well as the rebuilt ZIP.
$retiredAudioRelative = 'src\client\lua\vehicle\extensions\rlsmpAudioRecovery.lua'
$retiredAudioPath = Join-Path $devTarget $retiredAudioRelative
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $retiredAudioRelative)) -and (Test-Path -LiteralPath $retiredAudioPath)) {
  Copy-Item -LiteralPath $retiredAudioPath -Destination (Join-Path $backup 'retired-vehicle-audio-reset.lua')
  Remove-Item -LiteralPath $retiredAudioPath -Force
}
$devBuild = Join-Path $devTarget 'build'
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $devBuild 'build-manifest.json') -Force
Copy-Item -LiteralPath (Join-Path $buildRoot 'patched-lua') -Destination $devBuild -Recurse -Force
# BETA supplies this store itself; remove the retired alpha-only patched copy.
$retiredStoreRelative = 'patched-lua\ui\ui-vue\mods\rls_career_overhaul\overhaul\modules\career\stores\profilesStore.js'
$retiredStorePath = Join-Path $devBuild $retiredStoreRelative
if (-not (Test-Path -LiteralPath (Join-Path $buildRoot $retiredStoreRelative)) -and (Test-Path -LiteralPath $retiredStorePath)) {
  Copy-Item -LiteralPath $retiredStorePath -Destination (Join-Path $backup 'retired-alpha-profilesStore.js')
  Remove-Item -LiteralPath $retiredStorePath -Force
}
# RLS 2.8.0 final now awaits native routes; retire the BETA-only route override.
$retiredRouteRelative = 'patched-lua\ui\ui-vue\mods\rls_career_overhaul\overhaul\modules\career\utils\coreUiRoutes.js'
$retiredRoutePath = Join-Path $devBuild $retiredRouteRelative
if (-not (Test-Path -LiteralPath (Join-Path $buildRoot $retiredRouteRelative)) -and (Test-Path -LiteralPath $retiredRoutePath)) {
  Copy-Item -LiteralPath $retiredRoutePath -Destination (Join-Path $backup 'retired-beta-coreUiRoutes.js')
  Remove-Item -LiteralPath $retiredRoutePath -Force
}
$devServer = Join-Path $devBuild 'Resources\Server\rlsmpTeamx'
New-Item -ItemType Directory -Path $devServer -Force | Out-Null
Copy-Item -LiteralPath $configurationPath -Destination (Join-Path $devServer 'config.json') -Force
if ($IncludeServer) {
  foreach ($name in @('tradeWire.lua','trade.lua','main.lua')) {
    Copy-Item -LiteralPath (Join-Path $builtPlugin $name) -Destination (Join-Path $devServer $name) -Force
    if ((Get-FileHash -LiteralPath (Join-Path $pluginPath $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.serverFiles.$name) { throw ('Installed server script hash mismatch: ' + $name) }
  }
}
if ((Get-FileHash -LiteralPath $targetZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.zipSha256) { throw 'Installed ZIP hash mismatch.' }
Write-Output ('Installed client hotfix ' + $manifest.version + '. Restart the server and reconnect to load it.')
Write-Output ('Backup: ' + $backup)
