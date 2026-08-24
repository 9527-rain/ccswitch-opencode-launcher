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
  $sqliteCommand = if ($env:CCSWITCH_SQLITE) { $env:CCSWITCH_SQLITE } else { (Get-Command sqlite3.exe).Source }
  & $sqliteCommand $db ".read $sqlFile"
  if ($LASTEXITCODE -ne 0) { throw "sqlite3 fixture setup failed" }
  $oldHome = $env:CCSWITCH_HOME
  $oldDb = $env:CCSWITCH_DB
  $oldSqlite = $env:CCSWITCH_SQLITE
  $env:CCSWITCH_HOME = $root
  $env:CCSWITCH_DB = $db
  $env:CCSWITCH_SQLITE = $sqliteCommand
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
  $fakeOpenCode = Join-Path $root "opencode.cmd"
  $fakeContent = @(
    "@echo off",
    "echo ARGS=%*",
    "if defined CCSWITCH_OPENCODE_API_KEY echo KEY_CONFIGURED",
    "if defined OPENCODE_CONFIG echo CONFIG_CONFIGURED",
    "exit /b 0"
  ) -join "`r`n"
  Set-Content -LiteralPath $fakeOpenCode -Value $fakeContent -Encoding ASCII
  $oldPath = $env:PATH
  $oldHome = $env:CCSWITCH_HOME
  $oldDb = $env:CCSWITCH_DB
  $oldSqlite = $env:CCSWITCH_SQLITE
  $env:PATH = "$root;$oldPath"
  $env:CCSWITCH_HOME = $root
  $env:CCSWITCH_DB = $db
  $env:CCSWITCH_SQLITE = $sqliteCommand
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "..\opencode-ccswitch.ps1") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $output }
    if ($output -notmatch 'ARGS=--model ccswitch/demo') { throw "launcher did not inject the selected model: $output" }
    if ($output -notmatch 'KEY_CONFIGURED' -or $output -notmatch 'CONFIG_CONFIGURED') { throw "launcher did not configure the child process environment: $output" }
  } finally {
    $env:PATH = $oldPath
    $env:CCSWITCH_HOME = $oldHome
    $env:CCSWITCH_DB = $oldDb
    $env:CCSWITCH_SQLITE = $oldSqlite
  }
  $missingRoot = Join-Path $root "missing"
  New-Item -ItemType Directory -Path $missingRoot -Force | Out-Null
  $oldHome = $env:CCSWITCH_HOME
  $env:CCSWITCH_HOME = $missingRoot
  try {
    $doctor = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "..\opencode-ccswitch.ps1") doctor --json --strict 2>&1 | Out-String
    if ($LASTEXITCODE -ne 1) { throw "strict doctor should fail for a missing database: $doctor" }
    $diagnostic = $doctor | ConvertFrom-Json
    if ($diagnostic.issues.code -notcontains "database_missing") { throw "doctor did not report database_missing: $doctor" }
  } finally {
    $env:CCSWITCH_HOME = $oldHome
  }
  Write-Host "Windows integration test passed"
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
