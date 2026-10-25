param([Parameter(Mandatory=$true)][string]$ServerRoot)
$ErrorActionPreference = 'Stop'
$serverPath = (Resolve-Path -LiteralPath $ServerRoot).Path
$pluginPath = Join-Path $serverPath 'Resources\Server\rlsmpTeamx'
$mainPath = Join-Path $pluginPath 'main.lua'
if (-not (Test-Path -LiteralPath $mainPath -PathType Leaf)) { throw 'Extract the RLSMP server package before configuring it.' }
$configPath = Join-Path $pluginPath 'config.json'
if (Test-Path -LiteralPath $configPath) {
  $existing = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  if ($existing.serverId -notmatch '^[a-fA-F0-9]{32}$' -or $existing.level -ne 'rls_west_coast') {
    throw 'Existing config.json is invalid for this package. Restore or review it; it will not be replaced.'
  }
  Write-Output 'Existing RLSMP configuration preserved. No identity or options changed.'
  return
}
if (Test-Path -LiteralPath (Join-Path $pluginPath 'trades.jsonl')) {
  throw 'An exchange journal already exists. Restore its original config.json instead of generating a new identity.'
}
$match = [regex]::Match([IO.File]::ReadAllText($mainPath), "local VERSION = '([^']+)'")
if (-not $match.Success) { throw 'Could not read the RLSMP server version.' }
$config = [ordered]@{
  serverId = [guid]::NewGuid().ToString('N')
  level = 'rls_west_coast'
  storage = 'local'
  version = $match.Groups[1].Value
  automaticTraffic = $false
}
# CreateNew also protects against another setup process creating config.json concurrently.
$stream = [IO.File]::Open($configPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush()
} finally { $stream.Dispose() }
Write-Output 'Created a unique RLSMP server identity. Keep config.json in future updates and backups.'
