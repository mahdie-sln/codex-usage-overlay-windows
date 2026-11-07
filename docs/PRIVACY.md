# Privacy

Codex Usage Overlay & Multi-Account Manager is a local Windows utility. It has
no analytics, telemetry, advertising, crash-report upload, update server, or
project-operated backend.

## Local data read

The overlay invokes the separately installed `codex-auth` command. That tool
reads its own locally managed account/authentication data. The overlay receives
the formatted account list, plan labels, remaining percentages, reset times,
and active-row marker from the command's standard output.

Raw command output is held in memory only. It is not written to project files or
logs. Authentication tokens, cookies, and authorization headers are never
displayed or logged by the overlay.

The overlay also reads each `codex-auth` account snapshot in memory to obtain
the existing access token. It sends read-only GET requests to OpenAI's usage
and subscriptions endpoints for the available banked-reset count, paid-period
date, and renewal status. Tokens and raw responses are never saved.

## Network access

The overlay runs:

```text
codex-auth list --api
```

According to the upstream `codex-auth` documentation, API mode sends the
locally stored ChatGPT access token to these OpenAI endpoints:

- `https://chatgpt.com/backend-api/wham/usage`
- `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`

The upstream project warns that API mode may carry account or terms-of-service
risk. Installation requires explicit consent before this refresh is enabled.
The overlay's additional GET requests go only to
`https://chatgpt.com/backend-api/wham/usage` and
`https://chatgpt.com/backend-api/subscriptions`. They use the same local account
token and do not perform account-changing requests.

## Local files written

The installed directory may contain:

- `config.json`: non-secret user settings and optional account expiry dates.
- `account-extras-cache.json`: account email, banked reset count, paid-period
  date, and renewal status only; refreshed every five minutes.
- `signed-out-accounts.json`: email and plan label reminders for local logins
  the user explicitly removed. It contains no authentication data.
- `position.json`: the last overlay position.
- `runtime-status.json`: process state and active-account usage totals, without
  email addresses or credentials.
- `warning-state.json`: warning deduplication state.
- `logs\overlay.log`: timestamps, percentages, reset state, and safe error codes.

Logs do not contain account labels, email addresses, raw command output,
authentication values, cookies, or request headers.

## User-triggered account actions

Clicking an inactive account runs `codex-auth switch --skip-api` after validating
that the selected row still identifies the same account. Clicking **New login**
runs `codex-auth login --device-auth` in a visible terminal. No account-changing
command runs without a corresponding user click.

Clicking a signed-out reminder starts `codex-auth login --device-auth` in a
visible terminal and opens OpenAI's device page. Codex displays a one-time code;
the overlay cannot select an email or handle the password. When the selected
email appears again in the local list, its
reminder is removed. Right-click **Forget saved email** removes only the local
reminder. A manually entered paid-access end date stays in `config.json` until
the user clears it.

Right-clicking an account and choosing **Log out & remove** requires a second
confirmation, then runs `codex-auth remove <email>` only after revalidating the
row number, label hash, and exact email in the current local account list. The
upstream CLI rejects the combination `remove --skip-api <email>`; `--skip-api`
is only valid for its interactive remove mode. The exact-query form removes the
local login snapshot/registry entry supported by `codex-auth`; there is no
separate upstream logout command and no online account deletion. The helper
discards all command output, verifies the email disappeared from the local list,
and never logs account labels or authentication data.
