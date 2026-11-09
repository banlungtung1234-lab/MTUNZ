# MTUNZ development roadmap

| Milestone | Deliverable | State |
|---|---|---|
| 0.1.2-dev | Session leases, stale-peer cleanup and bounded signaling reconnect | Merged to main; Android, Windows and Go CI passed |
| 0.2.0-dev | Modern responsive interface and selectable multi-language UI | Merged to main; six languages and saved language preference |
| 0.3.0-dev | Peer-to-peer file transfer with receiver consent, progress, cancellation and 100 MB per-file limit | Merged to main; CI passed; physical-device transfer tests remain required |
| 0.3.1-dev | Windows 10/11 x64, Android API 24+, wired Ethernet/USB tether discovery, multi-STUN/optional TURN credentials, candidate batching, 64 KB file chunks and adaptive backpressure | In progress in `feature/platform-resilience-0.3.1` |
| 0.3.2 | TURN/coturn deployment hardening, HTTPS signaling and external NAT traversal validation | Planned |
| 0.4.0 | Stable three-device multi-view and per-peer control permissions, verified on physical devices | Planned |
| 0.5.0 | Clipboard synchronization and audio streaming | Planned |
| 1.0.0 | Security review, installer/signing, diagnostics, documentation and release-candidate test matrix | Not started |

**Platform scope:** Windows 10/11 x64 and Android API 24+. iOS/iPhone is intentionally excluded from the current roadmap.
