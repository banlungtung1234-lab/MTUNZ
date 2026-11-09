# MTUNZ Unified Core 0.4.0-dev — build and validation status

## Current development branch

- **Feature PR:** [PR #5](https://github.com/banlungtung1234-lab/MTUNZ/pull/5) — open, not merged into `main`.
- **Branch:** `feature/unified-core-0.4`.
- **Target platforms:** Windows 10/11 x64 and Android API 24+. iOS/iPhone is excluded.
- **Application architecture:** one shared Flutter/Dart application codebase. Windows and Android still have different native packages, but both include the same embedded signaling Core. Normal local-network pairing does not require a separate server EXE or terminal.

## 0.4.0-dev changes in this branch

- Embed the Dart signaling Core inside the Flutter process on both Windows and Android.
- Bind to IPv4 interfaces, prefer port `8787`, and fall back to a free ephemeral port if the preferred port is already occupied.
- Start and stop the Core with the app lifecycle; display the actual host port and LAN IPv4 addresses in the invitation.
- Join dialog accepts the remote host Core URL, room code and PIN.
- Creating a room always switches back to this device's embedded Core, even after the user has previously joined a room hosted by another device. This avoids accidentally creating another room on the previous remote host.
- Before create/join, call `GET /healthz` on the selected Core. Surface actionable diagnostics for wrong addresses, TCP refusal, timeout and firewall/network problems before trying to join a room.
- Add Core HTTP API limits: bounded body and queues, rate-limited room creation/join, three devices per room, per-peer bearer tokens, short room expiry, authenticated event polling and stale-peer cleanup.
- Fix empty-room cleanup so newly created invitations survive until their 15-minute expiry.
- Remove an indeterminate network-scan spinner from a hidden IndexedStack page. It previously prevented Flutter widget tests from settling.
- Add integration tests using the actual `SignalingClient` against the embedded Core: health probe, create, host join, second-device join, peer-joined, SDP offer, peer-left and wrong-Core rejection.

## Current CI status

The latest code commit is being validated by GitHub Actions. Do not treat older runs from earlier intermediate commits as validation of the current branch head.

Latest workflow run: [run #68](https://github.com/banlungtung1234-lab/MTUNZ/actions/runs/42671398635).

The workflow covers:

| Job | Checks |
|---|---|
| Android APK | Flutter analysis, unit/widget/integration tests, release APK |
| Windows 2022 x64 | Flutter analysis, tests, Windows release build and ZIP packaging |
| Current Windows runner x64 | Same analysis, tests, build and packaging on current Windows image |
| Optional Go signaling service | Go race tests, vet and Windows amd64 cross-build |
| Remote deployment template | Docker Compose and Caddy validation, Linux signaling container build |

## Known CI issue already found and addressed

A previous run reported 13 passing tests and 4 widget tests timing out at `pumpAndSettle`. The new Core startup asynchronously scanned network interfaces while Settings remained mounted inside an `IndexedStack`; the hidden page contained an indeterminate circular-progress animation. The scan indicator is now static while scanning, so hidden pages no longer animate forever. The next current-head workflow must confirm the test fix.

## Limitations — not yet certified as stable

1. **Physical device acceptance is outstanding.** CI cannot prove that Windows 10, Windows 11 and a real Android phone can reach one another across the user's Wi-Fi, Ethernet, RNDIS and router/firewall configuration.
2. **A green /healthz probe proves only that the host HTTP Core is reachable.** It does not prove that WebRTC ICE can establish a media/data channel. Restrictive NATs may still require TURN.
3. **Android hosting in the background is not guaranteed.** Keep MTUNZ open during a local-host session; Android can suspend background networking. A persistent foreground Core service is a future item.
4. **Windows Firewall may block inbound TCP.** Allow MTUNZ only on trusted Private networks. Do not expose the embedded HTTP Core to the public Internet.
5. **USB support is IP networking over Android USB tethering/RNDIS.** It is not raw USB or ADB.
6. **File receiving still buffers the complete file in memory**, uses a 100 MiB cap and serializes incoming save operations.
7. **Public Internet service is not bundled.** Cross-network Internet use requires user-managed HTTPS signaling and TURN infrastructure.
8. Android is not production-signed with a stable release keystore; no Play Store release is prepared.

## Required device acceptance matrix

Before treating 0.4.0 as stable, test on real Windows 10, Windows 11 and Android devices:

- Windows host ↔ Android guest on Wi-Fi.
- Android host ↔ Windows guest on Wi-Fi.
- Ethernet host and Android guest on the same LAN.
- Android USB tethering with the correct RNDIS adapter selected.
- Core port 8787 occupied, verifying that the fallback port is shown correctly and is reachable through the firewall.
- Screen sharing in both directions where supported.
- Remote-control consent, reject and revoke.
- File send both directions, accept/reject/cancel and verify SHA-256.
- Network interruption, Core/app restart and rejoin.
- Separate Internet networks with a real HTTPS/TURN deployment.

## Release state

PR #5 remains a development change and is not merged into `main`. A CI pass is necessary but not sufficient for production release. The Windows 10/11 + Android physical-device acceptance matrix, memory-based file receive path, production signing and external NAT/TURN tests remain before a stable 1.0.0 release.
