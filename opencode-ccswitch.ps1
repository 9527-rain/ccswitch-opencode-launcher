[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$OpenCodeArgs
)

$ErrorActionPreference = "Stop"
$LauncherVersion = "0.3.0"

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
  $errors = [IO.Path]::GetTempFileName()
  try {
    $output = (& $Executable -readonly -json -noheader $Database $Query 2> $errors) -join "`n"
    if ($LASTEXITCODE -ne 0) {
      $message = Get-Content -LiteralPath $errors -Raw -ErrorAction SilentlyContinue
      throw "sqlite3.exe failed: $message"
    }
  } finally {
    Remove-Item -LiteralPath $errors -Force -ErrorAction SilentlyContinue
  }
  if (-not $output) { return $null }
  try { $value = $output | ConvertFrom-Json } catch { throw "sqlite3.exe must support the -json option. Update SQLite: $($_.Exception.Message)" }
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

function Assert-BaseUrl([string]$BaseUrl, [string]$ProviderName) {
  $value = $BaseUrl.Trim().TrimEnd("/")
  if (-not $value) { throw "Provider $ProviderName has no explicit API base URL." }
  $uri = $null
  if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @("https", "http")) {
    throw "Provider $ProviderName has an invalid API base URL."
  }
  if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw "API base URL must not include credentials, query parameters, or fragments."
  }
  if ($uri.Scheme -ne "https" -and $uri.Host -notin @("localhost", "127.0.0.1", "::1")) {
    throw "API base URL must use HTTPS (HTTP is allowed only for localhost)."
  }
  return $value
}

function Get-DisplayBaseUrl([string]$BaseUrl) {
  $uri = [Uri]$BaseUrl
  return "$($uri.Scheme)://$($uri.Host)$(if ($uri.IsDefaultPort) { '' } else { ':' + $uri.Port })$($uri.AbsolutePath)".TrimEnd("/")
}

function Get-SafeOptions($ProviderConfig, [string]$BaseUrl) {
  $result = [ordered]@{ baseURL = $BaseUrl; apiKey = "{env:CCSWITCH_OPENCODE_API_KEY}" }
  $options = Get-ObjectValue $ProviderConfig "options"
  $allowed = @("organization", "project", "compatibility", "fetch", "timeout")
  if ($options) {
    foreach ($property in $options.PSObject.Properties) {
      if ($property.Name -in $allowed -and $property.Name -notmatch '(?i)(api.?key|token|secret|password|credential)') {
        $result[$property.Name] = Sanitize-Value $property.Value
      }
    }
  }
  return $result
}

function Sanitize-Value($Object) {
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in $Object.Keys) {
      if ([string]$key -notmatch '(?i)(api.?key|token|secret|password|credential|authorization|cookie)') {
        $result[$key] = Sanitize-Value $Object[$key]
      }
    }
    return $result
  }
  if ($Object -is [pscustomobject]) {
    $result = [ordered]@{}
    foreach ($property in $Object.PSObject.Properties) {
      if ($property.Name -notmatch '(?i)(api.?key|token|secret|password|credential|authorization|cookie)') {
        $result[$property.Name] = Sanitize-Value $property.Value
      }
    }
    return $result
  }
  if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
    return @($Object | ForEach-Object { Sanitize-Value $_ })
  }
  return $Object
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
  if (-not $row -and -not $RequestedAppType -and $appType -eq "opencode") {
    return Get-ProviderSelection $Settings "codex" $RequestedProviderId $Sqlite $Database
  }
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
    if ($models) { foreach ($property in $models.PSObject.Properties) { $modelMap[$property.Name] = Sanitize-Value $property.Value } }
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
  $baseUrl = Assert-BaseUrl $baseUrl ([string]$row.name)
  if (-not $modelId) { $modelId = "default" }
  return [pscustomobject]@{ ProviderConfig = $providerConfig; Npm = $npm; BaseUrl = $baseUrl.TrimEnd("/"); ModelId = $modelId; ReasoningEffort = $reasoningEffort; ModelMap = $modelMap; ApiKey = Resolve-ApiKey $providerConfig }
}

