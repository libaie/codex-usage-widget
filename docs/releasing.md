# Release process

`VERSION` is the single product version for Windows and macOS. Version `1.1.0` describes one feature set; it is not split by platform.

## Public assets

A complete v1.1.0 release has exactly these application/checksum assets:

1. `CodexUsageWidget-v1.1.0-windows.exe`
2. `CodexUsageWidget-v1.1.0-windows.exe.sha256`
3. `CodexUsageWidget-v1.1.0-windows.zip`
4. `CodexUsageWidget-v1.1.0-windows.zip.sha256`
5. `CodexUsageWidget-v1.1.0-macos.dmg`
6. `CodexUsageWidget-v1.1.0-macos.dmg.sha256`

GitHub creates source archives from the same signed release tag. Do not upload an unsigned macOS archive as the public DMG.

## 1. No-secret candidate gates

These steps need no signing account or certificate.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -SelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-Contract.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\Test-ReleasePackage.ps1 -PackageRoot .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Windows.ps1
.\dist\candidate\CodexUsageWidget-v1.1.0-windows.exe --self-test
```

On a Mac, run the tests and unsigned Universal build from `CONTRIBUTING.md`, then verify `lipo -archs` reports `arm64 x86_64`. CI publishes these unsigned candidates only as private workflow artifacts.

If no Developer ID certificate or real Mac is available, stop here. Do not create the public `v1.1.0` tag or GitHub release.

## 2. Protected macOS signing and notarization

Public direct-download distribution requires:

- active Apple Developer Program membership;
- a Developer ID Application certificate and private key in a protected CI keychain;
- an App Store Connect API key or notarization profile stored as protected secrets;
- a real Mac or trusted macOS runner.

Build the Universal Release app from the candidate commit with hardened runtime enabled and App Sandbox disabled. Sign nested code and the app with timestamping, create the DMG with `hdiutil`, sign the DMG, and submit it with `xcrun notarytool`. After acceptance, staple the ticket.

Verify on a clean Mac before publishing:

```bash
codesign --verify --deep --strict --verbose=2 CodexUsageWidget.app
xcrun stapler validate CodexUsageWidget.app
spctl --assess --type execute --verbose=4 CodexUsageWidget.app
codesign --verify --verbose=2 CodexUsageWidget-v1.1.0-macos.dmg
xcrun stapler validate CodexUsageWidget-v1.1.0-macos.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 CodexUsageWidget-v1.1.0-macos.dmg
```

Gatekeeper must accept a fresh download without asking the user to bypass security controls. Do not print certificate material, API keys, keychain passwords, or notarization credentials in logs.

## 3. Canonical manifest

Create one manifest after all six assets are final. It must contain:

- exact commit SHA and version;
- each asset name, byte size, and lowercase SHA-256;
- Windows self-test and package-check results;
- Universal architecture result;
- signing identity summary without private material;
- notarization request ID and accepted status;
- `codesign`, `stapler`, and Gatekeeper verification results;
- clean-Mac launch and demo evidence.

Do not rebuild after recording the manifest. Any changed byte invalidates the recorded evidence.

## 4. Publish and verify

Create the `v1.1.0` tag from the exact manifest commit. Upload the six files, publish the notes from `docs/releases/v1.1.0.md`, then download every asset again and compare its size and SHA-256 with the manifest. Confirm the GitHub source archives point to the same tag.

## Rollback

If any checksum, signature, notarization, launch, or privacy check fails, keep the release as a draft or remove the affected public asset. Preserve the rejected manifest and logs without secrets, fix the source, bump the version if a public artifact was already consumed, and run the complete process again. Never replace a published binary while keeping its old checksum or evidence.
