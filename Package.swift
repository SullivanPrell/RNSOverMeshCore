// swift-tools-version: 5.9
import PackageDescription
import Foundation

// RNSOverMeshCore — a Reticulum (RNS) interface addon that tunnels RNS traffic
// over a MeshCore LoRa mesh. Swift reimplementation of comms-engineer/RNS_Over_Meshcore.
//
// LICENSE: GPL-3.0-or-later. This package is a derivative work of the GPL-3.0
// Python project it ports, so it is licensed GPL-3.0. It only *depends on*
// (does not modify) the permissively-licensed ReticulumSwift — GPL works may
// depend on permissive ones — keeping the RNS core license clean. See LICENSE.

// ReticulumSwift dependency.
//
// Consumers get the published release from GitHub. To develop the whole stack
// from sibling checkouts (ReticulumSwift under ../swift_devel/), set
// RETICULUM_LOCAL_DEPS=1 to use the local path instead:
//
//   RETICULUM_LOCAL_DEPS=1 swift test
//
let useLocalDeps = ProcessInfo.processInfo.environment["RETICULUM_LOCAL_DEPS"] != nil
let reticulumDependency: Package.Dependency = useLocalDeps
    ? .package(path: "../swift_devel/ReticulumSwift")
    : .package(url: "https://github.com/SullivanPrell/ReticulumSwift.git", from: "1.28.0")

let package = Package(
    name: "RNSOverMeshCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "RNSOverMeshCore", targets: ["RNSOverMeshCore"])
    ],
    dependencies: [
        reticulumDependency
    ],
    targets: [
        .target(
            name: "RNSOverMeshCore",
            dependencies: [
                .product(name: "ReticulumSwift", package: "ReticulumSwift")
            ],
            path: "Sources/RNSOverMeshCore"
        ),
        .testTarget(
            name: "RNSOverMeshCoreTests",
            dependencies: ["RNSOverMeshCore"],
            path: "Tests/RNSOverMeshCoreTests"
        )
    ]
)
