# Changelog

## v1.1.0

- Read available banked resets from the OpenAI usage response, independently of
  any account end date.
- Fetch the live paid-period date and renewal status from OpenAI, with a manual
  paid-access end-date fallback when the account cannot be queried.
- Rebuilt the date editor with a dark rounded window and separate Year, Month,
  and Day fields.

## Account end dates and sign-in reminders

- Added per-account manual paid-access end dates and days remaining.
- Preserved a minimal email and plan reminder after an explicit local logout.
  Clicking it opens Codex browser sign-in; the user selects the account there.
- Added a right-click action to forget a signed-out reminder without changing
  any Codex account.

## Initial public release

- Reorganized the repository into `src`, `docs`, `tests`, and `.github` areas.
- Moved documentation artwork under `docs/images` and aligned every guide image
  with the dark visual theme.
- Kept only the installer, uninstaller, license, and README as user-facing root
  files.
- Compact draggable always-on-top usage bar.
- Multi-account usage panel, explicit account switch, and device login.
- Codex-aware automatic startup and system-tray controls.
- User-level installer and safe uninstaller.
- Explicit consent gate for `codex-auth list --api` refresh.
- Right-click **Log out & remove** action with confirmation and stale-row
  protection; removes only the selected local `codex-auth` login.
- Account rows are sorted after each refresh by remaining capacity, with 0%
  accounts and errors grouped below healthy accounts.
- The account panel remains open and refreshes in place after a confirmed local
  login removal.
- Added an illustrated English install, usage, update, troubleshooting, and
  uninstall guide.
- Fixed upgrades from earlier test installations by disabling their watcher
  before stopping stale processes, migrating local preferences, and replacing
  autostart safely.
- Updated the uninstaller to clean both the current user-level location and the
  earlier `C:\Tools\CodexUsageOverlay` location without touching `codex-auth` or
  account data.
