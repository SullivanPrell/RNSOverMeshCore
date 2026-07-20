# RNSOverMeshCore

A Swift addon for the [ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift)
stack that tunnels **Reticulum (RNS)** traffic over a **[MeshCore](https://github.com/meshcore-dev/MeshCore)**
LoRa mesh. It is a Swift reimplementation of the Python
[`comms-engineer/RNS_Over_Meshcore`](https://github.com/comms-engineer/RNS_Over_Meshcore)
interfaces — **not a fork** (the upstream is Python; this is a from-scratch Swift
port), and it is **wire-compatible** with the Python interfaces, so a Swift node
and a Python node interoperate on the same MeshCore channel.

It plugs into ReticulumSwift as ordinary `Interface`s, exactly like the built-in
TCP / RNode / BLE-mesh interfaces, and it lives in its **own package** — see
[License](#license).

## Why this exists

MeshCore is a LoRa-mesh firmware (in the spirit of, and crediting, Meshtastic).
Running Reticulum *over* a MeshCore mesh lets an iOS/macOS Reticulum app use
inexpensive MeshCore radios as a transport — messaging (LXMF), NomadNet pages, and
the rest of the RNS feature set riding on top of the LoRa mesh.

## Credits

This work stands on:

- **[comms-engineer/RNS_Over_Meshcore](https://github.com/comms-engineer/RNS_Over_Meshcore)**
  — the GPL-3.0 Python project whose interface logic and wire format this package
  ports to Swift.
- **[landandair/RNS_Over_Meshtastic](https://github.com/landandair/RNS_Over_Meshtastic)**
  — the project `RNS_Over_Meshcore` was forked from.
- **[MeshCore](https://github.com/meshcore-dev/MeshCore)** (by ripplebiz and
  contributors) — the LoRa-mesh firmware and its
  [companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md);
  the companion frame codec here follows [`meshcore_py`](https://github.com/meshcore-dev/meshcore_py).
- **[Meshtastic](https://github.com/meshtastic)** — upstream inspiration for the
  original Meshtastic tunnel that this lineage descends from.
- **[Reticulum](https://github.com/markqvist/Reticulum)** (by Mark Qvist) — the
  network stack this interface plugs into.

## License

**GPL-3.0-or-later.** Because this package ports the logic of the GPL-3.0
`RNS_Over_Meshcore`, it is itself a derivative work and is licensed GPL-3.0. It only
*depends on* — and never modifies — the permissively-licensed ReticulumSwift, which
keeps the RNS core's license clean (a GPL work may depend on permissive code). That
is why this package is kept **outside** `swift_devel/` (which is permissively
licensed) in its own directory. See [`LICENSE`](./LICENSE).

## Architecture

Three decoupled layers, mirroring ReticulumSwift's `RNodeInterface` / `RNodeTransport`
split so radio I/O is injected and the tunnel logic is pure and unit-testable:

```
Layer C  MeshCoreTransport        raw companion byte stream (TCP in-package;
         (protocol)               BLE/serial adapters injected by the host app)
              │
Layer A  MeshCoreCompanion        commands + events (appStart / setChannel /
         (protocol)               sendChannel / sendDirect / waitForAck …)
         └ MeshCoreClient         companion frame codec + command/response queue
              │
Layer B  three Interface types    fragmentation, reassembly, routing, discovery
         (conform to RNS Interface)
```

The two seams — `MeshCoreCompanion` and `MeshCoreTransport` — each have a mock in
the test suite, so every layer is tested with no radio present.

## The three interfaces

| Type | Ports | Transport to peers | Fragment header | Encoding |
|---|---|---|---|---|
| `MeshCoreDynamicInterface` | `MeshCore_Dynamic_Interface` | channel broadcast **+** unicast direct, demand-driven RNSBIND discovery | `[idx][pkt_id:4 BE][total]` | `RNS:`+base64url |
| `MeshCoreChannelInterface` | `MeshCore_Channel_Interface` | channel broadcast only; radio **or** RemoteTerm backend | `RN`+`[idx][src_id:4][pkt_id][total]` | `RNS:`+base64url |
| `MeshCoreContactInterface` | `MeshCore_Interface` | unicast direct to a configured endpoint contact | `[index][pos:signed]` | base64 |

`MeshCoreDynamicInterface` is the recommended one (matches the upstream README).
Its wire format and routing are byte-for-byte compatible with the Python driver —
see `MeshCoreWireParityTests`, which asserts the Swift fragmenters produce output
identical to the actual Python code.

## Usage

Add the package to your `Package.swift` (it pulls in ReticulumSwift transitively):

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/SullivanPrell/RNSOverMeshCore.git", from: "1.0.0"),
]
```

> **License note:** RNSOverMeshCore is **GPL-3.0-or-later**. Linking it into an
> application makes the distributed application a combined GPL-3.0 work — see
> [License](#license). ReticulumSwift itself stays permissively licensed.

Wire up a Dynamic interface over the in-package TCP transport and register it with
a running Reticulum instance:

```swift
import ReticulumSwift
import RNSOverMeshCore

// 1. Transport to the MeshCore companion device (TCP here; inject BLE/serial in-app).
let transport = MeshCoreTCPTransport(host: "127.0.0.1", port: 4403)

// 2. Companion client speaking the MeshCore companion protocol.
let companion = MeshCoreClient(transport: transport)

// 3. Configure and build the RNS interface.
var config = MeshCoreDynamicConfig()
config.channelName    = "RNSTunnel"
config.channelSecretHex = "c4d2b6c8254e3b11200f57e95dcb1197"  // openssl rand -hex 16
config.canRoute       = true
config.mode           = .accessPoint       // recommended on LoRa segments

let iface = MeshCoreDynamicInterface(companion: companion, config: config)

// 4. Bring it up and register with Transport.
try await iface.bringUp()
reticulum.transport.register(interface: iface)
```

All nodes sharing a tunnel must use identical `channelIndex`, `channelName`, and
`channelSecretHex`.

### Radios (Layer C)

- **`MeshCoreTCPTransport`** ships in this package (uses `Network.framework`), for
  MeshCore nodes reachable over TCP and for desktop/testing.
- **BLE** and **serial** adapters are supplied by the host app by conforming to
  `MeshCoreTransport`, exactly as RetiOS supplies `BLERNodeTransport` /
  `BLEMeshTransport`. The MeshCore BLE service/characteristic UUIDs are in
  `MeshCoreBLEUUID`.

### Channel interface with RemoteTerm

`MeshCoreChannelInterface` takes a `MeshCoreChannelBackend`:
`CompanionChannelBackend` (a direct radio) or `RemoteTermChannelBackend` (drives a
running [Remote-Terminal-for-MeshCore](https://github.com/jkingsman/Remote-Terminal-for-MeshCore)
over its REST + WebSocket API).

## Testing

```bash
swift test          # unit + wire-parity + loopback suites, 0 failures
```

The suite covers the companion frame codec, the serial/TCP framing, the
command/response client, the three fragmenters and reassembly, the rate limiters
and RNSBIND peer table, all three interfaces end-to-end against mocks, byte-exact
parity against the Python fragmenters, and a two-node Swift↔Swift loopback.

## Status & limitations

- `MeshCoreDynamicInterface` — full parity with the Python driver (routing,
  discovery, rate limiting, retransmission, ACK-gated direct with channel fallback).
- `MeshCoreContactInterface` — `endpointContact` accepts either a public-key hex
  prefix or an advert name (resolved against the device contact list via
  `getContacts`, mirroring the Python driver).
- `RemoteTermChannelBackend` — the WebSocket event filtering is unit-tested; the
  REST/WebSocket transport plumbing needs a live RemoteTerm server and is
  integration-only. The channel tunnel logic is fully tested via the companion
  backend and a mock backend.
- Live Python↔Swift interop over real hardware should be verified on a device before
  relying on it in production.
