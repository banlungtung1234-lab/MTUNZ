# MTUNZ — native cross-device control

**Version:** 0.1.2-dev  
**Platforms in this milestone:** Windows desktop + Android  
**Application type:** Flutter native desktop/mobile (compiled EXE package + APK), not a website.

MTUNZ is being built as a real remote-support application. The app UI is native Flutter, media is carried peer-to-peer with WebRTC, and a small Go service exchanges only room/pairing and WebRTC signaling messages.

## Repository layout

```text
MTUNZ/
├── app/                         # Flutter source shared by Windows and Android
│   ├── lib/                     # Native app UI, signaling and WebRTC mesh
│   ├── test/                    # Flutter smoke tests
│   └── pubspec.yaml
├── platform/android/            # Android manifest, Kotlin bridge, Accessibility service
├── server/                      # Go signaling server (standard library only)
├── scripts/                     # Native project preparation helpers
├── .github/workflows/           # Cloud builds for APK and Windows package
└── docs/                        # Setup, security and milestone notes
```

## Current 0.1.2-dev implementation

- Native Flutter user interface for Windows and Android.
- Temporary room creation with an 8-character room code and 6-digit invitation PIN.
- Per-device bearer token after joining; rooms allow at most 3 devices and expire after 15 minutes.
- Go signaling server with authenticated long-poll message exchange, constant-time PIN/token checks, bounded request bodies, queue-overload responses, and cleanup.
- Server abuse/resource limits: at most 64 active rooms, 3 devices per room, 32 queued events per device, one active long-poll per device, 6 room creations and 12 join attempts per source IP per 5 minutes.
- Uniform cryptographically generated room codes/PINs and bounded in-memory rate-limit tables.
- Client signaling retries temporary queue-full (`503`) responses and serializes inbound events to preserve peer join/leave ordering.
- Signaling presence uses a 90-second peer lease refreshed by long-poll requests; abandoned peers are removed, waiting polls are released, and remaining peers receive a peer-left event.
- Client signaling uses bounded exponential retry backoff, avoids repeating outage notices, and reports when signaling has recovered.
- WebRTC peer connections with STUN discovery, offer/answer and ICE candidate exchange. Video sender reuse avoids creating a new transceiver on each screen-share restart; externally ended Android capture sessions trigger cleanup.
- Screen capture via `getDisplayMedia` and remote video rendering.
- Android AccessibilityService bridge for normalized tap/swipe actions. The Android user must enable the service and approve each remote-control request.
- Windows and Android build workflows are included. GitHub Actions can create an Android APK and a Windows release folder ZIP once the source is pushed to a repository.

## Important current limitations

This is a development milestone, not a finished UltraViewer replacement. In particular:

1. No TURN relay is bundled yet. Direct P2P works only on network paths where ICE can establish a direct route; some mobile, office, school or carrier NATs will need TURN.
2. The signaling server is intentionally HTTP for a trusted LAN test. Do **not** expose it directly to the public Internet. Public use needs HTTPS behind a TLS reverse proxy and a properly secured TURN service.
3. Android screen capture requires the system's MediaProjection consent prompt each time. Remote tap/swipe requires the user to enable MTUNZ's Accessibility service and approve the incoming session.
4. Windows/Android remote tap and swipe are included in the development source. Keyboard injection, file transfer, clipboard, audio, persistent trusted devices, account login and iOS are not implemented yet.
5. Multi-peer signaling is limited to 3 devices per room. Simultaneous three-device streaming still needs soak testing on actual hardware and may require a TURN relay on restrictive networks.
6. The app source has not been compiled in this container because Flutter/Dart, Android SDK and Windows desktop build tools are not installed here. The Go signaling server has been race-tested, vetted, integration-tested over HTTP, and cross-compiled for Windows. The Flutter project-preparation script was exercised against a mock Flutter CLI to validate its file injection steps; that is not a substitute for a real Flutter build. The native app binaries are therefore not yet available from this environment.

## Quick local network test (Windows + Android)

These steps apply after the Android APK and Windows desktop package have been built. The source repository does not commit generated binaries. Download the `MTUNZ-Signaling-Windows` artifact from a successful GitHub Actions run and place `MTUNZ-Signaling-Windows.exe` beside `start-server.bat`. The Android and desktop application artifacts are built separately by the same workflow.

1. Download the `MTUNZ-Signaling-Windows` artifact from the latest successful Actions run, extract it, and place `MTUNZ-Signaling-Windows.exe` beside `start-server.bat`; then double-click `start-server.bat` (it sets port `8787`).
2. Allow it through Windows Firewall for **Private networks only** when prompted.
3. Find the Windows PC's IPv4 address using `ipconfig` (the Wi-Fi adapter address, e.g. `192.168.1.20`).
4. In MTUNZ on both devices, set the signaling address to `http://192.168.1.20:8787`.
5. Create a room on one device. Enter its room code and PIN on the other.
6. Start screen sharing on the device whose screen should be viewed. Android will show its system sharing-consent screen.
7. To control Android, the Android owner must enable MTUNZ Accessibility under Android Settings and approve the control request.

Both devices must be on the same Wi-Fi for this first test. If the room connects but the video does not, the network may block direct P2P; TURN relay is the next networking milestone.

## Build pipeline

The workflow `.github/workflows/build-native.yml` builds:

- `MTUNZ-Android-APK` — a release APK artifact.
- `MTUNZ-Windows-x64` — the Windows native release folder packaged as ZIP.
- `MTUNZ-Signaling-Windows` — Windows signaling server executable. This is a background pairing/signaling service, not the MTUNZ desktop app itself.

The Windows ZIP contains the EXE and Flutter runtime DLLs; keep the complete folder together when installing/running it.

## License and component notices

MTUNZ application source is currently provided for project development. Third-party Flutter packages and WebRTC native binaries retain their own licenses; preserve their notices when distributing builds. This repository does not bundle third-party binaries beyond the separately built Go signaling server.

## Build status

See [`docs/BUILD-STATUS.md`](docs/BUILD-STATUS.md) for the exact list of checks that passed and the remaining real-device/build validation.
