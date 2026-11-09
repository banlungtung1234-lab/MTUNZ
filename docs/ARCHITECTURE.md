# MTUNZ architecture — 0.4.0-dev

## Product architecture

MTUNZ is one cross-platform native application implemented with a shared Flutter/Dart codebase:

- **Windows:** Windows 10/11 x64 desktop application.
- **Android:** Android API 24+ (Android 7.0+) application.
- **iOS/iPhone:** intentionally excluded from this milestone.

The same application package contains the user interface, device/session manager, embedded signaling Core, WebRTC engine, file-transfer engine and platform-specific control bridges. Windows ships as a portable application folder/EXE; Android ships as an APK. The operating systems still require separate native packages, but the user no longer installs or launches a separate signaling server to make a local-network connection.

## Embedded Core and signaling plane

`EmbeddedSignalingServer` is a Dart `dart:io` HTTP service hosted inside the MTUNZ application process on both Windows and Android.

- It binds to `0.0.0.0` (IPv4) so another device on a reachable LAN/tether network can connect.
- It prefers TCP port `8787`. If that port is already occupied, it binds to an available ephemeral port instead of failing or taking over another process's port.
- The app starts the Core during initialization and closes it during application shutdown.
- The local app talks to its own Core over loopback. The invitation separately displays the host device's reachable LAN IPv4 address(es) and actual Core port.
- The joining device supplies that host URL, room code and PIN in one dialog.
- No `MTUNZ-Signaling-Windows.exe`, `start-server.bat`, terminal window or standalone daemon is required for normal LAN use.

The embedded Core implements the same endpoints as the optional Go service:

- `GET /healthz`
- `POST /api/rooms`
- `POST /api/rooms/{code}/join`
- `GET /api/rooms/{code}/events`
- `POST /api/rooms/{code}/signal`
- `POST /api/rooms/{code}/leave`

Rooms have a cryptographically random 8-character code and 6-digit PIN, expire after 15 minutes, allow at most three devices, and issue each joined peer a separate bearer token. The Core applies bounded request-body and event-queue sizes, per-IP create/join rate limits, authenticated long-polling, constant-time credential comparisons, peer presence expiry and room cleanup. New empty rooms remain available until their invitation expires.

The Go server under `server/` is retained as an optional self-hosted signaling service for remote Internet deployments. It is not part of the normal local pairing workflow.

## Media and file plane

- **Media plane:** WebRTC peer connections carry screen frames and data peer-to-peer. STUN candidates are attempted first; an optional TURN relay is required on restrictive NAT/mobile networks.
- **File transfer:** ordered binary chunks use the WebRTC data channel, receiver consent, cancellation and bounded backpressure. The current 100 MB per-file limit and memory-based receive/save path remain development constraints.
- **Remote control:** Android Accessibility dispatches tap/swipe gestures only after the device owner enables the service and approves each request. Android screen capture uses system MediaProjection consent.

## Local network connectivity

The embedded Core listens on all IPv4 interfaces. The room creator should share the matching address for the network that the other device can reach:

- Wi-Fi: both devices on a reachable Wi-Fi/LAN network.
- Ethernet: host PC and peer device on a routed/shared LAN.
- Android USB tethering: enable USB tethering, then select the host interface that receives the phone's RNDIS/USB network.
- USB is IP networking over tethering, not a raw USB or ADB transport.

Windows Firewall may ask permission for MTUNZ to accept incoming connections. Allow it only on trusted **Private** networks. Do not expose the embedded HTTP Core port directly to the public Internet.

Keep MTUNZ open on Android during a hosted LAN session. Android may suspend network activity when the app is backgrounded; a persistent foreground hosting service is a separate future task.

## Internet connectivity

The embedded Core is designed for trusted LAN pairing. Different Internet networks need a reachable HTTPS signaling server and a secured TURN relay. The optional Go service can issue short-lived coturn REST credentials using `MTUNZ_TURN_URLS`, `MTUNZ_TURN_SHARED_SECRET` and `MTUNZ_TURN_CREDENTIAL_TTL_SECONDS`. The self-hosted Linux template uses Caddy and coturn, but it is a deployment template, not a public MTUNZ service.

The Go service and relay must be deployed on infrastructure the user controls. TURN-over-TLS, external NAT acceptance tests, signed Android production builds and public infrastructure are not included in this development milestone.

## Platform, lifecycle and release constraints

- Windows 10/11 x64; Android API 24+.
- The app owns the embedded Core lifecycle. If startup fails, Settings shows the error and offers a retry.
- The host Core's actual port is shown in the invitation because the preferred port may be unavailable.
- CI analysis/build tests do not replace real device tests. Windows 10, Windows 11 and Android must still be tested on Wi-Fi, Ethernet, USB tethering, separate Internet connections, screen sharing and bidirectional file transfer.
- The current receiver assembles an entire file in memory before opening the native save dialog; one incoming receive/save operation is allowed at a time and the file size is capped at 100 MB.
