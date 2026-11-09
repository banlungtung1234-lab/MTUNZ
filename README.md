# MTUNZ — native cross-device control

**Version:** 0.3.1-dev  
**Platforms in this milestone:** Windows 10/11 x64 + Android (API 24+)  
**Application type:** Flutter native desktop/mobile (compiled EXE package + APK), not a website.

MTUNZ is being built as a real remote-support application. The app UI is native Flutter, media is carried peer-to-peer with WebRTC, and a small Go service exchanges only room/pairing and WebRTC signaling messages.

## Supported platform targets

- **Windows:** Windows 10 and Windows 11, x64 desktop build.
- **Android:** API 24 and newer (Android 7.0+); APK packages ARM32, ARM64 and x86_64 native libraries.
- **iOS/iPhone:** excluded from the current development scope and CI.

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

## Current 0.3.1-dev implementation

- Native Flutter user interface for Windows and Android.
- Refreshed futuristic dashboard with responsive navigation, layered panels, clearer session cards and improved visual hierarchy.
- Six selectable interface languages: Vietnamese, English, Simplified Chinese, Japanese, Korean and Spanish. The selected language applies immediately and is saved on the device.
- Temporary room creation with an 8-character room code and 6-digit invitation PIN.
- Per-device bearer token after joining; rooms allow at most 3 devices and expire after 15 minutes.
- Go signaling server with authenticated long-poll message exchange, constant-time PIN/token checks, bounded request bodies, queue-overload responses, and cleanup.
- Server abuse/resource limits: at most 64 active rooms, 3 devices per room, 32 queued events per device, one active long-poll per device, 6 room creations and 12 join attempts per source IP per 5 minutes.
- Uniform cryptographically generated room codes/PINs and bounded in-memory rate-limit tables.
- Client signaling retries temporary queue-full (`503`) responses and serializes inbound events to preserve peer join/leave ordering.
- Signaling presence uses a 90-second peer lease refreshed by long-poll requests; abandoned peers are removed, waiting polls are released, and remaining peers receive a peer-left event.
- Client signaling uses bounded exponential retry backoff, avoids repeating outage notices, and reports when signaling has recovered.
- WebRTC peer connections with multiple STUN endpoints and optional coturn TURN credentials with a short expiry. ICE candidate batches reduce signaling requests; interrupted links attempt bounded ICE restart/re-negotiation with a deterministic offerer to avoid offer collisions. Video sender reuse avoids creating a new transceiver on each screen-share restart; externally ended Android capture sessions trigger cleanup.
- Screen capture via `getDisplayMedia` and remote video rendering.
- Peer-to-peer file transfer over the existing WebRTC data channel: per-file receiver consent, ordered 60 KB binary chunks, 4/2 MB adaptive send backpressure, 1 MB progress updates, cancellation, filename sanitization, and a native save dialog. The current per-file limit is 100 MB; only one receive/save operation is accepted at a time to bound mobile memory use; file bytes do not pass through the signaling server.
- Android AccessibilityService bridge for normalized tap/swipe actions. The Android user must enable the service and approve each remote-control request.
- Android and Windows x64 builds run in GitHub Actions. The Windows build is checked on both the Windows Server 2022 and current Windows runner images; the native runner is compiled against the Windows 10+ API baseline.

## Important current limitations

This is a development milestone, not a finished UltraViewer replacement. In particular:

1. No TURN relay is bundled yet. Direct P2P works only on network paths where ICE can establish a direct route; some mobile, office, school or carrier NATs will need TURN.
2. The signaling server is intentionally HTTP for a trusted LAN test. Do **not** expose it directly to the public Internet. Public use needs HTTPS behind a TLS reverse proxy and a properly secured TURN service.
3. Android screen capture requires the system's MediaProjection consent prompt each time. Remote tap/swipe requires the user to enable MTUNZ's Accessibility service and approve the incoming session.
4. Windows/Android remote tap and swipe and consent-based file transfer are included in the development source. File transfer is capped at 100 MB and buffers the completed received file in memory before opening the native save dialog. Keyboard injection, clipboard, audio, persistent trusted devices and account login are not implemented yet. iOS/iPhone is intentionally out of scope.
5. Multi-peer signaling is limited to 3 devices per room. Simultaneous three-device streaming still needs soak testing on actual hardware and may require a TURN relay on restrictive networks.
6. CI build success does not replace a real device-to-device transfer test. Windows and Android must still be tested with a real file in both directions, including receiver rejection, save cancellation, interrupted connectivity and larger files. On restrictive networks, the lack of a TURN relay may prevent a direct WebRTC data-channel connection.

