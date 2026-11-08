# MTUNZ 0.1.1-dev — build and validation status

## Passed in the development container

- Go signaling server: `go test -race ./...` passes, including invitation rate limits, invalid PIN/token handling, queue-full behavior, three-device capacity, global room cap, bounded rate tables, and duplicate long-poll protection.
- Go static checks: `go vet ./...` passes; statement coverage is 68.0%. These checks ran with the container Go SDK 1.23.2. The GitHub workflow is pinned to Go 1.27.3, but that remote workflow has not yet been run.
- Windows x64 signaling server: cross-compiled with `CGO_ENABLED=0 GOOS=windows GOARCH=amd64`; file inspection identifies a PE32+ x86-64 Windows executable.
- Live HTTP integration test: verified health/version response, room creation, two-device join, offer signaling, authenticated long-poll delivery, invalid PIN rejection, and third/fourth-device capacity behavior.
- `prepare-flutter-project.sh` and `inject-windows-controller.py`: shell/Python syntax checked; preparation script integration-tested in an isolated temporary project against mock Flutter CLI outputs for both Gradle Kotlin DSL and Groovy, including Android manifest/Kotlin copy, minSdk/ProGuard setup, Windows method-channel injection, C++17 and User32 CMake setup, and MTUNZ product naming. This verifies the script transformations, not a real Flutter compilation.
- Android manifest and accessibility-service XML: parsed successfully.
- GitHub Actions workflow and pubspec YAML: parsed successfully. The pipeline pins Flutter 3.47.9 stable and Go 1.27.3; the Go race/vet job runs on Ubuntu, then cross-compiles the Windows server executable.
- Windows signaling executable: cross-compiled and inspected as a PE32+ x86-64 binary. The executable is not committed to the source tree; GitHub Actions builds and publishes it as a separate artifact.

## Not yet built or verified

- Flutter/Dart analyzer and Flutter widget tests have not run in this container; Flutter and Dart SDKs are not installed.
- Android Kotlin code has not been compiled against the Android SDK.
- Windows C++ input bridge has not been compiled with MSVC/Visual Studio.
- A release Android APK and the MTUNZ Windows desktop application package are not included yet. The Windows signaling server executable is a separate background service, not the desktop app.
- Screen sharing, input injection, battery/thermal behavior, multi-peer stability, and network traversal still require real Windows and Android hardware tests.

## Current feature boundaries

- Windows input bridge: remote click and swipe via Win32 `SendInput` only after the Windows user accepts the request. It cannot operate on the lock screen, secure desktop, or UAC consent desktop.
- Android: screen capture requires a fresh MediaProjection system consent. Android 14+ full-screen capture is requested. Remote tap/swipe requires the device owner to enable MTUNZ Accessibility and separately approve the incoming control request.
- Room signaling: 64 active rooms maximum, 3 peers maximum per room, 15-minute room TTL, max 32 KB request bodies, 32 queued events per peer, one active long-poll per peer, 6 room creations and 12 join attempts per source IP per 5 minutes. These are development defaults, not a substitute for an externally reviewed anti-abuse design.
- Internet relay: TURN/TLS is not bundled. Signaling HTTP is intended only for trusted LAN testing. Do not expose port 8787 directly to the public Internet.
- Keyboard injection, file transfer, clipboard, audio, iOS, persistent trusted devices, user accounts, and production-grade identity/revocation are not implemented.

## Build requirements

- Flutter 3.47.9 stable (pinned in CI; Dart 3.13.7 is bundled with Flutter).
- Android SDK / JDK 21 for APK builds.
- Windows 10/11 build host with Visual Studio 2022 and Desktop development with C++ for Windows builds.
- The `.github/workflows/build-native.yml` workflow can compile the APK, Windows desktop release ZIP, and Windows signaling executable after this source is pushed to a GitHub repository with Actions enabled.
