# Changelog

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
