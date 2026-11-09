# MTUNZ 0.3.0-dev — build and validation status

## CI result: PASS

- **Merged main commit:** `44dba08c68868ca723490ab28c7b1654f9ca7f9c`
- **Feature PR:** [PR #3](https://github.com/banlungtung1234-lab/MTUNZ/pull/3) — merged on 2026-11-09.
- **PR validation:** [run 42573294364](https://github.com/banlungtung1234-lab/MTUNZ/actions/runs/42573294364) — success.
- **Post-merge main validation:** [run 42574039126](https://github.com/banlungtung1234-lab/MTUNZ/actions/runs/42574039126) — success; Android, Windows desktop and Windows signaling jobs completed successfully.
- **Flutter:** 3.47.9 stable
- **Go:** 1.27.3
- **App version:** 0.3.0+5

The successful post-merge workflow was run against the exact commit now at the tip of `main`.

## Build outputs

| Artifact | CI | Binary/container inspection |
|---|---|---|
| Android APK | PASS | Valid APK archive; contains arm64-v8a, armeabi-v7a and x86_64 native libraries |
| Windows desktop | PASS | Valid ZIP; contains MTUNZ.exe, Flutter runtime, WebRTC DLL and app data |
| Signaling server | PASS | Valid PE32+ Windows x86-64 executable |

The downloadable GitHub Actions artifacts are retained for 30 days from the workflow run. A consolidated `MTUNZ-0.3.0-dev-Install-Pack.zip` can be assembled from these artifacts for first-time installation.

## CI checks

- Android: `flutter analyze`, `flutter test`, `flutter build apk --release` — PASS.
- Windows: `flutter analyze`, `flutter test`, `flutter build windows --release`, ZIP packaging — PASS.
- Signaling server: `go test -race ./...`, `go vet ./...`, Windows x64 cross-compile — PASS.

The new file-transfer unit tests and localized Files-page widget test passed on both Android and Windows CI jobs.

## 0.3.0-dev file-transfer implementation

- Peer-to-peer file bytes travel over the existing WebRTC data channel, not through the signaling server.
- The recipient must approve each incoming transfer and choose a save destination.
- Data is framed in ordered 16 KB binary chunks with input validation, bounded data-channel buffering, transfer progress and cancellation.
- Incoming file names are sanitized, including Windows-reserved names.
- Per-file limit is 100 MB. The receiving device assembles the file in memory before opening the native save dialog.
- File-transfer UI is translated into Vietnamese, English, Simplified Chinese, Japanese, Korean and Spanish.

## Still requires real-device validation

CI proves static analysis, automated tests and native compilation; it does **not** prove reliable real-world Windows↔Android transfer. Test on a physical Windows PC and Android phone:

- Send small files in both directions and compare the saved file size/hash.
- Verify receiver accept/reject, destination selection, save cancellation and sender cancellation.
- Interrupt Wi-Fi during transfer and confirm both sides recover without a stuck transfer.
- Exercise files approaching 100 MB while monitoring memory use.
- Test same-Wi-Fi and restrictive NAT/mobile-network paths.

## Current boundaries and safety limits

- No TURN relay is bundled. Direct WebRTC may fail on restrictive NAT, carrier or office/school networks.
- The signaling server uses HTTP for trusted-LAN development. Do not expose port 8787 directly to the public Internet; public deployment needs TLS and properly secured TURN.
- Three devices maximum per room; multi-peer file transfer has not had physical-device soak testing.
- The 100 MB file cap is a safeguard, not a promise of low memory use: the receiver buffers the complete file before saving.
- Remote Android tap/swipe still requires the device owner to enable MTUNZ Accessibility and approve the request.
- Keyboard injection, clipboard, audio, account login, persistent trusted devices and iOS are not implemented.

## Build requirements

- Flutter 3.47.9 stable (pinned in CI).
- Android SDK and JDK 21 for APK builds.
- Windows build host with Visual Studio 2022 and Desktop development with C++ for local Windows builds.
- GitHub Actions rebuilds Android, Windows and signaling server artifacts when relevant source files change, or when manually dispatched.
