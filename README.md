<div align="center">

# Codex Usage Widget

A small draggable Windows ring that keeps locally observed Codex usage visible and reveals the details on hover.

[Latest release](https://github.com/libaie/codex-usage-widget/releases/latest) · [MIT license](LICENSE) · **English** · [简体中文](README.zh-CN.md)

</div>

> [!IMPORTANT]
> This is an independent community project, not an official OpenAI or Codex project, and it is not affiliated with or endorsed by OpenAI. The widget is designed for local Codex sessions and reads a configured filesystem path; it does not call Web APIs, upload data, or synchronize it, and it stores no account credentials. Displayed values come from local session observations by default; a manually configured path becomes the source instead. They are not official billing or account data.

## Overview

Codex Usage Widget turns locally recorded Codex activity into a compact desktop percentage ring. Hovering the ring opens a localized detail card, while the normal desktop state stays minimal and unobtrusive.

## Quick start

1. Download `CodexUsageWidget-v1.0.0.zip` from the [latest release](https://github.com/libaie/codex-usage-widget/releases/latest) and extract it.
2. Double-click `Start-CodexUsageWidget.vbs`.
3. After local session data is available, wait up to about 15 seconds for the ring to refresh.

The VBS launcher starts the widget without a visible terminal window. `Start-CodexUsageWidget.cmd` remains available as a compatibility wrapper, and only one widget instance runs in the same Windows sign-in session. If the main script starts but initialization fails, an error message explains the problem, likely cause, and suggested fix; language-pack failures use a built-in English-and-Chinese fallback.

If the normal Codex directories cannot be found, the widget asks you to choose the `.codex` directory that contains `sessions`. Cancelling the picker does not cause repeated pop-ups; default locations continue to be checked on later refreshes.

## Languages

The interface includes Simplified Chinese (`zh-CN`), Traditional Chinese (`zh-TW`), English (`en-US`), Japanese (`ja-JP`), and Korean (`ko-KR`). On first launch, the widget follows the Windows UI language. Right-click the ring and choose **Language** to switch immediately; the choice is saved for later launches. Unsupported system languages and missing optional language packs fall back to English.

## Screenshots

<p align="center">
  <img src="assets/screenshots/widget-ring.png" alt="Codex usage percentage ring" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details.png" alt="Codex usage detail card with anonymized demo tasks" width="310">
</p>

<p align="center"><sub>Screenshots were rendered by the production UI with fictional, anonymized local demo data.</sub></p>

## Features

- Compact percentage-only ring that stays above normal windows.
- Free dragging with automatic snapping near the current screen edge.
- Five display languages: Simplified Chinese, Traditional Chinese, English, Japanese, and Korean.
- Eight synchronized themes: Glacier Cyan, Nebula Purple, Deep Sea Blue, Sakura Mist, Aurora Green, Mica Silver, Sunset Orange, and Lime Glow.
- A localized detail card on hover, including the limiting window, reset countdown, recently active tasks, token totals, context usage, input/output composition, and reasoning share.
- Per-task cache-hit and cache-miss tokens, plus a separate cumulative local cache ledger that never falls when the active task changes.
- Tasks updated within the last 30 minutes appear as lightweight capsules; hovering or focusing one reveals its own details.
- Tray controls, keyboard access, low-usage notifications, single-instance protection, and a built-in self-test.
- Designed for local session files, with no Web API calls, uploads, data synchronization, or credential storage.

## Requirements

- Windows with Windows PowerShell 5.1 and WPF components.
- A local Codex installation that has completed at least one task, so a `.codex\sessions` directory exists.
- No additional runtime or third-party package is required.

## Package contents

```text
CodexUsageWidget/
├── CodexUsageWidget.ps1
├── Start-CodexUsageWidget.vbs
├── Start-CodexUsageWidget.cmd
├── README.md
├── README.zh-CN.md
├── locales/
│   ├── zh-CN.json
│   ├── zh-TW.json
│   ├── en-US.json
│   ├── ja-JP.json
│   └── ko-KR.json
├── assets/screenshots/
└── fixtures/
    ├── rate-limits.jsonl
    └── Test-Launcher.ps1
```

`CodexUsageWidget.ps1` contains the UI, local data parser, cache ledger, interactions, and self-test. The VBS file is the recommended launcher; the command file is a compatibility wrapper. Files under `fixtures` are used only by the self-tests.

## Usage

| Interaction | Result |
|---|---|
| Hold the left mouse button and drag | Move the widget; release near an edge to snap it into place. |
| Hover for about 250 ms | Open the usage detail card. |
| Hover or focus an active task | Show that task's token, cache, and context data. |
| Right-click the ring | Open the language, theme, and exit menu. |
| Enter or Space while the ring is focused | Toggle the detail card. |
| Esc | Close the detail card. |
| Shift+F10 | Open the same context menu from the keyboard. |
| Tray menu | Show or exit the widget. |

The selected position and theme are also restored on the next launch. The detail accent color follows the ring theme; at 20% and 10% remaining, both views switch to warning and critical colors.

## Data directory discovery

The Codex data directory is resolved in this order:

1. A directory previously selected by the current user.
2. The `CODEX_HOME` environment variable.
3. `%USERPROFILE%\.codex`.
4. A manual folder selection when none of the above contains `sessions`.

| Purpose | Location |
|---|---|
| Codex session events | Resolved `.codex\sessions` directory, read only |
| Task name index | Resolved `.codex\session_index.jsonl`, read only when present |
| Widget position, theme, language, and manual data path | `%LOCALAPPDATA%\CodexUsageWidget\preferences.json` |
| Cumulative cache-token ledger | `%LOCALAPPDATA%\CodexUsageWidget\cache-token-ledger.json` |
| Reminder deduplication state | `%LOCALAPPDATA%\CodexUsageWidget\reminders.json` |

## How the numbers are calculated

### Usage gauge

Every 15 seconds, the widget reads valid events from local `.codex\sessions` files. The main ring uses only the Codex primary quota pool and ignores model-specific quota pools. Within the same reset cycle, parallel observations are merged using the highest observed usage; late observations from older cycles are ignored. When several valid windows exist, the gauge displays the one with the least remaining capacity.

The last observation remains visible until its corresponding window resets. After every observed window has reset, the widget displays a waiting state until a new cycle is recorded. A notification is sent once per reset cycle when remaining usage first reaches 20%, and once again at 10%.

### Active tasks

The list includes named primary tasks updated during the last 30 minutes, ordered from newest to oldest. Internal child tasks do not appear in the visible list. A task's context percentage is its most recent total-token count divided by the model context-window limit.

### Token and cache data

The selected task shows its own cumulative tokens, latest context usage, input/output composition, reasoning share, cache-hit tokens, and cache-miss tokens when those fields are available. Missing fields are hidden instead of being guessed.

The two local cumulative cache rows are independent of the selected task:

- Cache hit = cached input tokens already reused by Codex.
- Cache miss = cumulative input tokens minus cached input tokens.
- Each refresh adds only a session's newly observed increase.
- A lower or repeated snapshot cannot reduce or double-count the ledger.
- Internal child-task sessions still contribute to the cumulative local totals.

These are token quantities, not request counts and not official account-level statistics.

## Privacy

The widget does not scan the whole disk or read/store account credentials. It reads the filesystem path resolved from the saved selection, `CODEX_HOME`, or the current profile; a manually configured path can be a UNC path. The widget does not call Web APIs, upload data, or synchronize it. It writes its preferences, cumulative cache ledger, and reminder-deduplication state (`reminders.json`) under the current user's `%LOCALAPPDATA%\CodexUsageWidget` directory.

Theme and language changes affect presentation only. They do not change statistics, cache accumulation, token calculations, or quota data. Screenshots included in this project use fictional demo tasks and contain no real session or account data.

## Self-test

Open this directory in File Explorer, enter `powershell` in the address bar, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -SelfTest
```

A successful run prints only `自检通过。` (self-test passed). It normally completes in under five seconds, does not use the network, and does not modify Codex session records.

## Troubleshooting

| Symptom | Suggested action |
|---|---|
| The detail card says the local session directory was not found | Complete one Codex task, then wait about 15 seconds. |
| The selected directory has no local session records | Complete one Codex task and check again. |
| Session records cannot be read | Confirm that the current Windows account can read its own `.codex` directory, then restart the widget. |
| No recognizable usage event is available | Run the self-test. If it passes, keep the current build and wait for the next valid event. |
| The ring is off-screen | Exit the widget, rename `%LOCALAPPDATA%\CodexUsageWidget\preferences.json`, and launch it again. |
| The Codex data directory cannot be found | Run Codex once; for a custom location, restart the widget and select the `.codex` directory containing `sessions`. |
| A startup message reports a window or background-reader failure | Run the self-test; restore the previous directory backup if the self-test fails. |

## Updating and rollback

Exit the widget from the tray before updating. From the parent directory of `CodexUsageWidget`, create a timestamped backup:

```powershell
Copy-Item -LiteralPath .\CodexUsageWidget `
    -Destination ('.\CodexUsageWidget-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) `
    -Recurse
```

Replace the files, run the self-test, and start the widget again. To roll back, exit the current widget and double-click `Start-CodexUsageWidget.vbs` inside the backup directory; no data migration is required.

## Disclaimer

This project observes configured Codex session files and may stop recognizing fields if their format changes. Displayed limits, reset times, task activity, and token statistics are best-effort observations of those files—not official OpenAI usage, billing, or entitlement data. Always use official account pages for authoritative information.
