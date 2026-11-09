# MTUNZ — Unified Device Network

**Version:** 0.4.0-dev  
**Targets:** Windows 10/11 x64 + Android 7.0+ (API 24+)  
**Application:** Native Flutter applications sharing one codebase and one embedded Core architecture.

MTUNZ connects Windows and Android devices for screen sharing, consent-based remote touch control and peer-to-peer file transfer. The user interface, signaling Core and WebRTC engine live in the MTUNZ app. The two operating systems need their own native package (Windows EXE folder and Android APK), but local-network pairing does not require a separate server executable or terminal.

iPhone/iOS is intentionally out of scope.

## Unified architecture

- **One shared application codebase:** Flutter/Dart for Windows and Android.
- **Embedded Core:** a Dart `HttpServer` starts automatically inside each MTUNZ process. It owns room creation, PIN checks, peer tokens, event polling and signaling.
- **Same Core contract on both platforms:** one device hosts a room; the other device enters that host's LAN URL, room code and PIN.
- **WebRTC peer-to-peer:** screen frames and file data are transmitted directly between connected devices when the network permits.
- **Optional remote deployment:** the Go signaling service, Caddy and coturn template remain available for user-managed HTTPS/TURN deployments across different Internet networks.

Each app binary includes its own Core. Windows and Android still require separate OS-native packages; this is one product and architecture, not one interchangeable EXE/APK file.

## What the embedded Core does

The Core binds to all IPv4 interfaces, prefers TCP port `8787`, and falls back to an available ephemeral port if another process already owns that port. The actual port is displayed in the host's invitation.

It implements:

- `GET /healthz`
- `POST /api/rooms`
- `POST /api/rooms/{code}/join`
- `GET /api/rooms/{code}/events`
- `POST /api/rooms/{code}/signal`
- `POST /api/rooms/{code}/leave`

Room codes and PINs are generated using a secure random source. Rooms expire after 15 minutes and allow up to three devices. Each joined device receives its own bearer token. Request bodies and event queues are bounded; room creation and join attempts are rate-limited; credentials are compared in constant time; idle peers and expired rooms are cleaned up. The user does not need to launch `MTUNZ-Signaling-Windows.exe` or `start-server.bat` for LAN pairing.

## Supported platforms

| Platform | Support |
|---|---|
| Windows 10 x64 | Native desktop |
| Windows 11 x64 | Native desktop |
| Android 7.0+ / API 24+ | Native APK |
| iPhone / iOS | Not included |

The Android APK is built for ARM32, ARM64 and x86_64. The Windows runner is compiled against the Windows 10+ API baseline.

## Local network setup: Windows ↔ Android

1. Install and open MTUNZ on both devices. The embedded Core starts with the app.
2. Connect both devices to a network where they can reach each other: shared Wi-Fi/LAN, Ethernet, or Android USB tethering/RNDIS.
3. On the device that will host the session, select **Create a room**.
4. The invitation displays the room code, 6-digit PIN and available LAN Core addresses. Choose the address belonging to the network shared with the other device; copy that address.
5. On the second device, select **Join with a code**. Enter the host address shown in the invitation, then the room code and PIN.
6. If Windows Firewall asks, allow MTUNZ on trusted **Private** networks only. Do not expose the HTTP Core port to Public networks.
7. Once paired, use screen sharing, remote-control requests or file transfer. Android requires system screen-capture consent; remote touch input requires the Android owner to enable MTUNZ Accessibility and approve the session.

**Important:** Do not use `127.0.0.1` as the host address on the joining device. Loopback always points to the device where it is entered. Use a LAN address shown in the invitation. If port 8787 is occupied, the invitation displays the fallback port chosen by the Core.

### Wi-Fi, Ethernet and USB tethering

