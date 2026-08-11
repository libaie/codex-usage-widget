# v1.1.0 QA plan

This map binds all 32 release checks to an automated command or a named P9 E2E gate. P8 is complete only when the candidate workflow succeeds for one full commit SHA; P9 remains blocked until every external gate has signed evidence.

| # | Check | Evidence |
|---:|---|---|
| 1 | One version on both platforms | `VERSION` assertion in Windows and macOS CI jobs |
| 2 | Exact clean source commit | Three jobs verify the requested 40-character SHA; candidate assembly requires detached HEAD |
| 3 | Exact repository release inventory | `fixtures/Test-ReleasePackage.ps1` |
| 4 | No private paths, session state, credentials, or unexpected release files | Repository and RuntimeArchive modes of `Test-ReleasePackage.ps1` |
| 5 | Reviewed shared input cases | `fixtures/Test-Contract.ps1` and macOS `CoreTests.testReviewedContractFixtures` |
| 6 | Decimal, overflow, reset, and tightest-window parity | Contract expected-state comparison on both platforms |
| 7 | Five locale key, placeholder, size, and format parity | Windows `-SelfTest` and macOS `UIContractTests` |
| 8 | Eight theme identities and colors | Windows `-SelfTest` and `testThemeCatalogMatchesTheSharedEightThemes` |
| 9 | Windows parser and UI self-test | `CodexUsageWidget.ps1 -SelfTest` |
| 10 | Windows state, classification, path, and invalid-file boundaries | `fixtures/Test-WindowsDataBoundary.ps1` |
| 11 | Windows worker protocol and 256 KiB producer/consumer limits | `fixtures/Test-WindowsDataBoundary.ps1` producer and consumer rejection cases |
| 12 | Windows 30-file and 120-refresh stability | `fixtures/Test-WorkerStability.ps1` |
| 13 | Hidden launcher, single instance, and bounded cleanup | `fixtures/Test-Launcher.ps1` |
| 14 | Windows EXE/ZIP same bytes, exact payload, checksum, concurrency, and state isolation | CI executes `fixtures/Test-Bootstrap.ps1` |
| 15 | Windows demo uses reviewed data and writes no state | `-Demo` assertions in `-SelfTest` plus isolated native smoke |
| 16 | Windows 180/250 ms hover bridge, pin/Esc, four-point drag threshold, and edge snapping | `-SelfTest` interaction assertions plus P9 native smoke |
| 17 | Windows keyboard and accessibility labels | `-SelfTest` accessibility contract plus P5 native UI record |
| 18 | Windows five-language/eight-theme visual fit | P5 production-demo screenshots and font-width assertions |
| 19 | macOS parser and normalized state | `CoreTests.testReviewedContractFixtures` |
| 20 | macOS storage tri-state, directory precedence, and symlink containment | macOS CoreTests storage and path cases |
| 21 | macOS worker envelope, deadline, recovery, and read-only behavior | macOS CoreTests worker cases |
| 22 | macOS 30-file and 120-refresh resource stability | `testWorkerPerformanceAndResourceStability` |
| 23 | macOS single-instance declaration and writer lock | bundle assertion plus macOS lock tests |
| 24 | macOS demo uses the reviewed parser, recent dates, and no persistent state | `testDemoUsesTheReviewedFixtureWithoutASeparateParser` and `--demo` UI test |
| 25 | macOS hover, pin/Esc, drag, snap, and visible-frame placement | `UIContractTests` interaction and geometry cases |
| 26 | macOS ring/detail accessibility and no visual clipping | `WidgetUITests.testDemoRingAndDetailsAreAccessible` and CI screenshots |
| 27 | macOS five locale resources exactly match root packs | CI bundle `cmp` loop |
| 28 | Universal `arm64`/`x86_64`, no App Sandbox, Hardened Runtime | CI `lipo`, build-setting, and Info.plist checks |
| 29 | Fresh-checkout time-to-working, restart, update, and rollback path | Fresh Actions checkout, platform launch tests, README and release runbook checks |
| 30 | VoiceOver reading order and Reduce Motion on real hardware | P9 E2E: sanitized accessibility record on macOS 13+ |
| 31 | Notification allow/deny/click, Rosetta, and real dual-display hot-plug/snap | P9 E2E: signed real-Mac QA record |
| 32 | Developer ID signature, notarization ticket, staple, and Gatekeeper acceptance | P9 E2E: `codesign`, `notarytool`, `stapler`, and `spctl` evidence |

## Candidate evidence

The non-PR CI path downloads the exact `windows-unsigned` and `macos-unsigned` artifacts produced by its two successful jobs. It accepts exactly six internal files, rechecks every checksum, records each name, byte size, and SHA-256 in `candidate-manifest.json`, copies this 32/32 map, and uploads one 30-day unsigned-candidate artifact. Its artifact ID, artifact digest, and manifest SHA-256 are written to the workflow summary.

This artifact is internal P8 evidence. It is not the public macOS DMG and must not be tagged or released. P9 rebuilds the same commit in the protected environment after Developer ID credentials and real-Mac evidence are available.
