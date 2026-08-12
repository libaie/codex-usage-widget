<div align="center">

# Codex Usage Widget

A draggable usage ring for Windows and macOS. Hover to see locally observed Codex usage details.

[v1.0.0 release](https://github.com/libaie/codex-usage-widget/releases/latest) · [v1.1.0 CI builds](https://github.com/libaie/codex-usage-widget/actions/workflows/ci.yml) · [MIT license](LICENSE) · **English** · [简体中文](README.zh-CN.md)

</div>

> [!IMPORTANT]
> This is an independent personal project, not an official OpenAI or Codex project. It reads a configured local filesystem path and makes no Web API calls, uploads, or telemetry requests. Values are local session observations, not official billing or account data.

## Install

> [!NOTE]
> Version 1.1.0 source is on `main`. Successful CI runs retain the combined unsigned Windows and macOS candidate for 30 days. A signed public v1.1.0 release has not been published yet.

### Windows

Open the latest successful [v1.1.0 CI run](https://github.com/libaie/codex-usage-widget/actions/workflows/ci.yml), download `unsigned-candidate-v1.1.0-<commit SHA>`, and verify the included SHA-256 checksum before running `CodexUsageWidget-v1.1.0-windows.exe`. GitHub requires sign-in to download workflow artifacts.

The portable alternative is `CodexUsageWidget-v1.1.0-windows.zip`. Extract it and double-click `Start-CodexUsageWidget.vbs`; this launcher starts the widget without leaving a terminal window. `Start-CodexUsageWidget.cmd` is kept as a compatibility entry point.

### macOS

From the same combined candidate, verify `CodexUsageWidget-v1.1.0-macos-unsigned.zip.sha256`, extract the ZIP, and move `CodexUsageWidget.app` to Applications. This Universal build supports Apple silicon and Intel Macs on macOS 13 or later.

The CI app is not signed or notarized. On first launch, use Finder's **Open** command; if macOS still blocks it, use **System Settings → Privacy & Security → Open Anyway**. A Developer ID is not required to build, test, or run this unsigned build. It is required only for the planned signed and notarized `CodexUsageWidget-v1.1.0-macos.dmg`. Source-build commands are in [Contributing](CONTRIBUTING.md).

## Release files

| Channel | Files | Status |
|---|---|---|
| Windows CI | `CodexUsageWidget-v1.1.0-windows.exe`, `.exe.sha256`, `.zip`, and `.zip.sha256` | Included in the combined CI candidate |
| macOS CI | `CodexUsageWidget-v1.1.0-macos-unsigned.zip` and `.zip.sha256` | Included in the combined CI candidate |
| Planned public release | Authenticode-signed Windows files and notarized `CodexUsageWidget-v1.1.0-macos.dmg` with `CodexUsageWidget-v1.1.0-macos.dmg.sha256` | Waiting for signing identities |

Both platforms use version 1.1.0 because the version describes the feature set, not the operating system. A `v1.1.0` tag and its source archives will be created only with the signed public release; current source is on `main`.

## Screenshots

### Windows

<p align="center">
  <img src="assets/screenshots/widget-ring.png" alt="Windows Codex usage percentage ring" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details.png" alt="Windows Codex usage detail card" width="310">
</p>

### macOS

<p align="center">
  <img src="assets/screenshots/widget-ring-macos.png" alt="macOS Codex usage percentage ring" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details-macos.png" alt="macOS Codex usage detail card" width="310">
</p>

<p align="center"><sub>All screenshots are rendered by the production UI from fictional demo data.</sub></p>

## Features

- Percentage-only always-on-top ring with free dragging and screen-edge snapping.
- Hover details for the tightest limit, reset countdown, 30-minute active-task list, token totals, context use, input/output mix, reasoning share, and per-task cache tokens.
- A separate cumulative local cache-hit and cache-miss token ledger that does not fall when the selected task changes.
- Eight synchronized color themes and five languages: Simplified Chinese (`zh-CN`), Traditional Chinese (`zh-TW`), English (`en-US`), Japanese (`ja-JP`), and Korean (`ko-KR`).
- Keyboard access, single-instance protection, low-usage reminders, and bounded background scanning.

## Requirements

- Windows with Windows PowerShell 5.1 and WPF, or macOS 13 or later.
- At least one local Codex task so the selected `.codex` directory contains `sessions`.
- No third-party runtime for the packaged app.

## Use

| Interaction | Result |
|---|---|
| Drag the ring | Move it; releasing near a screen edge snaps it into place. |
| Hover for about 180 ms | Open the usage details. |
| Hover or focus an active task | Show that task's token, cache, and context data. |
| Right-click | Open language, theme, data-directory, reminder, and exit controls. |
| Enter or Space | Toggle details when the ring is focused. |
| Esc | Close details. |

The selected position, theme, language, and optional data directory are restored on the next launch. Unsupported system languages and missing optional packs fall back to English.

## Data discovery and storage

The data directory is resolved in this order on both platforms:

1. A directory previously selected by the user.
2. `CODEX_HOME`.
3. The current user's `.codex` directory.
4. A folder picker when none of those locations contains `sessions`.

| Purpose | Windows | macOS |
|---|---|---|
| Session events and optional task-name index | Resolved `.codex` directory, read only | Resolved `.codex` directory, read only |
| Position, theme, language, and manual data path | `%LOCALAPPDATA%\CodexUsageWidget\preferences.json` | `~/Library/Application Support/CodexUsageWidget/preferences.json` |
| Cumulative cache-token ledger | `%LOCALAPPDATA%\CodexUsageWidget\cache-token-ledger.json` | `~/Library/Application Support/CodexUsageWidget/cache-token-ledger.json` |
| Reminder deduplication state | `%LOCALAPPDATA%\CodexUsageWidget\reminders.json` | `~/Library/Application Support/CodexUsageWidget/reminders.json` |

## Demo mode

Demo mode uses the checked-in fictional contract fixture, does not read Codex data, and does not write preferences, cache ledgers, or `reminders.json`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -Demo
```

```bash
open CodexUsageWidget.app --args --demo
```

## Calculation notes

The widget refreshes local session observations about every 15 seconds. It displays the primary quota window with the least remaining capacity, merges same-cycle observations by their highest used percentage, and ignores late observations from older cycles. Active tasks are named primary tasks updated within the last 30 minutes.

Cache hit means cached input tokens reused by Codex. Cache miss means cumulative input tokens minus cached input tokens. Each refresh adds only newly observed per-session increases; repeated or lower snapshots cannot reduce or double-count the ledger. These are token quantities, not request counts.

## Privacy

The widget reads only the resolved filesystem path and does not scan the whole disk. It stores no account credentials and makes no Web API calls, uploads, synchronization, or telemetry requests. A manually selected path can be a network filesystem, in which case normal operating-system file access applies.

Only `preferences.json`, `cache-token-ledger.json`, and reminder deduplication state in `reminders.json` are written to the platform application-data directory. Theme and language changes affect presentation only. Demo screenshots contain no real task, session, account, or local-path data.

## Development and release

- [Contributing and source builds](CONTRIBUTING.md)
- [Architecture and trust boundaries](DESIGN.md)
- [Version history](CHANGELOG.md)

Public v1.1.0 publishing remains intentionally untagged until the Windows and macOS artifacts can be signed and the macOS build notarized. CI artifacts are testable unsigned candidates, not a public release.

The built-in Windows self-test is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -SelfTest
```

## Disclaimer

Local session formats may change. Displayed limits, reset times, task activity, and token statistics are best-effort observations, not authoritative OpenAI usage, billing, or entitlement data.
