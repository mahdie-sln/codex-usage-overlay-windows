A compact, draggable, always-on-top Codex usage overlay and explicit
multi-account manager for Windows 11.

## Install

1. Download `CodexUsageOverlay-Windows.zip` and optionally its `.sha256` file.
2. Extract the archive.
3. Open PowerShell in the extracted folder and run
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1`.
4. Read the API notice and type `I AGREE` only if you accept the documented
   `codex-auth list --api` behavior.

## Highlights

- Remaining 5-hour and weekly usage with live reset countdowns.
- Compact, draggable, no-focus overlay and system-tray controls.
- Explicit local account refresh, switch, device login, and removal actions.
- User-level startup that shows the overlay while Codex is running.
- Safe preference migration from earlier test installations.

## Security and privacy

The overlay has no telemetry, updater, project-owned backend, or direct network
implementation. It delegates usage and account operations to the separately
installed `codex-auth` tool. Review the README, privacy statement, and upstream
dependency notice before installation.

The matching `.sha256` asset contains the archive's SHA-256 checksum.
