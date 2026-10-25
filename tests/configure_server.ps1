$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$setup = Join-Path $projectRoot 'tools\configure-server.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('rlsmp-setup-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
function New-FakeServer([string]$name) {
  $server = Join-Path $temporaryRoot $name
  $plugin = Join-Path $server 'Resources\Server\rlsmpTeamx'
  New-Item -ItemType Directory -Path $plugin -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $plugin 'main.lua'), "local VERSION = '0.8.1-alpha'")
  return $server
}
function Assert-True($value, [string]$message) { if (-not $value) { throw $message } }
try {
  $first = New-FakeServer 'first'
  $second = New-FakeServer 'second'
  & $setup -ServerRoot $first | Out-Null
  & $setup -ServerRoot $second | Out-Null
  $firstConfig = Join-Path $first 'Resources\Server\rlsmpTeamx\config.json'
  $secondConfig = Join-Path $second 'Resources\Server\rlsmpTeamx\config.json'
  $a = Get-Content -LiteralPath $firstConfig -Raw | ConvertFrom-Json
  $b = Get-Content -LiteralPath $secondConfig -Raw | ConvertFrom-Json
  Assert-True ($a.serverId -match '^[a-f0-9]{32}$' -and $a.serverId -ne $b.serverId) 'New servers must have distinct valid identities.'
  Assert-True ($a.level -eq 'rls_west_coast' -and $a.version -eq '0.8.1-alpha') 'Setup must match the package.'
  $a | Add-Member -NotePropertyName customOption -NotePropertyValue 'keep me'
  [IO.File]::WriteAllText($firstConfig, ($a | ConvertTo-Json -Depth 10))
  $before = (Get-FileHash -LiteralPath $firstConfig).Hash
  & $setup -ServerRoot $first | Out-Null
  Assert-True ((Get-FileHash -LiteralPath $firstConfig).Hash -eq $before) 'An existing identity and options must remain byte-for-byte unchanged.'
  $orphan = New-FakeServer 'orphan'
  [IO.File]::WriteAllText((Join-Path $orphan 'Resources\Server\rlsmpTeamx\trades.jsonl'), '{}')
  $blocked = $false
  try { & $setup -ServerRoot $orphan | Out-Null } catch { $blocked = $true }
  Assert-True $blocked 'An orphan journal must prevent a new identity.'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $orphan 'Resources\Server\rlsmpTeamx\config.json'))) 'An orphan journal must not receive a replacement identity.'
  $invalid = New-FakeServer 'invalid'
  $invalidConfig = Join-Path $invalid 'Resources\Server\rlsmpTeamx\config.json'
  [IO.File]::WriteAllText($invalidConfig, '{"serverId":"invalid","level":"rls_west_coast"}')
  $invalidBefore = (Get-FileHash -LiteralPath $invalidConfig).Hash
  $blocked = $false
  try { & $setup -ServerRoot $invalid | Out-Null } catch { $blocked = $true }
  Assert-True ($blocked -and (Get-FileHash -LiteralPath $invalidConfig).Hash -eq $invalidBefore) 'Invalid existing configuration must be preserved for review.'
  Write-Output 'PASS: distinct server identities, existing configuration preservation, orphan-journal and invalid-config protection.'
} finally {
  $resolved = [IO.Path]::GetFullPath($temporaryRoot)
  $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or
      -not [IO.Path]::GetFileName($resolved).StartsWith('rlsmp-setup-check-')) { throw 'Unexpected temporary test directory.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
