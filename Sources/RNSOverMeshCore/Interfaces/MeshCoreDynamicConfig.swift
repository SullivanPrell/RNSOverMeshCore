// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation
import ReticulumSwift

/// Configuration for `MeshCoreDynamicInterface`, mirroring the config keys of the
/// Python `MeshCore_Dynamic_Interface`. Defaults match the reference exactly, so a
/// Swift node interoperates with a Python node using default settings. Radio/timing
/// knobs a test wants to shrink (backoff, heartbeat) are exposed here.
public struct MeshCoreDynamicConfig: Sendable {

    // MARK: Identity / channel
    public var name: String = "MeshCore Dynamic"
    /// Channel slot on the radio (all tunnel nodes must share idx/name/secret).
    public var channelIndex: Int = 0
    public var channelName: String = "RNSTunnel"
    /// 16-byte channel secret as hex (32 hex chars).
    public var channelSecretHex: String = "00000000000000000000000000000000"

    // MARK: Optional radio overrides (applied only when all four are non-zero)
    public var radioFreq: Double = 0     // MHz
    public var radioBw: Double = 0       // kHz
    public var radioSf: Int = 0
    public var radioCr: Int = 0

    // MARK: Fragmentation / pacing
    public var payloadSize: Int = 64
    public var fragmentDelay: TimeInterval = 2.5
    public var directFragDelay: TimeInterval = 0.5
    public var directAckTimeout: TimeInterval = 4.0
    public var directAckTimeoutMax: TimeInterval = 8.0
    public var fragmentTimeout: TimeInterval = 300
    public var rateLimitBps: Int = 0

    // MARK: Outgoing rate limiting
    public var announceRate: TimeInterval = 600
    public var pathReqRate: TimeInterval = 1800
    public var pathReqBurstWindow: TimeInterval = 60
    public var pathResponseBypassWindow: TimeInterval = 15

    // MARK: Broadcast retransmission
    public var announceRetransmitExtra: Int = 2
    public var pathReqRetransmitExtra: Int = 0
    public var retransmitJitterMin: TimeInterval = 8
    public var retransmitJitterMax: TimeInterval = 20

    // MARK: Routing / discovery
    public var canRoute: Bool = true
    public var allowDirect: Bool = true
    public var peerTTL: TimeInterval = 86_400
    public var bitrate: Int = 300
    public var dedupTTL: TimeInterval = 30
    public var unboundReqRetry: TimeInterval = 120

    // MARK: Peer-discovery timing (Python class constants; shrinkable for tests)
    public var bindBackoffMin: TimeInterval = 3
    public var bindBackoffMax: TimeInterval = 15
    public var bindHeartbeat: TimeInterval = 3600
    public var bindResponseWindow: TimeInterval = 60
    public var bindMaxRetries: Int = 3
    public var cleanupInterval: TimeInterval = 30
    /// Initial settle delay before the first discovery request.
    public var discoverySettleDelay: TimeInterval = 5

    // MARK: RNS interface mode
    /// Recommended `.accessPoint` on LoRa segments (see README); default `.full`
    /// mirrors the Python base default.
    public var mode: InterfaceMode = .full

    /// App name reported to the firmware in `CMD_APP_START`.
    public var appName: String = "rnsomc"

    public init() {}

    /// The 16-byte channel secret decoded from `channelSecretHex`, or nil if the
    /// hex is malformed / not 16 bytes.
    public var channelSecret: Data? {
        guard let d = Data(hexString: channelSecretHex), d.count == 16 else { return nil }
        return d
    }
}
