# Changelog

## v0.3.0

- Preserve OpenCode global/project configuration by generating only the provider/model override layer.
- Add `doctor --json`, `--version`, `update`, and `uninstall` maintenance commands.
- Include the versioned installer inside release archives so installed launchers can self-update.
- Extend diagnostics with runtime versions, paths, dependency status, and redacted API endpoint details.
- Run Windows PowerShell and Unix shell checks in CI and publish SHA256-checksummed archives.

## v0.2.1

- Reject API URLs containing embedded credentials, query parameters, or fragments.
- Restore the Windows parent PowerShell environment after launching OpenCode.
- Add actionable SQLite errors and validate JSON support on Windows.
- Make local Unix installs explicit and remote installs use Release assets with SHA256 verification.
- Align `--dry-run` reasoning effort output across platforms.

## v0.2.0

- Recursively remove credential-like fields from model metadata and generated config.
- Added `--dry-run` to preview sanitized config without launching OpenCode or contacting the provider.
- Unified provider fallback, model discovery validation, and doctor output across Windows and Python launchers.
- Added regression coverage for nested credential filtering and discovery mode validation.

## v0.1.1

- Fixed PowerShell remote installation when run through `irm | iex`.
- Pinned one-line installers to the `v0.1.1` release instead of the moving `main` branch.
- Removed the unsafe `website_url` fallback for API requests.
- Require HTTPS API base URLs, with HTTP allowed only for localhost.
- Disabled `/models` discovery by default; enable it explicitly with `CCSWITCH_MODEL_DISCOVERY`.
- Added `opencode-ccswitch doctor` without exposing API credentials.
- Restricted generated provider options to a small non-secret allowlist.
- Added regression tests for URL validation and credential filtering.
