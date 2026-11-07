# Architecture

The application is a user-level PowerShell and WPF utility. It has no service,
project-owned backend, analytics, or updater.

## Components

| Component | Responsibility |
| --- | --- |
| `CodexUsageOverlay.ps1` | Renders the no-activation WPF bar, account panel, and tray controls. |
| `CodexOverlayWatcher.ps1` | Starts the overlay while Codex is running and stops it after Codex exits. |
| `Get-CodexAccounts.ps1` | Runs `codex-auth list --api` and converts its table output to bounded JSON fields. |
| `Get-AccountExtras.ps1` | Reads local account snapshots in memory and queries OpenAI usage and subscriptions endpoints for banked resets and the live paid-period date. |
| `AccountStatus.ps1` | Calculates days from paid-access dates and validates the local signed-out email reminder file. |
| `Switch-CodexAccount.ps1` | Revalidates a selected row, then performs one explicit account switch. |
| `Remove-CodexAccount.ps1` | Revalidates the selected account and removes only that local login. |
| `Start-CodexAuthLogin.ps1` | Opens device login for new accounts or browser login for a signed-out reminder. |
| `Install.ps1` / `Uninstall.ps1` | Manage per-user files, shortcuts, and the scheduled watcher task. |

## Runtime flow

1. The user-level scheduled task starts the watcher at sign-in.
2. The watcher checks only local processes and launches one overlay instance when
   the Codex desktop app is running.
3. After explicit API consent, the overlay asks the usage reader for refreshed
   account data every 60 seconds by default.
4. The reader invokes the separately installed `codex-auth` executable. Raw CLI
   output stays in memory; only parsed usage fields reach the overlay.
5. Login, switch, and remove operations run only after an explicit UI action.

## Trust boundaries

- The overlay reads `codex-auth` account snapshots in memory for the existing
  access token. It never writes to those snapshots.
- `codex-auth` handles the usage table and all user-triggered account actions.
  The extras helper makes GET requests only to OpenAI's usage and subscriptions
  endpoints.
- Account selection helpers re-read the current list and verify the selected
  row before changing local account state.
- The signed-out reminder file contains email addresses and plan labels only.
  Logs contain no account labels, emails, or authentication values.

See [PRIVACY.md](PRIVACY.md) for the data-access model and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency ownership.
