[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$OpenCodeArgs
)

$ErrorActionPreference = "Stop"

function Get-SqliteExecutable {
  if ($env:CCSWITCH_SQLITE) {
    if (Test-Path -LiteralPath $env:CCSWITCH_SQLITE) { return $env:CCSWITCH_SQLITE }
    throw "CCSWITCH_SQLITE does not point to an executable: $env:CCSWITCH_SQLITE"
  }
  $command = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $candidates = @(
    (Join-Path $env:USERPROFILE "anaconda3\Library\bin\sqlite3.exe"),
    (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\SQLite.SQLite_Microsoft.Winget.Source_8wekyb3d8bbwe\sqlite3.exe")
  )
  foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
  throw "sqlite3.exe is required. Install SQLite and add it to PATH."
}

function Invoke-SqliteJson([string]$Executable, [string]$Database, [string]$Query) {
  $output = (& $Executable -readonly -json -noheader $Database $Query 2>$null) -join "`n"
  if (-not $output) { return $null }
  $value = $output | ConvertFrom-Json
  if ($value -is [array] -and $value.Count -eq 1) { return $value[0] }
  return $value
}

function Get-ObjectValue($Object, [string]$Name) {
  if (-not $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function Get-FirstPropertyValue($Object, [string[]]$Names) {
  foreach ($name in $Names) {
    $value = Get-ObjectValue $Object $name
    if ($null -ne $value -and [string]$value) { return [string]$value }
  }
  return $null
}

function Convert-ToHashtable($Object) {
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in $Object.Keys) { $result[$key] = Convert-ToHashtable $Object[$key] }
    return $result
  }
  if ($Object -is [pscustomobject]) {
    $result = [ordered]@{}
    foreach ($property in $Object.PSObject.Properties) { $result[$property.Name] = Convert-ToHashtable $property.Value }
    return $result
  }
  if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
    return @($Object | ForEach-Object { Convert-ToHashtable $_ })
  }
  return $Object
}

