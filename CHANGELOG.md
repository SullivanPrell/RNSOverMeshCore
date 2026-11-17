# Changelog

All notable changes to RNSOverMeshCore are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-11-16

### Fixed

- Builds against ReticulumSwift 1.8.0 and later. ReticulumSwift's `Interface`
  protocol requires a settable `bitrate` since 1.8.0, and the three interfaces
  declared it `private(set)`. RNSOverMeshCore now requires ReticulumSwift 1.28.0.

## [1.0.0] — 2026-07-20

Initial release. A Swift reimplementation of the GPL-3.0 Python
[`comms-engineer/RNS_Over_Meshcore`](https://github.com/comms-engineer/RNS_Over_Meshcore)
interfaces, wire-compatible with the Python driver so a Swift node and a Python
node interoperate on the same MeshCore channel.

### Added

- **Three-layer, injection-based architecture** mirroring ReticulumSwift's
  `RNodeInterface` / `RNodeTransport` split:
  - Layer C — `MeshCoreTransport` protocol + in-package `MeshCoreTCPTransport`
    (`Network.framework`); BLE/serial adapters are host-injected.
  - Layer A — `MeshCoreCompanion` protocol + `MeshCoreClient` (companion frame
    codec `MeshCoreFrames`, one-in-flight command/response queue, MESSAGES_WAITING
    drain, multi-frame `getContacts` accumulation).
  - Layer B — three RNS `Interface` conformers with shared tunnel helpers
    (`RNSHeaderInspector`, three `Fragmenter`s, `FragmentReassembler`,
    `RateLimiters`, `PeerTable`).
- **`MeshCoreDynamicInterface`** — flagship hybrid interface: channel broadcast +
  unicast direct, demand-driven RNSBIND peer discovery, rate limiting,
  retransmission, ACK-gated direct with channel fallback.
- **`MeshCoreChannelInterface`** — channel-broadcast-only, over a radio
  (`CompanionChannelBackend`) or a `RemoteTermChannelBackend`
  (REST + WebSocket to a Remote-Terminal-for-MeshCore server).
- **`MeshCoreContactInterface`** — unicast direct to a configured endpoint
  contact, which may be a public-key hex prefix or an advert name resolved
  against the device contact list via `getContacts`.
- **Wire-parity tests** (`MeshCoreWireParityTests`) asserting the Swift
  fragmenters emit bytes identical to the Python code, plus a two-node
  Swift↔Swift loopback and full codec / framing / rate-limiter / peer-table
  coverage. 81 tests, 0 failures.

### Known limitations

- `RemoteTermChannelBackend`'s WebSocket event filtering is unit-tested; its
  REST/WebSocket transport plumbing needs a live RemoteTerm server and is
  integration-only.
- Live Python↔Swift interop over real MeshCore hardware should be verified on a
  device before production use.

[1.0.0]: https://github.com/SullivanPrell/RNSOverMeshCore/releases/tag/1.0.0