## Wired network support

Windows Settings can scan active IPv4 adapters and label Wi-Fi, Ethernet and common RNDIS/USB tether interfaces. For a cable connection, connect both devices to the same Ethernet network, or enable Android USB tethering and choose the Windows RNDIS/USB adapter address the phone can reach. Then set the Android signaling URL to `http://<Windows-IPv4>:8787`. The application uses normal IP networking; it does not require ADB or USB debugging.

For remote Internet paths, the signaling server can issue temporary coturn credentials when `MTUNZ_TURN_URLS` and a strong `MTUNZ_TURN_SHARED_SECRET` are configured. Public use requires HTTPS signaling and a secured coturn deployment; TURN is optional and is not bundled as a public relay service.

## Quick local network test (Windows + Android)

These steps apply after the Android APK and Windows desktop package have been built. The source repository does not commit generated binaries. Download the `MTUNZ-Signaling-Windows` artifact from a successful GitHub Actions run and place `MTUNZ-Signaling-Windows.exe` beside `start-server.bat`. The Android and desktop application artifacts are built separately by the same workflow.

1. Download the `MTUNZ-Signaling-Windows` artifact from the latest successful Actions run, extract it, and place `MTUNZ-Signaling-Windows.exe` beside `start-server.bat`; then double-click `start-server.bat` (it sets port `8787`).
2. Allow it through Windows Firewall for **Private networks only** when prompted.
3. In Windows MTUNZ → **Settings** → **WI-FI / ETHERNET / USB**, scan adapters and select the IPv4 address reachable by the Android device. Alternatively, run `ipconfig` and identify the correct Wi-Fi, Ethernet or RNDIS adapter (e.g. `192.168.1.20`).
4. In MTUNZ on both devices, set the signaling address to `http://192.168.1.20:8787`.
5. Create a room on one device. Enter its room code and PIN on the other.
6. Start screen sharing on the device whose screen should be viewed. Android will show its system sharing-consent screen.
7. To control Android, the Android owner must enable MTUNZ Accessibility under Android Settings and approve the control request.
8. To transfer a file, open **Files** in MTUNZ, choose the connected device and select a file. The receiving device must approve the incoming request and choose a save location. Each file is limited to 100 MB.

Both devices must be able to reach the Windows signaling server over the same LAN or tethered IP network. Examples: Windows Ethernet + Android Wi-Fi on the same router, or Android USB tethering with Windows using the RNDIS adapter address. A USB cable alone is not a raw direct-USB transport. If the room connects but video/data does not, the network may block direct P2P; a deployed TURN relay is required for those restrictive paths.

## Remote Internet deployment (optional)

A Linux VPS deployment template is available in [deploy/README.md](deploy/README.md). It combines the Go signaling service, Caddy HTTPS reverse proxy and coturn TURN relay. It is not a hosted MTUNZ service: you need your own Linux VPS, DNS records, firewall access and secrets. The template currently uses TURN over UDP/TCP; TURN-over-TLS and real external NAT acceptance tests remain future work.

## Build pipeline

The workflow `.github/workflows/build-native.yml` builds:

- `MTUNZ-Android-APK` — a release APK artifact.
- `MTUNZ-Windows-x64-windows-2022` and `MTUNZ-Windows-x64-windows-latest` — Windows native release folder ZIPs built on two Windows runner images.
- `MTUNZ-Signaling-Windows` — Windows signaling server executable. This is a background pairing/signaling service, not the MTUNZ desktop app itself.

The Windows ZIP contains the EXE and Flutter runtime DLLs; keep the complete folder together when installing/running it.

## License and component notices

MTUNZ application source is currently provided for project development. Third-party Flutter packages and WebRTC native binaries retain their own licenses; preserve their notices when distributing builds. This repository does not bundle third-party binaries beyond the separately built Go signaling server.

## Build status

See [`docs/BUILD-STATUS.md`](docs/BUILD-STATUS.md) for the exact list of checks that passed and the remaining real-device/build validation.
