$ErrorActionPreference = "Stop"
$root = Join-Path $env:TEMP ("ccswitch-opencode-test-" + [guid]::NewGuid().ToString("N"))
$db = Join-Path $root "cc-switch.db"
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
  $settingsConfig = @{ auth = @{ OPENAI_API_KEY = "secret-key" }; options = @{ baseURL = "https://api.example.test/v1" }; models = @{ demo = @{ name = "Demo" } } } | ConvertTo-Json -Compress
  $meta = @{ model = "demo" } | ConvertTo-Json -Compress
  $settingsSql = $settingsConfig.Replace("'", "''")
  $metaSql = $meta.Replace("'", "''")
  $schema = "CREATE TABLE providers (id TEXT, name TEXT, settings_config TEXT, meta TEXT, website_url TEXT, app_type TEXT, is_current INTEGER); INSERT INTO providers VALUES ('p1','Windows Test','$settingsSql','$metaSql','https://example.test','opencode',1);"
  $sqlFile = Join-Path $root "fixture.sql"
  [IO.File]::WriteAllText($sqlFile, $schema, [Text.Encoding]::UTF8)
  & sqlite3.exe $db ".read $sqlFile"
  if ($LASTEXITCODE -ne 0) { throw "sqlite3 fixture setup failed" }
  $oldHome = $env:CCSWITCH_HOME
  $oldDb = $env:CCSWITCH_DB
  $oldSqlite = $env:CCSWITCH_SQLITE
  $env:CCSWITCH_HOME = $root
  $env:CCSWITCH_DB = $db
  $env:CCSWITCH_SQLITE = (Get-Command sqlite3.exe).Source
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "..\opencode-ccswitch.ps1") --dry-run 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $output }
    if ($output -notmatch '"model":\s+"ccswitch/demo"') { throw "dry-run did not select fixture model: $output" }
    if ($output -match "secret-key") { throw "dry-run leaked API key" }
  } finally {
    $env:CCSWITCH_HOME = $oldHome
    $env:CCSWITCH_DB = $oldDb
    $env:CCSWITCH_SQLITE = $oldSqlite
  }
  Write-Host "Windows integration test passed"
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
