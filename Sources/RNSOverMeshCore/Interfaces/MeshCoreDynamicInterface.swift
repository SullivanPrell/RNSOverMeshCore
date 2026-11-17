// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation
import ReticulumSwift

/// Reticulum interface that tunnels RNS traffic over a MeshCore LoRa mesh using the
/// hybrid channel-broadcast / unicast-direct strategy with demand-driven RNSBIND
/// peer discovery — the Swift port of `MeshCore_Dynamic_Interface`.
///
/// Radio I/O is injected as a `MeshCoreCompanion` (mirroring `RNodeTransport`), so
/// the whole interface is unit-testable against a mock. It conforms to
/// ReticulumSwift's `Interface`: outbound `send(_:)` IFAC-wraps, fragments, and
/// routes; inbound reassembled packets are delivered via `rawInboundHandler`
/// exactly like `BLEMeshInterface`.
public final class MeshCoreDynamicInterface: Interface, @unchecked Sendable {

    // MARK: - Interface conformance
    public let name: String
    public var bitrate: Int
    public private(set) var isOnline: Bool = false
    public let hwMtu: Int? = Constants.mtu
    public let fixedMtu: Bool = true
    public let mode: InterfaceMode

    public var inboundHandler: ((Packet, any Interface) -> Void)?
    public var rawInboundHandler: ((Data, any Interface) -> Void)?

    public private(set) var rxBytes: Int = 0
    public private(set) var txBytes: Int = 0
    public private(set) var rxPackets: Int = 0
    public private(set) var txPackets: Int = 0

    public var ifacIdentity: Identity?
    public var ifacKey: Data?
    public var ifacSize: Int = 8

    public var displayName: String { "MeshCoreDynamicInterface[\(name)]" }

    // MARK: - Collaborators & state
    private let companion: MeshCoreCompanion
    private let config: MeshCoreDynamicConfig

    private let lock = NSRecursiveLock()
    private var peerTable = PeerTable()
    private var reassembler: FragmentReassembler<DynKey>
    private var announceLimiter = AnnounceRateLimiter()
    private var pathReqLimiter = PathRequestRateLimiter()
    private var bypass = PathResponseBypass()
    private var packetID: UInt32 = 0
    private var ownName = ""
    private var ownKey = ""
    private var bindResponsePending = false

    private struct DynKey: Hashable { let sender: String; let packetID: UInt32 }

    private enum Route { case channel; case direct(String) }
    private struct OutFragment { let route: Route; let text: String }

    private var outContinuation: AsyncStream<OutFragment>.Continuation?
    private var backgroundTasks: [Task<Void, Never>] = []

    // MARK: - Init

    public init(companion: MeshCoreCompanion, config: MeshCoreDynamicConfig = .init()) {
        self.companion = companion
        self.config = config
        self.name = config.name
        self.bitrate = config.bitrate
        self.mode = config.mode
        self.reassembler = FragmentReassembler<DynKey>(dedupTTL: config.dedupTTL,
                                                       fragmentTimeout: config.fragmentTimeout)
    }

    // MARK: - Lifecycle

    /// Interface-protocol entry: kicks off async bring-up (fire-and-forget), like the
    /// Python constructor. Prefer `bringUp()` when you need to await readiness.
    public func start() throws {
        let task = Task { [weak self] in try? await self?.bringUp() }
        lock.lock(); backgroundTasks.append(Task { _ = await task.value }); lock.unlock()
    }

    /// Connect the companion, configure radio/channel, wire up event handlers, and
    /// start the outgoing worker plus discovery/cleanup loops. Awaitable.
    public func bringUp() async throws {
        companion.onChannelMessage = { [weak self] msg in self?.handleChannelMessage(msg) }
        companion.onContactMessage = { [weak self] msg in self?.handleContactMessage(msg) }
        companion.onDisconnect = { [weak self] _ in self?.markOffline() }

        let info = try await companion.start()
        withLock { ownName = info.name; ownKey = info.publicKey }

        if config.radioFreq > 0, config.radioBw > 0, config.radioSf > 0, config.radioCr > 0 {
            try? await companion.setRadio(freq: config.radioFreq, bw: config.radioBw,
                                          sf: config.radioSf, cr: config.radioCr)
        }
        if let secret = config.channelSecret {
            try? await companion.setChannel(index: config.channelIndex, name: config.channelName,
                                            secret: secret)
        }

        startOutgoingWorker()
        startBackgroundLoops()

        withLock { isOnline = true }
    }

