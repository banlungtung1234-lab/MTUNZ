# MTUNZ 0.1.1-dev — build and validation status

## Latest CI release build: PASS

- **Commit:** `c13f0d182d930e125cd8786faee6de66718a0df6`
- **GitHub Actions run:** [Build MTUNZ native apps #7](https://github.com/banlungtung1234-lab/MTUNZ/actions/runs/42500358591)
- **Overall result:** success
- **Flutter:** 3.47.9 stable
- **Go:** 1.27.3

### Build outputs (uploaded as GitHub Actions artifacts; 30-day retention)

| Artifact | Result | Contents |
|---|---|---|
| `MTUNZ-Android-APK` | PASS | Release APK (`app-release.apk`) |
| `MTUNZ-Windows-x64` | PASS | Portable Windows release ZIP with `MTUNZ.exe`, Flutter runtime and WebRTC DLLs |
| `MTUNZ-Signaling-Windows` | PASS | Windows x64 signaling-server executable |

### CI checks

- `flutter analyze`: PASS on Android and Windows.
- `flutter test`: PASS on Android and Windows.
- `flutter build apk --release`: PASS.
- `flutter build windows --release`: PASS.
- `go test -race ./...`: PASS.
- `go vet ./...`: PASS.
- Windows signaling server cross-compile: PASS.

### Post-build artifact inspection

The three Actions artifacts were downloaded into a separate validation environment.

- Android APK: recognized as an Android package; archive integrity passed. It contains native libraries for `arm64-v8a`, `armeabi-v7a` and `x86_64`.
- Windows desktop ZIP: archive integrity passed; contains `MTUNZ.exe`, `flutter_windows.dll`, `libwebrtc.dll`, `flutter_webrtc_plugin.dll`, `dartjni.dll` and application data.
- Signaling artifact: archive integrity passed; executable identified as PE32+ Windows x86-64.
- Combined installation ZIP: SHA-256 manifest verification and ZIP integrity passed.

## Local development-container checks

- Go signaling-server tests passed with `go test -race ./...`; statement coverage was 68.0% in the local Go 1.23.2 environment.
- `go vet ./...` passed.
- Live HTTP integration checks covered health/version response, room creation, two-device join, offer signaling, authenticated long-poll delivery, invalid PIN rejection and third/fourth-device capacity behavior.
- `prepare-flutter-project.sh` and `inject-windows-controller.py` passed shell/Python syntax checks. The project-preparation script was also exercised in an isolated temporary project against mock Flutter CLI outputs for Gradle Kotlin DSL and Groovy. This mock check is supplemental; the real builds above are the authoritative compile results.
- Android manifest and Accessibility XML parsed successfully.

## Still requires real-device validation

The app has been compiled and unit/widget-tested, but the following behavior has not yet been verified on the user's physical Windows PC and Nubia Neo 2:

- First installation and startup on the target devices.
- Android MediaProjection consent and screen-capture stability on the target OS.
- Accessibility-service enablement and tap/swipe behavior on the target phone.
- Real Windows remote click/swipe behavior, including DPI/scaling.
- Three-device soak testing, latency, thermal/battery use and reconnect behavior on Wi-Fi and Internet.

## Current feature boundaries and safety limits

- Windows input bridge: remote click and swipe via Win32 `SendInput` only after the Windows user accepts the request. It cannot operate on the lock screen, secure desktop or UAC consent desktop.
- Android: screen capture requires a fresh MediaProjection system consent. Remote tap/swipe requires the device owner to enable MTUNZ Accessibility and separately approve the incoming control request.
- Room signaling: 64 active rooms maximum, 3 peers maximum per room, 15-minute room TTL, max 32 KB request bodies, 32 queued events per peer, one active long-poll per peer, 6 room creations and 12 join attempts per source IP per 5 minutes. These are development defaults, not a substitute for an externally reviewed anti-abuse design.
- Internet relay: TURN/TLS is not bundled. Signaling HTTP is intended only for trusted LAN testing. Do not expose port 8787 directly to the public Internet.
- Keyboard injection, file transfer, clipboard, audio, iOS, persistent trusted devices, user accounts and production-grade identity/revocation are not implemented.

## Build requirements

- Flutter 3.47.9 stable (pinned in CI).
- Android SDK / JDK 21 for APK builds.
- Windows 10/11 build host with Visual Studio 2022 and Desktop development with C++ for local Windows builds.
- GitHub Actions can rebuild the Android APK, Windows desktop release ZIP and signaling executable when application/platform/server source changes are pushed, or when the workflow is manually dispatched.
