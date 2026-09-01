# Testing

Use a Windows 11 user account where `codex-auth list --api` already works. Read
the API notice in `README.md` and `PRIVACY.md` before installing.

## Automated checks

```powershell
.\tests\Test-Package.ps1
.\tests\Test-UsageParser.ps1
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
9. Exit the overlay, close and reopen Codex, and confirm automatic restart.
10. Test account switching only if you intentionally want to change the active
    account; restart Codex afterward.
11. Run `Uninstall.ps1` and confirm shortcuts, task, and installed files are gone.
12. Confirm `codex-auth` and all signed-in accounts remain unchanged.

## Safe feedback

Include Windows version, the overlay release tag or commit ID, `codex-auth` version, steps to
reproduce, and expected/actual behavior. Before attaching screenshots, blur all
email addresses and account labels.

Do not attach raw `codex-auth` output, configuration files, authentication files,
cookies, tokens, authorization headers, API keys, or session data.
