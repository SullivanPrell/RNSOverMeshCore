# Contributing to RNSOverMeshCore

Thanks for your interest in improving RNSOverMeshCore! This package tunnels
Reticulum (RNS) traffic over a MeshCore LoRa mesh, and it values **wire
compatibility with the Python `comms-engineer/RNS_Over_Meshcore` driver** above
all else — a change that breaks interop with a Python node on the same MeshCore
channel is a regression, even if the Swift tests pass.

## Ground rules

- **Test-driven.** Write a failing test first, implement until green, then commit.
  The Python driver (<https://github.com/comms-engineer/RNS_Over_Meshcore>) and the
  MeshCore [companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md)
  are the sources of truth; new wire-level behavior should be checked against
  captured Python bytes where possible (see `MeshCoreWireParityTests`).
- **No regressions.** The full `swift test` suite must pass before any commit.
- **Keep the seams mockable.** Both injection points — `MeshCoreCompanion`
  (Layer A→B) and `MeshCoreTransport` (Layer C→A) — have mocks so every layer is
  tested with no radio present. New code should stay testable the same way.

## Setup

```sh
git clone https://github.com/SullivanPrell/RNSOverMeshCore.git
cd RNSOverMeshCore
swift build
swift test
```

By default the build fetches the published **ReticulumSwift** release from GitHub.
To develop against a local ReticulumSwift checkout (placed at
`../swift_devel/ReticulumSwift` relative to this repo), set the env toggle:

```sh
RETICULUM_LOCAL_DEPS=1 swift test
```

If you see `SwiftShims` module-cache errors: `rm -rf .build && swift test`.

## Conventions

- **File names:** PascalCase, matching the primary type (`MeshCoreClient.swift`).
- **API naming:** the camelCase equivalent of the Python snake_case name
  (`send_channel` → `sendChannel`), so the two APIs read the same.
- **Bytes:** prefer `Data`; use `[UInt8]` only on performance-critical paths.
- **SPDX:** every file that ports GPL-3.0 Python carries
  `// SPDX-License-Identifier: GPL-3.0-or-later`.
- **Tests:** file `Tests/.../<Feature>Tests.swift`, class `<Feature>Tests`.

## Running a single suite

```sh
swift test --filter MeshCoreWireParityTests
```

## Submitting changes

1. Branch from `main`.
2. Keep commits focused; describe the *why*.
3. Ensure `swift test` is green.
4. Open a pull request describing the change and any interop implications.

## License of contributions

By contributing, you agree your contributions are licensed under the
**GNU General Public License v3.0 or later** ([LICENSE](LICENSE)), the same
license as the project.
