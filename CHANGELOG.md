# Changelog

## v0.1.1

- Fixed PowerShell remote installation when run through `irm | iex`.
- Pinned one-line installers to the `v0.1.1` release instead of the moving `main` branch.
- Removed the unsafe `website_url` fallback for API requests.
- Require HTTPS API base URLs, with HTTP allowed only for localhost.
- Disabled `/models` discovery by default; enable it explicitly with `CCSWITCH_MODEL_DISCOVERY`.
- Added `opencode-ccswitch doctor` without exposing API credentials.
- Restricted generated provider options to a small non-secret allowlist.
- Added regression tests for URL validation and credential filtering.
