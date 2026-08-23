# Compatibility

## Verified support

| Component | Verified range | Notes |
| --- | --- | --- |
| Windows | Windows 10/11, PowerShell 5.1+ | Uses the system `sqlite3.exe` or the documented Anaconda/WinGet locations. |
| macOS/Linux | Python 3.9+ | Uses Python's built-in SQLite driver. |
| CCSwitch | `providers` table with `id`, `name`, `settings_config`, `meta`, `app_type`, `is_current` | The launcher rejects unknown/incomplete schemas before launch. |
| OpenCode | Current CLI with `OPENCODE_CONFIG` support | The launcher passes the selected model with `--model` unless the user supplied one. |

## Provider formats

- Native CCSwitch `opencode` providers are preferred.
- Legacy CCSwitch `codex` providers are translated through `@ai-sdk/openai-compatible`.
- Providers using a Responses-compatible endpoint may need `CCSWITCH_OPENCODE_NPM=@ai-sdk/openai`.
- API URLs must be explicit HTTPS URLs; HTTP is allowed only for localhost.

Run `opencode-ccswitch doctor --json` to see the detected schema, provider format, and dependency status. The JSON field `doctor_schema` is versioned independently from the launcher release.
