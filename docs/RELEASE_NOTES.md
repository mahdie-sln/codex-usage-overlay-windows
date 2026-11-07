A compact, draggable, always-on-top Codex usage overlay and explicit
multi-account manager for Windows 11.

This release adds optional paid-access end dates, days left, and OpenAI banked
reset counts. It fetches the current paid-period date and renewal status from
OpenAI when account authorization succeeds. After a local logout, a signed-out email reminder stays in
the account panel; click it to open OpenAI device sign-in, or right-click to
forget it. Device login requires the one-time code and the user to choose the
email and enter credentials. The current paid period may renew automatically.

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

The overlay has no telemetry, updater, or project-owned backend. It delegates
account actions to the separately installed `codex-auth` tool. It reads local
account snapshots to query banked resets from OpenAI. Review the README,
privacy statement, and upstream
dependency notice before installation.

The matching `.sha256` asset contains the archive's SHA-256 checksum.