    public func stop() {
        markOffline()
        lock.lock()
        outContinuation?.finish()
        outContinuation = nil
        let tasks = backgroundTasks
        backgroundTasks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        companion.stop()
    }

    private func markOffline() { lock.lock(); isOnline = false; lock.unlock() }

    // MARK: - Outbound (Interface.send → processOutgoing)

    public func send(_ packet: Packet) throws {
        guard isOnline else { return }
        let raw = try packet.pack()
        enqueueOutgoing(wrapIfac(raw))     // IFAC-wrap → the wire bytes we fragment/route
    }

    /// Port of `processOutgoing`: rate-limit, assign a packet id, fragment, choose a
    /// route, enqueue, and schedule broadcast retransmits.
    private func enqueueOutgoing(_ wire: Data) {
        guard let b0 = wire.first else { return }
        let ptype = b0 & 0x03
        let dtype = (b0 >> 2) & 0x03
        let now = Self.now()

        lock.lock()

        // Per-destination announce rate limiter (with path-response bypass).
        if ptype == RNSHeaderInspector.PacketType.announce.rawValue,
           config.announceRate > 0, let dest = Self.destID10(wire) {
            let answering = bypass.consume(dest: dest, now: now)
            if answering {
                announceLimiter.record(dest: dest, now: now)
            } else if !announceLimiter.allow(dest: dest, now: now, rate: config.announceRate) {
                lock.unlock(); return                          // suppressed
            }
        }

        // Per-destination path-request rate limiter with burst window.
        if ptype == RNSHeaderInspector.PacketType.data.rawValue,
           dtype == RNSHeaderInspector.DestinationType.plain.rawValue,
           config.pathReqRate > 0, let dest = Self.destID10(wire) {
            if !pathReqLimiter.allow(dest: dest, now: now, rate: config.pathReqRate,
                                     burstWindow: config.pathReqBurstWindow) {
                lock.unlock(); return                          // suppressed
            }
        }

        let pktID = packetID
        packetID = packetID &+ 1

        // Route selection.
        let broadcast = RNSHeaderInspector.isBroadcast(wire)
        var route = Route.channel
        if !broadcast, config.allowDirect, let token = RNSHeaderInspector.extractToken(wire),
           let mcKey = peerTable.mcKey(forToken: token) {
            route = .direct(mcKey)
        }
        txBytes += wire.count
        txPackets += 1
        lock.unlock()

        let fragments = DynamicFragmenter.fragments(wire, packetID: pktID, payloadSize: config.payloadSize)
        for f in fragments { enqueue(OutFragment(route: route, text: f)) }

        // Broadcast-only retransmission (announces / path requests can't be ACK'd).
        var extra = 0
        if broadcast {
            if ptype == RNSHeaderInspector.PacketType.announce.rawValue { extra = config.announceRetransmitExtra }
            else if dtype == RNSHeaderInspector.DestinationType.plain.rawValue { extra = config.pathReqRetransmitExtra }
        }
        if extra > 0 { scheduleRetransmits(fragments, route: route, count: extra) }
    }

    private func enqueue(_ item: OutFragment) {
        lock.lock(); let cont = outContinuation; lock.unlock()
        cont?.yield(item)
    }

    // MARK: - Outgoing worker

    private func startOutgoingWorker() {
        let (stream, continuation) = AsyncStream.makeStream(of: OutFragment.self)
        lock.lock(); outContinuation = continuation; lock.unlock()
        let task = Task { [weak self] in
            for await item in stream {
                await self?.sendFragment(item)
            }
        }
        lock.lock(); backgroundTasks.append(task); lock.unlock()
    }

    /// Port of `_async_outgoing_worker`'s per-fragment handling: direct send with an
    /// ACK wait (falling back to channel on failure), else a channel broadcast, then
    /// the inter-fragment pacing delay.
    private func sendFragment(_ item: OutFragment) async {
        switch item.route {
        case .direct(let key):
            do {
                let sent = try await companion.sendDirectMessage(pubkeyPrefix: key, text: item.text)
                let suggested = TimeInterval(sent.suggestedTimeoutMs) / 1000.0 * 1.2
                let ackTimeout = min(max(config.directAckTimeout, suggested), config.directAckTimeoutMax)
                let acked = await companion.waitForAck(code: sent.expectedAckHex, timeout: ackTimeout)
                if !acked { throw MeshCoreTransportError.timedOut }
            } catch {
                // Fall back to a channel broadcast of the same fragment.
                enqueue(OutFragment(route: .channel, text: item.text))
            }
        case .channel:
            try? await companion.sendChannelMessage(index: config.channelIndex, text: item.text)
        }
        await pace(direct: { if case .direct = item.route { return true } else { return false } }(),
                   fragmentLength: item.text.count)
    }

