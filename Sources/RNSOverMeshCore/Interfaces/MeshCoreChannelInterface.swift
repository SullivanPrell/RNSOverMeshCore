// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation
import CryptoKit
import ReticulumSwift

/// Configuration for `MeshCoreChannelInterface`, mirroring the Python
/// `MeshCore_Channel_Interface` keys.
public struct MeshCoreChannelConfig: Sendable {
    public var name = "MeshCore Channel"
    public var channelIndex = 39
    public var channelName = "RNSTunnel"
    public var channelSecretHex = "c4d2b6c8254e3b11200f57e95dcb1197"
    public var radioFreq: Double = 0
    public var radioBw: Double = 0
    public var radioSf: Int = 0
    public var radioCr: Int = 0
    public var payloadSize = 64
    public var fragmentDelay: TimeInterval = 2.5
    public var fragmentTimeout: TimeInterval = 3600
    public var rateLimitBps = 0
    public var dedupTTL: TimeInterval = 30
    public var cleanupInterval: TimeInterval = 60
    public var bitrate = 300
    public var mode: InterfaceMode = .full
    /// Basis for the fallback src_id when the backend does not report a pubkey
    /// (Python uses the hostname). Set deterministically in tests.
    public var nodeIdentity = ProcessInfo.processInfo.hostName
    public var appName = "rnsomc"

    public init() {}

    public var channelSecret: Data? {
        guard let d = Data(hexString: channelSecretHex), d.count == 16 else { return nil }
        return d
    }
}

/// Reticulum interface that tunnels RNS traffic over a shared MeshCore channel
/// (broadcast only) — the Swift port of `MeshCore_Channel_Interface`. Any node on
/// the channel running this interface can relay. Routing intelligence lives in RNS
/// Transport; this interface is a dumb shared medium.
///
/// Wire format: `"RNS:" + base64url( magic 'RN' + [idx][src_id:4][pkt_id][total] + payload )`.
/// The 4-byte src_id is embedded because MeshCore channel messages do not expose the
/// sender's pubkey. Pluggable `MeshCoreChannelBackend` selects radio vs RemoteTerm.
public final class MeshCoreChannelInterface: Interface, @unchecked Sendable {

    // MARK: Interface conformance
    public let name: String
    public var bitrate: Int
    public private(set) var isOnline = false
    public let hwMtu: Int? = Constants.mtu
    public let fixedMtu = true
    public let mode: InterfaceMode
    public var inboundHandler: ((Packet, any Interface) -> Void)?
    public var rawInboundHandler: ((Data, any Interface) -> Void)?
    public private(set) var rxBytes = 0
    public private(set) var txBytes = 0
    public private(set) var rxPackets = 0
    public private(set) var txPackets = 0
    public var ifacIdentity: Identity?
    public var ifacKey: Data?
    public var ifacSize = 8
    public var displayName: String { "MeshCoreChannelInterface[\(name)]" }

    // MARK: State
    private let backend: MeshCoreChannelBackend
    private let config: MeshCoreChannelConfig
    private let lock = NSRecursiveLock()
    private var reassembler: FragmentReassembler<ChanKey>
    private var srcID = Data([0, 0, 0, 0])
    private var packetID: UInt8 = 0
    private var outContinuation: AsyncStream<String>.Continuation?
    private var backgroundTasks: [Task<Void, Never>] = []

    private struct ChanKey: Hashable { let src: String; let packetID: UInt8 }

    public init(backend: MeshCoreChannelBackend, config: MeshCoreChannelConfig = .init()) {
        self.backend = backend
        self.config = config
        self.name = config.name
        self.bitrate = config.bitrate
        self.mode = config.mode
        self.reassembler = FragmentReassembler<ChanKey>(dedupTTL: config.dedupTTL,
                                                        fragmentTimeout: config.fragmentTimeout)
    }

    // MARK: Lifecycle

    public func start() throws {
        let task = Task { [weak self] in try? await self?.bringUp() }
        withLock { backgroundTasks.append(Task { _ = await task.value }) }
    }

    public func bringUp() async throws {
        backend.onChannelText = { [weak self] text in self?.handleText(text) }
        backend.onDisconnect = { [weak self] _ in self?.withLock { self?.isOnline = false } }
        let pubkey = try await backend.start()
        withLock { srcID = Self.deriveSrcID(pubkey: pubkey, config: config) }
        startOutgoingWorker()
        startCleanupLoop()
        withLock { isOnline = true }
    }

    public func stop() {
        withLock {
            isOnline = false
            outContinuation?.finish()
            outContinuation = nil
        }
        let tasks = withLock { () -> [Task<Void, Never>] in let t = backgroundTasks; backgroundTasks.removeAll(); return t }
        tasks.forEach { $0.cancel() }
        backend.stop()
    }

    // MARK: Outbound

    public func send(_ packet: Packet) throws {
        guard isOnline else { return }
        let wire = wrapIfac(try packet.pack())
        let (pid, src) = withLock { () -> (UInt8, Data) in
            packetID = packetID &+ 1
            txBytes += wire.count
            txPackets += 1
            return (packetID, srcID)
        }
        let frags = ChannelFragmenter.fragments(wire, sourceID: src, packetID: pid,
                                                payloadSize: config.payloadSize)
        let cont = withLock { outContinuation }
        frags.forEach { cont?.yield($0) }
    }

    private func startOutgoingWorker() {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        withLock { outContinuation = continuation }
        let task = Task { [weak self] in
            for await frag in stream { await self?.sendFragment(frag) }
        }
        withLock { backgroundTasks.append(task) }
    }

    private func sendFragment(_ frag: String) async {
        try? await backend.sendChannelText(frag)
        var delay = config.fragmentDelay
        if config.rateLimitBps > 0 {
            delay = max(delay, Double(frag.count * 3 / 4) / Double(config.rateLimitBps))
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    // MARK: Inbound

    private func handleText(_ text: String) {
        guard let r = text.range(of: ChannelFragmenter.prefix)?.lowerBound else { return }
        guard let frag = ChannelFragmenter.decode(String(text[r...])) else { return }
        let (own, now) = withLock { (srcID, Self.now()) }
        if frag.sourceID == own { return }                              // our own echo

        let key = ChanKey(src: frag.sourceID.hexEncoded, packetID: frag.packetID)
        let full = withLock {
            reassembler.add(key: key, index: frag.index, total: frag.total,
                            payload: frag.payload, now: now)
        }
        guard let full, !full.isEmpty else { return }
        withLock { rxBytes += full.count; rxPackets += 1 }
        if let handler = rawInboundHandler { handler(full, self) }
        else if let packet = try? Packet.unpack(full) { inboundHandler?(packet, self) }
    }

    // MARK: Maintenance

    private func startCleanupLoop() {
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.config.cleanupInterval * 1_000_000_000))
                let now = Self.now()
                self.withLock { self.reassembler.evictStale(now: now) }
            }
        }
        withLock { backgroundTasks.append(task) }
    }

    // MARK: Helpers

    /// src_id = first 4 bytes of the node pubkey when known, else
    /// `sha256("<secret_hex>:<node_identity>")[:4]`. Mirrors `_derive_local_src_id`
    /// with the direct-mode pubkey override.
    static func deriveSrcID(pubkey: String?, config: MeshCoreChannelConfig) -> Data {
        if let pubkey, pubkey.count >= 8,
           let d = Data(hexString: String(pubkey.prefix(8))), d.count == 4 {
            return d
        }
        let basis = "\(config.channelSecretHex):\(config.nodeIdentity)"
        return Data(SHA256.hash(data: Data(basis.utf8)).prefix(4))
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
