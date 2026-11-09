# Changelog

## 0.3.0-dev — 2026-11-09

- Add peer-to-peer file sending and receiving over the existing WebRTC data channel; file contents are not uploaded to the signaling server.
- Require the receiving device to approve each incoming file and choose a destination through the native save dialog.
- Stream files in ordered 16 KB binary chunks with backpressure, per-chunk validation, progress reporting and cancellation.
- Limit each file to 100 MB, sanitize incoming filenames, and retain a capped transfer history.
- Add localized file-transfer UI in Vietnamese, English, Simplified Chinese, Japanese, Korean and Spanish.
- Add protocol unit tests and bump the application version to 0.3.0+5.

## 0.2.0-dev — 2026-11-09

- Refresh the futuristic interface with clearer visual hierarchy, gradient panels, responsive navigation and improved session/device cards.
- Add a persistent language selector for Vietnamese, English, Simplified Chinese, Japanese, Korean and Spanish.
- Apply language changes immediately across dashboard, devices, remote session, settings, room dialogs and navigation.
- Add widget coverage for runtime language switching and restoring the saved language after the app is reopened.
- Bump the Android/Windows app version to 0.2.0+4.

## 0.1.2-dev — 2026-11-09

- Add server-side peer presence leases: active clients refresh presence through authenticated long-poll requests.
- Expire abandoned peers after 90 seconds and release their waiting poll requests.
- Notify remaining room participants when an idle peer is removed.
- Add bounded exponential backoff to signaling polling and surface recovery/terminal session states in the app.
- Run native build and test checks on pull requests as well as pushes to main.

## 0.1.1-dev — 2026-11-08

- Harden signaling server room, peer, request-body, event-queue and polling limits.
- Return explicit overload errors instead of silently losing signaling messages.
- Add bounded rate limiting for room creation and invitation attempts.
- Serialize incoming signaling events and retry temporary queue-full responses in the client.
- Improve Android MediaProjection startup/cleanup and Accessibility gesture validation; bound foreground-service startup wait and surface failures.
- Add WebRTC Android release keep rules and apply them in generated Gradle projects.
- Make native-project preparation support both Gradle Kotlin DSL and Groovy templates.
- Pin CI build tool versions, run Go race/vet checks on Ubuntu before Windows cross-compilation, and correct the uploaded server artifact path.
- Document verified checks separately from Android/Windows client builds that still require SDK toolchains.
