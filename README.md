# CCSwitch OpenCode Launcher

Automatically sync the active CCSwitch provider into OpenCode every time you launch it.

The launcher reads the current Codex provider from CCSwitch, discovers its available models, passes the API credential only to the child OpenCode process, generates a temporary OpenCode configuration, and starts OpenCode with that configuration.

## Requirements

- Windows 10 or later
- [CCSwitch](https://github.com/farion1231/cc-switch)
- [OpenCode](https://opencode.ai/)
- PowerShell 5.1 or later
- `sqlite3.exe` available on `PATH`

CCSwitch stores its provider database at `%USERPROFILE%\.cc-switch\cc-switch.db`. Install SQLite with `winget install SQLite.SQLite` if `sqlite3.exe` is not already available.

## Install

Clone this repository, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The default install location is `%APPDATA%\npm`, which is normally already on the user `PATH`.

## Use

Switch providers in CCSwitch and run:

```powershell
opencode-ccswitch
```

You can pass any normal OpenCode arguments:

```powershell
opencode-ccswitch run "Inspect this project and add tests"
opencode-ccswitch --model ccswitch/deepseek-chat
```

The wrapper re-syncs on every launch. It does not modify your regular OpenCode config or `auth.json`; it uses a per-process temporary config and removes it when OpenCode exits.

## Optional environment variables

Use these when CCSwitch or OpenCode uses a non-default location:

```powershell
$env:CCSWITCH_HOME = "D:\\path\\to\\.cc-switch"
$env:CCSWITCH_DB = "D:\\path\\to\\cc-switch.db"
$env:CCSWITCH_PROVIDER_ID = "provider-id"
$env:OPENCODE_GENERATED_CONFIG = "D:\\path\\to\\opencode.generated.json"
```

By default, the launcher follows CCSwitch's `currentProviderCodex` setting. `CCSWITCH_PROVIDER_ID` is useful for testing a specific provider.

## Security

API credentials are read locally and passed through a child-process environment variable. They are never printed or included in the generated configuration. Do not commit `%USERPROFILE%\.cc-switch`, OpenCode credential files, or generated configs. `OPENCODE_GENERATED_CONFIG` is optional and should point to a private path.

## License

MIT
