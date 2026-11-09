# MTUNZ 0.1.2-dev — build and validation status

## CI result: PASS

- **Source tree:** `cc2a0192e7280dbe79c16f590ebf9a67d632a8b5`
- **Merged main commit:** `0b3e4661b58dc53d2847fa82757c23a942002350`
- **Tested GitHub Actions run:** [Build MTUNZ native apps](https://github.com/banlungtung1234-lab/MTUNZ/actions/runs/42565549426)
- **Run result:** success; Android, Windows and Go server jobs completed successfully.
- **Flutter:** 3.47.9 stable
- **Go:** 1.27.3

The tested PR commit and merged main commit have the same Git tree SHA, so the binaries below were built from exactly the source tree now on `main`.

## Build outputs

| Artifact | Result | Inspection |
|---|---|---|
| Android APK | PASS | Valid APK archive; native ABIs arm64-v8a, armeabi-v7a and x86_64 |
| Windows desktop | PASS | ZIP integrity; contains `MTUNZ.exe`, Flutter runtime, WebRTC DLL and app data |
| Signaling server | PASS | PE32+ Windows x86-64 executable |

The individual Actions artifacts are retained for 30 days from the CI run. A combined installation pack was also assembled and checked separately; it includes the APK, Windows portable ZIP, signaling EXE, LAN startup BAT, Vietnamese installation guide and SHA-256 manifest.

## CI checks

- Android: `flutter analyze`, `flutter test`, `flutter build apk --release` — PASS.
- Windows: `flutter analyze`, `flutter test`, `flutter build windows --release`, ZIP packaging — PASS.
- Signaling server: `go test -race ./...`, `go vet ./...`, Windows x64 cross-compile — PASS.

Regression coverage added for:
- A new empty invitation room remains available until its TTL expires.
- An idle peer is removed after its 90-second lease, the blocked long-poll is released, and remaining peers receive `peer-left`.
- An expired room releases blocked peer pollers.

## Reliability changes in 0.1.2-dev

- Each successful authenticated long-poll refreshes a peer's presence lease.
- The server performs cleanup every 15 seconds and expires peers idle for more than 90 seconds.
- Removing an idle peer releases its pending poll and notifies the other room members.
- The client uses bounded exponential retry backoff (500 ms to 4 seconds), avoids repeated outage notices, and reports signaling recovery or terminal session errors.
- Build and test checks now run on pull requests as well as source pushes to main.

## Still requires real-device validation

CI confirms source analysis, tests and native compilation; it does **not** prove real-world remote control is stable on the user's devices. The following still need to be tested on a physical Windows PC and Android phone:

- First installation and startup on the target devices.
- Android MediaProjection consent and screen-capture stability.
- Accessibility-service enablement and tap/swipe behavior.
- Windows remote click/swipe behavior across DPI and scaling settings.
- Two- and three-device soak tests, latency, reconnect behavior, thermal/battery usage and different Wi-Fi/network conditions.

## Current feature boundaries and safety limits

- Windows input bridge: approved mouse click/swipe via Win32 `SendInput`; it cannot operate the lock screen or UAC secure desktop.
- Android: screen capture requires a fresh MediaProjection consent. Remote tap/swipe requires the device owner to enable MTUNZ Accessibility and approve control.
- Signaling: maximum 3 peers per room, 15-minute room TTL, 90-second peer idle lease, maximum 64 active rooms, bounded event queues and rate limiting.
- The signaling service is for trusted LAN testing. It uses HTTP in this development setup; do not expose port 8787 directly to the public Internet.
- STUN is configured, but TURN relay/TLS is not bundled. Some NAT and mobile-network paths will fail to establish direct P2P media.
- iOS, keyboard injection, file transfer, clipboard, audio, persistent device identities and production-grade account/revocation are not implemented.

## Build requirements

- Flutter 3.47.9 stable (pinned in CI).
- Android SDK and JDK 21 for APK builds.
- Windows build host with Visual Studio 2022 and Desktop development with C++ for local Windows builds.
- GitHub Actions rebuilds Android, Windows desktop and signaling server when relevant source files change, or when manually dispatched.
