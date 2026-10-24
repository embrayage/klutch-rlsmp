# Create the public repository explicitly requested for this project.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required. Install it, then run gh auth login.' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
Push-Location -LiteralPath $root
try {
  & gh auth status
  if ($LASTEXITCODE -ne 0) { throw 'Sign in first with gh auth login.' }
  $accountJson = & gh api user
  if ($LASTEXITCODE -ne 0) { throw 'Could not read the connected GitHub account.' }
  $account = $accountJson | ConvertFrom-Json
  $owner = [string]$account.login
  if ($owner -notmatch '^[A-Za-z0-9-]+$') { throw 'Unexpected GitHub account name.' }
  $repository = $owner + '/klutch-rlsmp'
  if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    & git init --initial-branch=main
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize Git.' }
  }
  $remotes = & git remote
  if ($remotes) { throw 'This checkout already has a remote. Review it before publishing again.' }
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $existing = & gh repo view $repository --json name 2>$null
    $repositoryStatus = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  if ($repositoryStatus -eq 0) { throw ('Repository already exists: ' + $repository + '. Review it before attaching this checkout.') }
  & git add -- .gitignore .gitattributes .github README.md CONTRIBUTING.md THIRD_PARTY.md CHANGELOG.md docs build.py src tests tools
  if ($LASTEXITCODE -ne 0) { throw 'Could not stage the project sources.' }
  $staged = & git diff --cached --name-only
  foreach ($file in $staged) {
    if ($file -match '(^|/)(build|reference|Resources|saves|settings|RLSMP-backups)/|(^|/)(config.json|ServerConfig.toml)$|\.(zip|dll|exe|log|jsonl)$') {
      throw ('Unexpected private/generated staged file: ' + $file)
    }
  }
  & git diff --cached --check
  if ($LASTEXITCODE -ne 0) { throw 'Fix staged whitespace errors before publishing.' }
  $identity = & git config --get user.name
  if (-not $identity) { & git config user.name $owner }
  $email = & git config --get user.email
  if (-not $email) { & git config user.email (([string]$account.id) + '+' + $owner + '@users.noreply.github.com') }
  & git rev-parse --verify --quiet HEAD | Out-Null
  if ($LASTEXITCODE -ne 0) {
    & git commit -m 'Import RLSMP 0.8.0 bridge, build tools, regression suite and documentation'
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the initial commit.' }
  } elseif ($staged) {
    throw 'Existing history has staged changes. Commit and review them before publishing.'
  }
  & gh repo create $repository --public --source $root --remote origin --push --description 'BeamMP bridge for RLS Career Overhaul: independent local careers, synchronized AI traffic and a persistent player marketplace.'
  if ($LASTEXITCODE -ne 0) { throw 'Publication did not complete. Check the repository and remote before retrying.' }
  Write-Output ('Published: https://github.com/' + $repository)
} finally { Pop-Location }
