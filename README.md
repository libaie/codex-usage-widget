<div align="center">

# Codex Usage Widget

A small, draggable desktop widget for viewing locally observed Codex usage on Windows and macOS.

[Download v1.1.0](https://github.com/libaie/codex-usage-widget/releases/tag/v1.1.0) · [简体中文](README.zh-CN.md) · [MIT license](LICENSE)

</div>

Codex Usage Widget reads local Codex session files and presents the remaining allowance, token usage, cache tokens, context use, and recently active tasks in a compact ring. It is an independent personal project, not an official OpenAI or Codex project. The values are local session observations, not official billing or account data.

## Screenshots

### Windows

<p align="center">
  <img src="assets/screenshots/widget-ring.png" alt="Windows Codex usage percentage ring" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details.png" alt="Windows Codex usage details" width="310">
</p>

### macOS

<p align="center">
  <img src="assets/screenshots/widget-ring-macos.png" alt="macOS Codex usage percentage ring" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details-macos.png" alt="macOS Codex usage details" width="310">
</p>

<p align="center"><sub>The screenshots use fictional demo data.</sub></p>

## Features

- An always-on-top percentage ring that can be dragged anywhere and snaps to nearby screen edges.
- Hover details for the current limit, reset time, token usage, context use, and tasks updated in the last 30 minutes.
- Per-task and cumulative cache-hit and cache-miss token totals.
- Eight color themes and five interface languages: Simplified Chinese (`zh-CN`), Traditional Chinese (`zh-TW`), English (`en-US`), Japanese (`ja-JP`), and Korean (`ko-KR`).
- Local data reading with no Web API calls, account credentials, uploads, or telemetry.

## Download and install

Downloads are available on the [v1.1.0 release page](https://github.com/libaie/codex-usage-widget/releases/tag/v1.1.0). The current Windows and macOS files are unsigned, so verify the accompanying SHA-256 file before opening them.

### Windows

Windows PowerShell 5.1 and WPF are required.

1. Download `CodexUsageWidget-v1.1.0-windows.exe` and its `.sha256` file.
2. Verify the checksum, then run the EXE.

For a portable installation, download `CodexUsageWidget-v1.1.0-windows.zip`, extract it, and double-click `Start-CodexUsageWidget.vbs`. The VBS launcher starts the widget without leaving a terminal window open.

### macOS

macOS 13 or later is required. The Universal build supports Apple silicon and Intel Macs.

1. Download `CodexUsageWidget-v1.1.0-macos-unsigned.zip` and its `.sha256` file.
2. Verify the checksum, extract the ZIP, and move `CodexUsageWidget.app` to Applications.
3. On first launch, Control-click the app in Finder and choose **Open**. If macOS still blocks it, use **System Settings → Privacy & Security → Open Anyway**.

The widget normally finds the current user's Codex data automatically. If it cannot find a `.codex` folder containing `sessions`, it asks you to choose the folder.

## Use

| Action | Result |
|---|---|
| Drag the ring | Move it; release near an edge to snap it into place. |
| Hover over the ring | Open usage details. |
| Hover or focus a task | View that task's token, cache, and context data. |
| Right-click the ring | Change the language, theme, data folder, or reminder settings; or exit. |
| Press Enter or Space | Open or close details when the ring has keyboard focus. |
| Press Esc | Close details. |

Position, theme, language, and the selected data folder are restored on the next launch.

## Privacy

The widget reads only the selected Codex data folder. It does not scan the whole drive, call a Web API, upload session files, or send telemetry. It stores the widget position, theme, language, selected folder, cumulative cache totals, and reminder history in the operating system's application-data folder.

## Open source

The project is available under the [MIT license](LICENSE). See [Contributing](CONTRIBUTING.md) for source builds, [Security](SECURITY.md) for reporting vulnerabilities, and the [Changelog](CHANGELOG.md) for version history.

## Disclaimer

Codex session formats can change. Displayed limits, reset times, task activity, and token statistics are best-effort observations from local files, not authoritative OpenAI usage, billing, or entitlement data.
