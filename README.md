<div align="center">

# Codex Usage Widget

A polished, draggable Windows desktop widget for locally observed Codex usage, token, cache, and context data.

**English** · [简体中文](README.zh-CN.md)

</div>

> [!IMPORTANT]
> This is a community project and is not affiliated with or endorsed by OpenAI. Every value shown by the widget is derived from local Codex session records; it is not an official account balance or billing record.

## Overview

Codex Usage Widget turns locally recorded Codex activity into a compact desktop percentage ring. Hovering the ring opens a localized detail card, while the normal desktop state stays minimal and unobtrusive.

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
- Local-only reading with no network requests and no credential storage.

## Requirements

- Windows with Windows PowerShell 5.1 and WPF components.
- A local Codex installation that has completed at least one task, so a `.codex\sessions` directory exists.
- No additional runtime or third-party package is required.

## Installation

1. Keep the files in the `CodexUsageWidget` directory together.
2. Double-click `Start-CodexUsageWidget.vbs`.
3. After local session data is available, the ring refreshes automatically within about 15 seconds.

The VBS launcher starts the widget without a visible terminal window. `Start-CodexUsageWidget.cmd` remains available as a compatibility wrapper, and only one widget instance runs in the same Windows sign-in session. If startup fails, a Chinese message explains the problem, likely cause, and suggested fix.

If the normal Codex directories cannot be found, the widget asks you to choose the `.codex` directory that contains `sessions`. Cancelling the picker does not cause repeated pop-ups; default locations continue to be checked on later refreshes.

### Package contents

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

On first launch, the widget follows the Windows UI language. An unsupported Windows language or a missing optional language pack falls back to English. Right-click the ring and choose **Language** to switch immediately; the choice is saved for the next launch.

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

The widget does not scan the whole disk, inspect other Windows users, call a remote service, or read/store account credentials. It only reads local session records needed for the display and writes its own preferences and cumulative cache ledger under the current user's `%LOCALAPPDATA%` directory.

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

This project observes local Codex session files and may stop recognizing fields if their format changes. Displayed limits, reset times, task activity, and token statistics are best-effort local observations—not official OpenAI usage, billing, or entitlement data. Always use official account pages for authoritative information.