- **Wi-Fi:** use the host's Wi-Fi IPv4 address when both devices share a reachable LAN.
- **Ethernet:** use the PC's Ethernet IPv4 address when the Android device can reach it on that LAN.
- **USB tethering:** enable Android **USB tethering / Chia sẻ Internet qua USB**, then select the PC's RNDIS/USB adapter address displayed by MTUNZ.
- A USB cable alone is not a raw USB or ADB transport. MTUNZ uses normal IP networking over tethering.

Keep MTUNZ open on Android during a hosted LAN session. Android may suspend network activity when the app is backgrounded; persistent background hosting is a future milestone.

## Current features

- Futuristic responsive dashboard and six languages: Vietnamese, English, Simplified Chinese, Japanese, Korean and Spanish.
- Temporary pairing rooms with 8-character code and 6-digit PIN.
- WebRTC screen sharing and remote video rendering.
- Consent-based Android remote tap/swipe through AccessibilityService.
- Peer-to-peer file transfer with receiver consent, progress, cancellation, filename validation and adaptive sender backpressure.
- Windows adapter discovery for Wi-Fi, Ethernet and common RNDIS/USB tether interfaces.
- Signaling retry/backoff and bounded ICE restart/re-negotiation.

## Current limitations

This is a development milestone, not a production remote-support suite.

1. Embedded HTTP Core is intended for trusted LAN use only. Do not expose it directly to the public Internet.
2. Connecting across unrelated Internet networks requires a reachable HTTPS signaling deployment and a secured TURN relay. STUN alone cannot guarantee traversal through restrictive or carrier-grade NAT.
3. Android may suspend a hosted Core when MTUNZ is backgrounded. Keep the app open during a LAN session.
4. File transfer is capped at 100 MB per file. The receiver currently assembles the full file in memory before opening the native save dialog and accepts only one incoming receive/save operation at a time.
5. Remote keyboard injection, clipboard sync, audio, accounts, persistent trusted devices and iOS are not included.
6. The current CI pipeline compiles and tests code, but does not replace physical-device testing on Windows 10, Windows 11 and Android.

## Optional Internet deployment

The `deploy/` directory contains a Linux VPS template with the Go signaling service, Caddy HTTPS reverse proxy and coturn. It is not a hosted MTUNZ service. A user must provide their own VPS, domain/DNS, firewall configuration and secrets.

Do not publish the embedded Core's HTTP port directly to the Internet. The optional Go service can issue temporary coturn REST credentials when configured with `MTUNZ_TURN_URLS` and `MTUNZ_TURN_SHARED_SECRET`. Public use must go through HTTPS. TURN-over-TLS and real external NAT acceptance tests remain future work.

## Build and validation

GitHub Actions builds:

- `MTUNZ-Android-APK` — Android release APK.
- `MTUNZ-Windows-x64-windows-2022` — Windows portable release folder.
- `MTUNZ-Windows-x64-windows-latest` — Windows portable release folder on the current runner.
- `MTUNZ-Signaling-Windows` — optional Go signaling service for user-managed deployments; not required for normal embedded LAN use.

See [docs/INSTALL-WINDOWS-ANDROID.md](docs/INSTALL-WINDOWS-ANDROID.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and [docs/BUILD-STATUS.md](docs/BUILD-STATUS.md).

## Acceptance checks still required

Before calling this release stable, test on physical Windows 10, Windows 11 and Android devices:

- Create/join on shared Wi-Fi, Ethernet and USB tethering.
- Share screen in both directions where supported.
- Approve and reject remote control requests.
- Send files both directions; test accept, reject, cancel, cancelled save dialog and interrupted network.
- Verify received file sizes and SHA-256 hashes.
- Test app restart, Core port conflict/fallback and reconnection after network interruption.
- Test separate Internet connections with a real HTTPS/TURN deployment.

CI success is necessary, but it is not proof that every device, router, firewall or carrier network works.

## License and component notices

Preserve licenses and notices for Flutter packages, WebRTC native binaries and all third-party components when redistributing MTUNZ builds.
