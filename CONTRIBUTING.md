# Contributing

Use Windows PowerShell 5.1. Keep pull requests focused on one change and avoid unrelated refactoring.

Before submitting a pull request, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -SelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-Launcher.ps1 -PackageRoot .
```

Every locale must contain the same string keys and format placeholders as `locales/en-US.json`. When changing a localized string, preserve that key and placeholder parity in all five locale files.

Screenshots and fixtures must use fictional data. Never include real task names, session records, account information, credentials, preferences, cache ledgers, reminders, or local paths.
