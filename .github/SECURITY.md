# Security policy

## Supported version

Security fixes are applied to the latest public release.

## Report a vulnerability

Use GitHub's private vulnerability reporting feature for the repository. Do not
open a public issue containing credentials, account identifiers, command output,
local paths, or screenshots with email addresses.

Never submit authentication tokens, cookies, authorization headers, API keys,
session files, or the contents of any Codex/authentication directory.

## Security boundaries

- The overlay is a local user-level process and does not require administrator
  rights.
- `codex-auth` is an external dependency and is not bundled.
- Raw `codex-auth` output is processed in memory and discarded.
- Account switching is user-triggered and protected by row-label revalidation.
- Local account removal is user-triggered, requires a second confirmation, and
  is protected by row-number, label-hash, and exact-email revalidation before
  the exact-query `codex-auth remove <email>` command is invoked. The helper
  verifies that the email disappears from the local list before reporting
  success.
- The uninstaller removes only explicitly owned files, shortcuts, processes,
  and the matching current-user Scheduled Task.

This project is not an OpenAI product and cannot provide guarantees about the
behavior, security, availability, or policies of OpenAI or third-party tools.