    private func pace(direct: Bool, fragmentLength: Int) async {
        var delay = direct ? config.directFragDelay : config.fragmentDelay
        if config.rateLimitBps > 0 {
            let bits = (fragmentLength * 3 / 4) * 8
            delay = max(delay, Double(bits) / Double(config.rateLimitBps))
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    private func scheduleRetransmits(_ fragments: [String], route: Route, count: Int) {
        let task = Task { [weak self] in
            guard let self else { return }
            for _ in 0 ..< count {
                let jitter = Double.random(in: self.config.retransmitJitterMin ... self.config.retransmitJitterMax)
                try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
                if Task.isCancelled || !self.isOnline { return }
                for f in fragments { self.enqueue(OutFragment(route: route, text: f)) }
            }
        }
        lock.lock(); backgroundTasks.append(task); lock.unlock()
    }

    // MARK: - Inbound

    private func handleChannelMessage(_ msg: MeshCoreChannelMessage) {
        let text = msg.text
        let rnsIdx = text.range(of: DynamicFragmenter.prefix)?.lowerBound
        let bindIdx = earliestBindPrefix(in: text)

        // A bind prefix appearing before any "RNS:" marker is a discovery message.
        if let b = bindIdx, rnsIdx == nil || b < rnsIdx! {
            handleBind(text)
            return
        }
        guard let r = rnsIdx else { return }
        let sender = String(text[text.startIndex ..< r]).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        processTunnelText(String(text[r...]), sender: sender)
    }

    private func handleContactMessage(_ msg: MeshCoreContactMessage) {
        guard msg.text.hasPrefix(DynamicFragmenter.prefix) else { return }
        lock.lock(); let sender = peerTable.resolveSenderKey(msg.pubkeyPrefix); lock.unlock()
        processTunnelText(msg.text, sender: sender)
    }

    private func earliestBindPrefix(in text: String) -> String.Index? {
        let req = text.range(of: PeerTable.bindReqPrefix)?.lowerBound
        let bind = text.range(of: PeerTable.bindPrefix)?.lowerBound
        switch (req, bind) {
        case let (r?, b?): return min(r, b)
        case let (r?, nil): return r
        case let (nil, b?): return b
        default: return nil
        }
    }

    private func handleBind(_ text: String) {
        lock.lock(); let own = ownName; lock.unlock()
        guard let msg = PeerTable.parseBind(text, ownName: own) else { return }
        lock.lock()
        peerTable.applyBind(msg, now: Self.now())
        let shouldRespond = msg.isRequest && !ownKey.isEmpty && !bindResponsePending
        if shouldRespond { bindResponsePending = true }
        lock.unlock()
        if shouldRespond { scheduleDelayedBindResponse() }
    }

    /// Port of `_process_tunnel_text`: decode a fragment, reassemble, learn routing,
    /// flag path responses, and deliver the completed packet upward.
    private func processTunnelText(_ text: String, sender: String) {
        lock.lock(); let own = ownName; lock.unlock()
        if !sender.isEmpty, sender == own { return }
        guard let frag = DynamicFragmenter.decode(text) else { return }

        let now = Self.now()
        lock.lock()
        let full = reassembler.add(key: DynKey(sender: sender, packetID: frag.packetID),
                                   index: frag.index, total: frag.total, payload: frag.payload, now: now)
        lock.unlock()
        guard let full, !full.isEmpty else { return }

        learnRouting(from: full, sender: sender, now: now)

        // A DATA+PLAIN inbound packet is a path request → let the resulting
        // demand-driven announce bypass the announce rate limiter.
        if RNSHeaderInspector.packetType(full) == .data,
           RNSHeaderInspector.destinationType(full) == .plain,
           let dest = Self.destID10(full) {
            lock.lock(); bypass.markPending(dest: dest, now: now, window: config.pathResponseBypassWindow); lock.unlock()
        }

        deliver(full)
    }

    private func learnRouting(from full: Data, sender: String, now: TimeInterval) {
        guard !sender.isEmpty, let token = RNSHeaderInspector.extractToken(full) else { return }
        lock.lock()
        if let mcKey = peerTable.mcKey(forSender: sender) {
            peerTable.mapToken(token, toMcKey: mcKey)
            // Pre-bind the link id from a LINK_REQUEST so the eventual link data routes directly.
            if RNSHeaderInspector.packetType(full) == .linkRequest,
               let linkID = RNSHeaderInspector.linkID(fromLinkRequest: full) {
                peerTable.mapToken(linkID, toMcKey: mcKey)
            }
            lock.unlock()
        } else {
            peerTable.stashPendingToken(token, sender: sender)
            let allow = peerTable.allowUnboundRequest(sender: sender, now: now,
                                                      retryInterval: config.unboundReqRetry)
            lock.unlock()
            if allow { Task { [weak self] in await self?.sendBindRequest() } }
        }
    }

    private func deliver(_ wire: Data) {
        lock.lock(); rxBytes += wire.count; rxPackets += 1; lock.unlock()
        if let handler = rawInboundHandler {
            handler(wire, self)
        } else if let packet = try? Packet.unpack(wire) {
            inboundHandler?(packet, self)
        }
    }

    // MARK: - Discovery / maintenance loops

    private func capability() -> String {
        config.canRoute ? PeerTable.capabilityRouter : PeerTable.capabilityEdge
    }

    private func startBackgroundLoops() {
        let discovery = Task { [weak self] in _ = await self?.bindDiscoveryLoop() }
        let cleanup = Task { [weak self] in _ = await self?.cleanupLoop() }
        withLock { backgroundTasks.append(contentsOf: [discovery, cleanup]) }
    }

    private func bindDiscoveryLoop() async {
        try? await Task.sleep(nanoseconds: UInt64(config.discoverySettleDelay * 1_000_000_000))
        var retries = 0
        while !Task.isCancelled {
            let (havePeers, key, online) = withLock { (peerTable.hasPeers, ownKey, isOnline) }
            if !havePeers, retries < config.bindMaxRetries {
                if online, !key.isEmpty { await sendBindRequest() }
                retries += 1
                try? await Task.sleep(nanoseconds: UInt64(config.bindResponseWindow * 1_000_000_000))
            } else {
                retries = 0
                if online, !key.isEmpty {
                    try? await companion.sendChannelMessage(index: config.channelIndex,
                                                            text: "\(PeerTable.bindPrefix)\(key):\(capability())")
                }
                try? await Task.sleep(nanoseconds: UInt64(config.bindHeartbeat * 1_000_000_000))
            }
        }
    }

    private func sendBindRequest() async {
        let (key, online) = withLock { (ownKey, isOnline) }
        guard online, !key.isEmpty else { return }
        try? await companion.sendChannelMessage(index: config.channelIndex,
                                                text: "\(PeerTable.bindReqPrefix)\(key):\(capability())")
    }

    private func scheduleDelayedBindResponse() {
        let task = Task { [weak self] in
            guard let self else { return }
            let delay = Double.random(in: self.config.bindBackoffMin ... self.config.bindBackoffMax)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            defer { self.withLock { self.bindResponsePending = false } }
            let (key, online) = self.withLock { (self.ownKey, self.isOnline) }
            if online, !key.isEmpty {
                try? await self.companion.sendChannelMessage(index: self.config.channelIndex,
                                                             text: "\(PeerTable.bindPrefix)\(key):\(self.capability())")
            }
        }
        lock.lock(); backgroundTasks.append(task); lock.unlock()
    }

    private func cleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(config.cleanupInterval * 1_000_000_000))
            let now = Self.now()
            withLock {
                reassembler.evictStale(now: now)
                peerTable.expirePeers(now: now, ttl: config.peerTTL)
                announceLimiter.evictStale(now: now, rate: config.announceRate)
                pathReqLimiter.evictStale(now: now, rate: config.pathReqRate)
                bypass.evictStale(now: now)
            }
        }
    }

    // MARK: - Helpers

    /// Reticulum's 10-byte destination id used for rate-limiter keys (`data[2:12]`).
    private static func destID10(_ wire: Data) -> Data? {
        guard wire.count >= 12 else { return nil }
        return Data(wire[(wire.startIndex + 2) ..< (wire.startIndex + 12)])
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Synchronous scoped locking. Being a non-async method, it is safe to call from
    /// async contexts (the lock is never held across a suspension point).
    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