function Resolve-ApiKey($ProviderConfig) {
  $auth = Get-ObjectValue $ProviderConfig "auth"
  $options = Get-ObjectValue $ProviderConfig "options"
  $value = Get-FirstPropertyValue $options @("apiKey", "api_key", "token", "accessToken")
  if (-not $value) { $value = Get-FirstPropertyValue $auth @("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "apiKey", "api_key", "token", "accessToken") }
  if (-not $value -and $auth) {
    $property = $auth.PSObject.Properties | Where-Object { $_.Name -match '(?i)(api.?key|token|secret)' } | Select-Object -First 1
    if ($property) { $value = [string]$property.Value }
  }
  if ($value -match '^\{env:([^}]+)\}$') { $value = [Environment]::GetEnvironmentVariable($Matches[1]) }
  return $value
}

function Get-ProviderSelection($Settings, [string]$RequestedAppType, [string]$RequestedProviderId, [string]$Sqlite, [string]$Database) {
  $appType = $RequestedAppType
  if (-not $appType) {
    $openCodeId = [string](Get-ObjectValue $Settings "currentProviderOpenCode")
    $openCodeCurrent = Invoke-SqliteJson $Sqlite $Database "SELECT count(*) AS count FROM providers WHERE app_type='opencode' AND is_current=1;"
    if ($openCodeId -or ([int](Get-ObjectValue $openCodeCurrent "count") -gt 0)) { $appType = "opencode" } else { $appType = "codex" }
  }
  $providerId = $RequestedProviderId
  if (-not $providerId) {
    $settingName = switch ($appType) {
      "opencode" { "currentProviderOpenCode" }
      "codex" { "currentProviderCodex" }
      default { "currentProvider$($appType.Substring(0,1).ToUpperInvariant())$($appType.Substring(1))" }
    }
    $providerId = [string](Get-ObjectValue $Settings $settingName)
  }
  $safeAppType = $appType.Replace("'", "''")
  $where = "app_type='$safeAppType'"
  if ($providerId) {
    $safeProviderId = $providerId.Replace("'", "''")
    $where += " AND id='$safeProviderId'"
  } else { $where += " AND is_current=1" }
  $row = Invoke-SqliteJson $Sqlite $Database "SELECT id,name,settings_config,meta,website_url FROM providers WHERE $where LIMIT 1;"
  if ($row -is [array]) { $row = $row | Select-Object -First 1 }
  if (-not $row) { throw "No active CCSwitch $appType provider was found." }
  return [pscustomobject]@{ AppType = $appType; ProviderId = [string]$row.id; Row = $row }
}

function Get-ProviderRuntime($Selection) {
  $row = $Selection.Row
  $providerConfig = [string]$row.settings_config | ConvertFrom-Json
  $nativeOpenCode = $Selection.AppType -eq "opencode" -or (Get-ObjectValue $providerConfig "npm")
  $npm = if ($nativeOpenCode -and (Get-ObjectValue $providerConfig "npm")) { [string]$providerConfig.npm } else { "@ai-sdk/openai-compatible" }
  if ($env:CCSWITCH_OPENCODE_NPM) { $npm = $env:CCSWITCH_OPENCODE_NPM }
  $baseUrl = $null; $modelId = $null; $reasoningEffort = $null; $modelMap = [ordered]@{}
  if ($nativeOpenCode) {
    $options = Get-ObjectValue $providerConfig "options"
    $baseUrl = [string](Get-ObjectValue $options "baseURL")
    $models = Get-ObjectValue $providerConfig "models"
    if ($models) { foreach ($property in $models.PSObject.Properties) { $modelMap[$property.Name] = Convert-ToHashtable $property.Value } }
    $meta = [string](Get-ObjectValue $row "meta")
    if ($meta) { try { $metaObject = $meta | ConvertFrom-Json; $modelId = [string](Get-FirstPropertyValue $metaObject @("model", "defaultModel")) } catch { } }
    if (-not $modelId) { $modelId = [string](Get-ObjectValue $providerConfig "model") }
    if (-not $modelId -and $modelMap.Count -gt 0) { $modelId = [string]($modelMap.Keys | Select-Object -First 1) }
  } else {
    $toml = [string](Get-ObjectValue $providerConfig "config")
    $modelMatch = [regex]::Match($toml, '(?m)^\s*model\s*=\s*"([^"]+)"')
    $baseMatch = [regex]::Match($toml, '(?m)^\s*base_url\s*=\s*"([^"]+)"')
    $effortMatch = [regex]::Match($toml, '(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"')
    $modelId = if ($modelMatch.Success) { $modelMatch.Groups[1].Value } else { $null }
    $baseUrl = if ($baseMatch.Success) { $baseMatch.Groups[1].Value } else { $null }
    $reasoningEffort = if ($effortMatch.Success) { $effortMatch.Groups[1].Value } else { $null }
    $catalogModels = Get-ObjectValue (Get-ObjectValue $providerConfig "modelCatalog") "models"
    foreach ($entry in @($catalogModels)) {
      $id = [string](Get-FirstPropertyValue $entry @("model", "id", "slug"))
      if ($id) { $modelMap[$id] = [ordered]@{ name = [string](Get-FirstPropertyValue $entry @("displayName", "name", "model")) } }
    }
  }
  if (-not $baseUrl) { $baseUrl = [string]$row.website_url }
  if (-not $baseUrl) { throw "The active CCSwitch provider has no base URL." }
  if (-not $modelId) { $modelId = "default" }
  return [pscustomobject]@{ ProviderConfig = $providerConfig; Npm = $npm; BaseUrl = $baseUrl.TrimEnd("/"); ModelId = $modelId; ReasoningEffort = $reasoningEffort; ModelMap = $modelMap; ApiKey = Resolve-ApiKey $providerConfig }
}

function Add-RemoteModels($Runtime) {
  if ($env:CCSWITCH_MODEL_DISCOVERY -ne "never") {
    try {
      $headers = @{ Authorization = "Bearer $($Runtime.ApiKey)" }
      $catalog = Invoke-RestMethod -Uri "$($Runtime.BaseUrl)/models" -Headers $headers -Method Get -TimeoutSec 15
      $entries = if ($catalog.data) { @($catalog.data) } elseif ($catalog -is [array]) { @($catalog) } else { @() }
      foreach ($entry in $entries) {
        $id = [string](Get-ObjectValue $entry "id")
        if ($id -and -not $Runtime.ModelMap.Contains($id)) { $Runtime.ModelMap[$id] = [ordered]@{ name = $id } }
      }
    } catch {
      if ($env:CCSWITCH_MODEL_DISCOVERY -eq "required") { throw "Model discovery failed: $($_.Exception.Message)" }
    }
  }
  if (-not $Runtime.ModelMap.Contains($Runtime.ModelId)) { $Runtime.ModelMap[$Runtime.ModelId] = [ordered]@{ name = $Runtime.ModelId } }
  if ($Runtime.ReasoningEffort) {
    $entry = $Runtime.ModelMap[$Runtime.ModelId]
    if ($entry -isnot [System.Collections.IDictionary]) { $entry = Convert-ToHashtable $entry; $Runtime.ModelMap[$Runtime.ModelId] = $entry }
    $entry.options = [ordered]@{ reasoningEffort = $Runtime.ReasoningEffort }
  }
}

$ccRoot = if ($env:CCSWITCH_HOME) { $env:CCSWITCH_HOME } else { Join-Path $env:USERPROFILE ".cc-switch" }
$dbPath = if ($env:CCSWITCH_DB) { $env:CCSWITCH_DB } else { Join-Path $ccRoot "cc-switch.db" }
$settingsPath = Join-Path $ccRoot "settings.json"
$customGeneratedConfig = [bool]$env:OPENCODE_GENERATED_CONFIG
$generatedConfig = if ($customGeneratedConfig) { $env:OPENCODE_GENERATED_CONFIG } else { Join-Path $env:TEMP "ccswitch-opencode-$PID.json" }
if (-not (Test-Path -LiteralPath $dbPath)) { throw "CCSwitch database not found: $dbPath" }
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { throw "OpenCode was not found on PATH." }
$sqlite = Get-SqliteExecutable
$settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$selection = Get-ProviderSelection $settings $env:CCSWITCH_APP_TYPE $env:CCSWITCH_PROVIDER_ID $sqlite $dbPath
$runtime = Get-ProviderRuntime $selection
if (-not $runtime.ApiKey) { throw "The active CCSwitch provider has no API key." }
Add-RemoteModels $runtime

$configDir = Split-Path -Parent $generatedConfig
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$options = [ordered]@{ baseURL = $runtime.BaseUrl; apiKey = "{env:CCSWITCH_OPENCODE_API_KEY}" }
if ($runtime.ProviderConfig.options) {
  foreach ($property in $runtime.ProviderConfig.options.PSObject.Properties) {
    if ($property.Name -notin @("baseURL", "apiKey")) { $options[$property.Name] = Convert-ToHashtable $property.Value }
  }
}
$config = [ordered]@{
  '$schema' = "https://opencode.ai/config.json"
  provider = [ordered]@{ ccswitch = [ordered]@{ npm = $runtime.Npm; name = "CCSwitch: $($selection.Row.name)"; options = $options; models = $runtime.ModelMap } }
  model = "ccswitch/$($runtime.ModelId)"
}
[IO.File]::WriteAllText($generatedConfig, ($config | ConvertTo-Json -Depth 50), $utf8)

$env:CCSWITCH_OPENCODE_API_KEY = $runtime.ApiKey
$env:OPENCODE_CONFIG = $generatedConfig
Write-Host "CCSwitch [$($selection.AppType)] provider: $($selection.Row.name) | model: $($runtime.ModelId)"
try {
  & opencode @OpenCodeArgs
  $exitCode = $LASTEXITCODE
} finally {
  if (-not $customGeneratedConfig) { Remove-Item -LiteralPath $generatedConfig -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
