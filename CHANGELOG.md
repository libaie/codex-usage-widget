# Changelog

## 1.1.0 - 2026-08-11

- Added a native macOS 13+ app with Universal `arm64` and `x86_64` builds and the same ring, details, themes, languages, dragging, and edge snapping as Windows.
- Added a single-file Windows EXE while retaining the portable ZIP, VBS launcher, and checksum files.
- Added the shared local-session contract, isolated scan workers, and cross-platform parser, UI, package, and CI checks.
- Added write-free fictional demo modes: `-Demo` on Windows and `--demo` on macOS.
- Added platform-specific local state storage while preserving the same data-discovery and cumulative cache-token rules.

## 1.0.0 - 2026-08-10

- Added a draggable percentage ring with edge snapping and hover details.
- Added eight themes and five interface languages: Simplified Chinese, Traditional Chinese, English, Japanese, and Korean.
- Added local views for observed token usage, cache totals, and recently active tasks.
- Added hidden VBS and CMD launchers for starting the widget without a visible console window.
- Kept observation local: the widget makes no network requests, stores no credentials, and treats displayed values as best-effort readings from local Codex session data rather than official account or billing data.
