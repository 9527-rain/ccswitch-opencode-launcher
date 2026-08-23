# Security Policy

## Scope

This launcher reads CCSwitch data locally and passes the selected API key only to the OpenCode child process. It does not intentionally write `auth.json`, commit credentials, or print secret values.

## Reporting a vulnerability

Please do not open a public issue for a credential leak, malicious download, or remote-code-execution report. Use GitHub's private vulnerability reporting for this repository, or contact the maintainer privately through the repository profile.

Include the affected version, platform, reproduction steps, and redacted logs. Never include API keys or CCSwitch database files.

## Installation safety

- Prefer a tagged Release installer over a moving branch URL.
- Release archives are checked against `checksums.txt` before installation.
- Review `doctor --json` before launching if a provider or endpoint looks unexpected.
- Keep `CCSWITCH_LAUNCHER_RELEASE_BASE` unset unless using a trusted mirror.