function Add-RemoteModels($Runtime) {
  Assert-DiscoveryMode
  if ($env:CCSWITCH_MODEL_DISCOVERY -in @("best-effort", "required")) {
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

function Assert-DiscoveryMode {
  if ($env:CCSWITCH_MODEL_DISCOVERY -and $env:CCSWITCH_MODEL_DISCOVERY -notin @("never", "best-effort", "required")) {
    throw "CCSWITCH_MODEL_DISCOVERY must be never, best-effort, or required."
  }
}

function Invoke-Maintenance([string]$Action) {
  $installer = Join-Path $PSScriptRoot "install.ps1"
  if (-not (Test-Path -LiteralPath $installer)) { throw "Maintenance requires install.ps1 beside the launcher. Reinstall from a GitHub Release." }
  if ($Action -eq "update") {
    & $installer -InstallDir $PSScriptRoot -Latest
  } else {
    & $installer -InstallDir $PSScriptRoot -Uninstall
  }
  exit $LASTEXITCODE
}

if ($OpenCodeArgs.Count -eq 1 -and $OpenCodeArgs[0] -eq "--version") {
  Write-Output "CCSwitch OpenCode Launcher v$LauncherVersion"
  exit 0
}
if ($OpenCodeArgs.Count -eq 1 -and $OpenCodeArgs[0] -in @("update", "uninstall")) {
  Invoke-Maintenance $OpenCodeArgs[0]
}

$ccRoot = if ($env:CCSWITCH_HOME) { $env:CCSWITCH_HOME } else { Join-Path $env:USERPROFILE ".cc-switch" }
$dbPath = if ($env:CCSWITCH_DB) { $env:CCSWITCH_DB } else { Join-Path $ccRoot "cc-switch.db" }
$settingsPath = Join-Path $ccRoot "settings.json"
$customGeneratedConfig = [bool]$env:OPENCODE_GENERATED_CONFIG
$generatedConfig = if ($customGeneratedConfig) { $env:OPENCODE_GENERATED_CONFIG } else { Join-Path $env:TEMP "ccswitch-opencode-$PID.json" }
if (-not (Test-Path -LiteralPath $dbPath)) { throw "CCSwitch database not found: $dbPath" }
$sqlite = Get-SqliteExecutable
$settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$selection = Get-ProviderSelection $settings $env:CCSWITCH_APP_TYPE $env:CCSWITCH_PROVIDER_ID $sqlite $dbPath
$runtime = Get-ProviderRuntime $selection
$dryRun = $OpenCodeArgs -contains "--dry-run"
Assert-DiscoveryMode
if ($OpenCodeArgs.Count -gt 0 -and $OpenCodeArgs[0] -in @("doctor", "--doctor")) {
  $doctorArgs = @($OpenCodeArgs | Select-Object -Skip 1)
  if (@($doctorArgs | Where-Object { $_ -ne "--json" }).Count -gt 0) { throw "doctor accepts only --json" }
  $openCodeCommand = Get-Command opencode -ErrorAction SilentlyContinue
  $doctor = [ordered]@{
    launcher_version = $LauncherVersion
    platform = [Environment]::OSVersion.Platform.ToString()
    powershell = [ordered]@{ version = $PSVersionTable.PSVersion.ToString(); supported = $PSVersionTable.PSVersion -ge [version]"5.1" }
    ccswitch = [ordered]@{ home = $ccRoot; database = $dbPath; sqlite = $sqlite }
    provider = [ordered]@{
      name = $selection.Row.name
      app_type = $selection.AppType
      model = $runtime.ModelId
      api_base_url = Get-DisplayBaseUrl $runtime.BaseUrl
      api_key = if ($runtime.ApiKey) { "configured" } else { "missing" }
    }
    opencode = [ordered]@{ status = if ($openCodeCommand) { "found" } else { "missing" }; path = if ($openCodeCommand) { $openCodeCommand.Source } else { $null } }
    model_discovery = if ($env:CCSWITCH_MODEL_DISCOVERY) { $env:CCSWITCH_MODEL_DISCOVERY } else { "never" }
  }
  if ($doctorArgs -contains "--json") {
    $doctor | ConvertTo-Json -Depth 10
    exit 0
  }
  Write-Host "launcher version: $($doctor.launcher_version)"
  Write-Host "provider: $($doctor.provider.name)"
  Write-Host "app type: $($doctor.provider.app_type)"
  Write-Host "model: $($doctor.provider.model)"
  Write-Host "api base URL: $($doctor.provider.api_base_url)"
  Write-Host "api key: $($doctor.provider.api_key)"
  Write-Host "PowerShell: $($doctor.powershell.version) ($(if ($doctor.powershell.supported) { 'supported' } else { 'unsupported' }))"
  Write-Host "sqlite3: $($doctor.ccswitch.sqlite)"
  Write-Host "opencode: $($doctor.opencode.status)"
  Write-Host "model discovery: $($doctor.model_discovery)"
  exit 0
}
if (-not $runtime.ApiKey -and -not $dryRun) { throw "The active CCSwitch provider has no API key." }
if (-not $dryRun) {
  if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { throw "OpenCode was not found on PATH." }
  Add-RemoteModels $runtime
} elseif (-not $runtime.ModelMap.Contains($runtime.ModelId)) {
  $runtime.ModelMap[$runtime.ModelId] = [ordered]@{ name = $runtime.ModelId }
}
if ($dryRun -and $runtime.ReasoningEffort) {
  $entry = $runtime.ModelMap[$runtime.ModelId]
  if ($entry -isnot [System.Collections.IDictionary]) { $entry = Convert-ToHashtable $entry; $runtime.ModelMap[$runtime.ModelId] = $entry }
  $entry.options = [ordered]@{ reasoningEffort = $runtime.ReasoningEffort }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$options = Get-SafeOptions $runtime.ProviderConfig $runtime.BaseUrl
$sanitizedModels = [ordered]@{}
foreach ($modelId in $runtime.ModelMap.Keys) { $sanitizedModels[$modelId] = Sanitize-Value $runtime.ModelMap[$modelId] }
$config = [ordered]@{
  '$schema' = "https://opencode.ai/config.json"
  provider = [ordered]@{ ccswitch = [ordered]@{ npm = $runtime.Npm; name = "CCSwitch: $($selection.Row.name)"; options = $options; models = $sanitizedModels } }
  model = "ccswitch/$($runtime.ModelId)"
}
if ($dryRun) {
  $config | ConvertTo-Json -Depth 50
  exit 0
}
$configDir = Split-Path -Parent $generatedConfig
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
[IO.File]::WriteAllText($generatedConfig, ($config | ConvertTo-Json -Depth 50), $utf8)

Write-Host "CCSwitch [$($selection.AppType)] provider: $($selection.Row.name) | model: $($runtime.ModelId)"
try {
  $previousKey = $env:CCSWITCH_OPENCODE_API_KEY
  $previousConfig = $env:OPENCODE_CONFIG
  $env:CCSWITCH_OPENCODE_API_KEY = $runtime.ApiKey
  $env:OPENCODE_CONFIG = $generatedConfig
  $forwardedArgs = @($OpenCodeArgs | Where-Object { $_ -ne "--dry-run" })
  if (-not (@($forwardedArgs | Where-Object { $_ -eq "--model" -or $_ -like "--model=*" }).Count -gt 0)) {
    & opencode --model "ccswitch/$($runtime.ModelId)" @forwardedArgs
  } else {
    & opencode @forwardedArgs
  }
  $exitCode = $LASTEXITCODE
} finally {
  if ($null -eq $previousKey) { Remove-Item Env:CCSWITCH_OPENCODE_API_KEY -ErrorAction SilentlyContinue } else { $env:CCSWITCH_OPENCODE_API_KEY = $previousKey }
  if ($null -eq $previousConfig) { Remove-Item Env:OPENCODE_CONFIG -ErrorAction SilentlyContinue } else { $env:OPENCODE_CONFIG = $previousConfig }
  if (-not $customGeneratedConfig) { Remove-Item -LiteralPath $generatedConfig -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
