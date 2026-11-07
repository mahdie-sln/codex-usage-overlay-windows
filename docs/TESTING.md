# Testing

Use a Windows 11 user account where `codex-auth list --api` already works. Read
the API notice in `README.md` and `PRIVACY.md` before installing.

## Automated checks

```powershell
.\tests\Test-Package.ps1
.\tests\Test-UsageParser.ps1
.\tests\Test-AccountStatus.ps1
.\tests\Test-InstallCycle.ps1
.\tools\Build-Release.ps1
```

These commands validate package contents and syntax, exercise the usage parser
against isolated fixture data, test upgrade/install/uninstall behavior in
temporary directories, and create the versionless release archive plus its
SHA-256 checksum. They do not run the real `codex-auth` executable.

## Checklist

1. Verify the ZIP checksum supplied with the release.
2. Extract the ZIP and run `Install.ps1`.
3. Confirm the bar displays 5-hour and weekly remaining percentages.
4. Compare values and reset times with `codex-auth list --api`.
5. Confirm refresh updates within 60 seconds.
6. Drag the bar and confirm its position survives a restart.
7. Open the account panel and confirm it closes after clicking elsewhere.
8. Confirm Always-on-Top and normal Codex keyboard focus.
9. Verify the plain reset number matches the available banked resets in
   OpenAI Usage & Billing. It must appear even when no end date is entered.
   Right-click an account to enter a known paid-access end date using the
   Year, Month, and Day fields. Confirm that the live date takes precedence and
   the manual date is used only when the live request fails.
10. If intentionally testing logout, confirm the selected email remains as a
    signed-out reminder. Clicking it should open the OpenAI device page and
    show a one-time code; the user must enter the code and choose that email
    in the browser. After sign-in, refresh and confirm
    the reminder disappears. Do not run this check on an account you cannot
    sign back in to.
11. Exit the overlay, close and reopen Codex, and confirm automatic restart.
12. Test account switching only if you intentionally want to change the active
    account; restart Codex afterward.
13. Run `Uninstall.ps1` and confirm shortcuts, task, and installed files are gone.
14. Confirm `codex-auth` and all signed-in accounts remain unchanged except for
    any login or logout you intentionally tested.

## Safe feedback

Include Windows version, the overlay release tag or commit ID, `codex-auth` version, steps to
reproduce, and expected/actual behavior. Before attaching screenshots, blur all
email addresses and account labels.

Do not attach raw `codex-auth` output, configuration files, authentication files,
cookies, tokens, authorization headers, API keys, or session data.
