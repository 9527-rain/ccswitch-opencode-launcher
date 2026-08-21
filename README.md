# CCSwitch OpenCode Launcher

Launch OpenCode with the provider currently selected in [CCSwitch](https://github.com/farion1231/cc-switch). The launcher re-syncs on every start, so switching providers in CCSwitch takes effect the next time you run `opencode-ccswitch`.

## What it does

- Supports CCSwitch's native `opencode` providers and older `codex` providers.
- Reads the active provider, API endpoint, key, default model, and reasoning effort locally.
- Discovers models from an OpenAI-compatible `/models` endpoint when available.
- Uses OpenCode's custom `OPENCODE_CONFIG` override and a per-process temporary config.
- Passes the API key only to the child OpenCode process; it does not write `auth.json` or print the key.
- Keeps your regular OpenCode configuration untouched.

## Requirements

### Windows

- Windows 10 or later
- CCSwitch and OpenCode
- PowerShell 5.1 or later
- `sqlite3.exe` on `PATH` (the launcher also checks a standard Anaconda and WinGet location)

### macOS/Linux

- Python 3.9 or later
- CCSwitch and OpenCode

CCSwitch stores its data under `%USERPROFILE%\\.cc-switch` on Windows and `~/.cc-switch` on Unix-like systems by default.

## Install

### Windows (PowerShell)

From a cloned repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\\install.ps1
```

One-line install from GitHub:

```powershell
irm https://raw.githubusercontent.com/9527-rain/ccswitch-opencode-launcher/main/install.ps1 | iex
```

The installer copies the launcher to `%APPDATA%\\npm` and adds that directory to the user `PATH` when needed. Open a new terminal afterwards if PATH was changed.

### macOS/Linux

From a cloned repository:

```sh
./install.sh
```

One-line install from GitHub:

```sh
curl -fsSL https://raw.githubusercontent.com/9527-rain/ccswitch-opencode-launcher/main/install.sh | sh
```

The default install directory is `~/.local/bin`. Add it to `PATH` if the installer reports that it is missing.

## Use

Switch providers in CCSwitch, then run:

```text
opencode-ccswitch
```

All normal OpenCode arguments are forwarded:

```text
opencode-ccswitch run "Inspect this project and add tests"
opencode-ccswitch --model ccswitch/deepseek-chat
```

The launcher does not change an already-running OpenCode session. Start a new session after switching providers.

## Configuration and troubleshooting

By default, the launcher prefers CCSwitch's native `opencode` provider and falls back to the active `codex` provider when no OpenCode provider exists. You can override selection for testing:

```powershell
$env:CCSWITCH_APP_TYPE = "codex"
$env:CCSWITCH_PROVIDER_ID = "provider-id"
opencode-ccswitch --version
```

Useful overrides:

| Variable | Purpose |
| --- | --- |
| `CCSWITCH_HOME` | Override the CCSwitch data directory |
| `CCSWITCH_DB` | Override the SQLite database path |
| `CCSWITCH_SQLITE` | Explicit path to `sqlite3.exe` on Windows |
| `CCSWITCH_APP_TYPE` | Force `opencode` or `codex` provider selection |
| `CCSWITCH_PROVIDER_ID` | Force a specific provider ID |
| `CCSWITCH_OPENCODE_NPM` | Override the AI SDK package, such as `@ai-sdk/openai` |
| `CCSWITCH_MODEL_DISCOVERY` | `best-effort` (default), `never`, or `required` |
| `OPENCODE_GENERATED_CONFIG` | Keep the generated config at a chosen private path instead of a temporary file |

For a provider that only supports `/v1/responses`, set:

```powershell
$env:CCSWITCH_OPENCODE_NPM = "@ai-sdk/openai"
opencode-ccswitch
```

## Security

API credentials are read locally and passed through a child-process environment variable. They are never printed or stored in the generated config. Do not commit CCSwitch databases, OpenCode credential files, or generated configs.

## License

MIT
