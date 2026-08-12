# Contributing

Keep pull requests focused and preserve Windows/macOS behavior parity. A Developer ID is not required for development, tests, or unsigned local builds.

## Prerequisites

| Work | Requirement |
|---|---|
| Windows app and package | Windows, Windows PowerShell 5.1, WPF, .NET Framework compiler |
| macOS app and tests | macOS 13+, current Xcode command-line tools |
| Contract, docs, and locale changes | Either platform; CI runs both platform suites |
| Public notarized DMG | Apple Developer Program membership, Developer ID Application certificate, and a real Mac |

## Run the demo

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -Demo
```

macOS after a local build:

```bash
open .build/Build/Products/Debug/CodexUsageWidget.app --args --demo
```

Both `-Demo` and `--demo` use `fixtures/contract/v1/inputs/demo.jsonl`. Demo mode must not read real Codex data or write widget state.

## Source map

| Area | Location |
|---|---|
| Windows parser, state, worker, and WPF UI | `CodexUsageWidget.ps1` |
| Windows EXE bootstrap | `windows/Bootstrap/Program.cs` |
| Windows packaging | `scripts/Build-Windows.ps1` |
| macOS parser and state | `macos/CodexUsageWidget/Core/UsageCore.swift` |
| macOS AppKit/SwiftUI UI | `macos/CodexUsageWidget/UI/WidgetUI.swift` |
| Shared behavior contract | `fixtures/contract/v1/` |
| Five locale packs | `locales/` |
| Cross-platform CI | `.github/workflows/ci.yml` |
| Architecture and release rules | `DESIGN.md`, `README.md` |

The contract is the cross-platform source of truth. When changing parsing or selection behavior, add or update the smallest fixture and make both implementations produce the same normalized state.

## Windows checks

Run from the repository root in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -SelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-Contract.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-WindowsDataBoundary.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-WorkerStability.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-Bootstrap.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-Launcher.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-ReleasePackage.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Windows.ps1
.\dist\candidate\CodexUsageWidget-v1.1.0-windows.exe --self-test
```

## macOS checks and unsigned build

```bash
xcodebuild -project macos/CodexUsageWidget.xcodeproj \
  -scheme CodexUsageWidget \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  MARKETING_VERSION=1.1.0 \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild -project macos/CodexUsageWidget.xcodeproj \
  -scheme CodexUsageWidget \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build \
  MARKETING_VERSION=1.1.0 \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

lipo -archs .build/Build/Products/Release/CodexUsageWidget.app/Contents/MacOS/CodexUsageWidget
```

The final command must report both `arm64` and `x86_64`. No signing certificate is needed for this build.

## Locales, screenshots, and reports

Every locale must contain the same keys and format placeholders as `locales/en-US.json`. Keep user-facing text natural in all five languages.

Screenshots and fixtures must use fictional demo data. Never include real task names, session records, account information, credentials, preferences, cache ledgers, reminders, or local paths. Bug reports should include the platform, app version, exact steps, expected and actual behavior, and sanitized logs only.

Before submitting, check `git diff --check` and confirm the relevant commands above pass. Public signing and notarization remain maintainer-only steps; unsigned CI candidates must not be presented as a public release.
