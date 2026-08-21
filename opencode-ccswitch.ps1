[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$OpenCodeArgs
)

$ErrorActionPreference = "Stop"

function Get-SqliteExecutable {
  $command = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }

  $candidates = @(
    (Join-Path $env:USERPROFILE "anaconda3\Library\bin\sqlite3.exe"),
    (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\SQLite.SQLite_Microsoft.Winget.Source_8wekyb3d8bbwe\sqlite3.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  throw "sqlite3.exe is required. Install SQLite and add it to PATH."
}

function Invoke-SqliteJson([string]$Executable, [string]$Database, [string]$Query) {
  $output = (& $Executable -json -noheader $Database $Query 2>$null) -join "`n"
  if (-not $output) { return $null }
  return $output | ConvertFrom-Json
}

function Get-FirstPropertyValue($Object, [string[]]$Names) {
  if (-not $Object) { return $null }
  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties[$name]
    if ($property -and $property.Value) { return [string]$property.Value }
  }
  return $null
}

$ccRoot = if ($env:CCSWITCH_HOME) { $env:CCSWITCH_HOME } else { Join-Path $env:USERPROFILE ".cc-switch" }
$dbPath = if ($env:CCSWITCH_DB) { $env:CCSWITCH_DB } else { Join-Path $ccRoot "cc-switch.db" }
$settingsPath = Join-Path $ccRoot "settings.json"
$customGeneratedConfig = [bool]$env:OPENCODE_GENERATED_CONFIG
$generatedConfig = if ($customGeneratedConfig) {
  $env:OPENCODE_GENERATED_CONFIG
} else {
  Join-Path $env:TEMP "ccswitch-opencode-$PID.json"
}

if (-not (Test-Path -LiteralPath $dbPath)) {
  throw "CCSwitch database not found: $dbPath"
}

$sqlite = Get-SqliteExecutable
$providerId = $null
if (Test-Path -LiteralPath $settingsPath) {
  $providerId = [string](Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).currentProviderCodex
}
if ($env:CCSWITCH_PROVIDER_ID) { $providerId = $env:CCSWITCH_PROVIDER_ID }

$appType = if ($env:CCSWITCH_APP_TYPE) { $env:CCSWITCH_APP_TYPE } else { "codex" }
$safeAppType = $appType.Replace("'", "''")
$where = "app_type='$safeAppType'"
if ($providerId) {
  $safeProviderId = $providerId.Replace("'", "''")
  $where += " AND id='$safeProviderId'"
} else {
  $where += " AND is_current=1"
}

$query = "SELECT id,name,settings_config,website_url FROM providers WHERE $where LIMIT 1;"
$row = Invoke-SqliteJson $sqlite $dbPath $query
if ($row -is [array]) { $row = $row | Select-Object -First 1 }
if (-not $row) { throw "No active CCSwitch $appType provider was found." }

$providerConfig = [string]$row.settings_config | ConvertFrom-Json
$apiKey = Get-FirstPropertyValue $providerConfig.auth @("OPENAI_API_KEY", "apiKey", "api_key", "token", "accessToken")
if (-not $apiKey) {
  $keyProperty = $providerConfig.auth.PSObject.Properties |
    Where-Object { $_.Name -match '(?i)(api.?key|token|secret)' } |
    Select-Object -First 1
  if ($keyProperty) { $apiKey = [string]$keyProperty.Value }
}
if (-not $apiKey) { throw "The active CCSwitch provider has no API key." }

$toml = [string]$providerConfig.config
$modelMatch = [regex]::Match($toml, '(?m)^\s*model\s*=\s*"([^"]+)"')
$baseMatch = [regex]::Match($toml, '(?m)^\s*base_url\s*=\s*"([^"]+)"')
$effortMatch = [regex]::Match($toml, '(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"')
$modelId = if ($modelMatch.Success) { $modelMatch.Groups[1].Value } else { "default" }
$baseUrl = if ($baseMatch.Success) { $baseMatch.Groups[1].Value.TrimEnd("/") } else { [string]$row.website_url }
$reasoningEffort = if ($effortMatch.Success) { $effortMatch.Groups[1].Value } else { $null }
if (-not $baseUrl) { throw "The active CCSwitch provider has no base URL." }

$modelMap = [ordered]@{}
try {
  $headers = @{ Authorization = "Bearer $apiKey" }
  $catalog = Invoke-RestMethod -Uri "$baseUrl/models" -Headers $headers -Method Get -TimeoutSec 15
  foreach ($entry in @($catalog.data)) {
    if ($entry.id) { $modelMap[[string]$entry.id] = [ordered]@{ name = [string]$entry.id } }
  }
} catch {
  # Some OpenAI-compatible endpoints do not expose /models.
}

if (-not $modelMap.Contains($modelId)) {
  $modelMap[$modelId] = [ordered]@{ name = $modelId }
}
if ($reasoningEffort) {
  $modelMap[$modelId].options = [ordered]@{ reasoningEffort = $reasoningEffort }
}

$auth = [pscustomobject]@{}
$configDir = Split-Path -Parent $generatedConfig
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

$config = [ordered]@{
  '$schema' = "https://opencode.ai/config.json"
  provider = [ordered]@{
    ccswitch = [ordered]@{
      npm = "@ai-sdk/openai-compatible"
      name = "CCSwitch: $($row.name)"
      options = [ordered]@{
        baseURL = $baseUrl
        apiKey = "{env:CCSWITCH_OPENCODE_API_KEY}"
      }
      models = $modelMap
    }
  }
  model = "ccswitch/$modelId"
}
[IO.File]::WriteAllText($generatedConfig, ($config | ConvertTo-Json -Depth 40), $utf8)

$env:CCSWITCH_OPENCODE_API_KEY = $apiKey
$env:OPENCODE_CONFIG = $generatedConfig
Write-Host "CCSwitch provider: $($row.name) | model: $modelId"
try {
  & opencode @OpenCodeArgs
  $exitCode = $LASTEXITCODE
} finally {
  if (-not $customGeneratedConfig) {
    Remove-Item -LiteralPath $generatedConfig -Force -ErrorAction SilentlyContinue
  }
}
exit $exitCode
