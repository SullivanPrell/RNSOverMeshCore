// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation
import ReticulumSwift

/// Configuration for `MeshCoreContactInterface`, mirroring the Python
/// `MeshCoreInterface` (contact / out-of-band) keys. Radio defaults match the
/// Python reference.
public struct MeshCoreContactConfig: Sendable {
    public var name = "MeshCore Interface"
    /// Destination contact public-key hex (≥ 6 bytes / 12 hex chars). Required for
    /// outbound; without it outbound packets are dropped (as in the Python driver,
    /// which sends only to a configured `endpoint_contact`).
    public var endpointContact = ""
    public var radioFreq: Double = 910.525
    public var radioBw: Double = 62.5
    public var radioSf: Int = 7
    public var radioCr: Int = 5
    public var maxPayload = 160
    public var fragmentDelay: TimeInterval = 0.02
    public var bitrate = 300
    public var hwMtu = 184
    public var mode: InterfaceMode = .gateway
    public var appName = "rnsomc"

    public init() {}
}

/// Reticulum interface that tunnels RNS traffic over MeshCore *direct/contact*
/// messages to a single configured endpoint contact — the Swift port of the
/// contact-based `MeshCoreInterface`.
///
/// Wire format: `base64( [index:1][pos:1 signed] + chunk )` sent as a direct message
/// body (no `"RNS:"` prefix); the final fragment carries a negative position.
public final class MeshCoreContactInterface: Interface, @unchecked Sendable {

    // MARK: Interface conformance
    public let name: String
    public private(set) var bitrate: Int
    public private(set) var isOnline = false
    public let hwMtu: Int?
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
    public var displayName: String { "MeshCoreContactInterface[\(name)]" }

    // MARK: State
    private let companion: MeshCoreCompanion
    private let config: MeshCoreContactConfig
    private let lock = NSRecursiveLock()
    private var reassembler = ContactReassembler()
    private var packetIndex: UInt8 = 0
    /// The endpoint public-key actually used for outbound. Starts as
    /// `config.endpointContact` and is replaced with a resolved pubkey when the
    /// configured value is an advert name (see `resolveEndpoint`).
    private var resolvedEndpoint: String
    private var outContinuation: AsyncStream<OutItem>.Continuation?
    private var backgroundTasks: [Task<Void, Never>] = []

    private struct OutItem { let dest: String; let text: String }

    public init(companion: MeshCoreCompanion, config: MeshCoreContactConfig = .init()) {
        self.companion = companion
        self.config = config
        self.name = config.name
        self.bitrate = config.bitrate
        self.mode = config.mode
        self.hwMtu = config.hwMtu
        self.resolvedEndpoint = config.endpointContact
    }

    // MARK: Lifecycle

    public func start() throws {
        let task = Task { [weak self] in try? await self?.bringUp() }
        withLock { backgroundTasks.append(Task { _ = await task.value }) }
    }

    public func bringUp() async throws {
        companion.onContactMessage = { [weak self] msg in self?.handleContact(msg) }
        companion.onDisconnect = { [weak self] _ in self?.withLock { self?.isOnline = false } }
        _ = try await companion.start()
        if config.radioFreq > 0, config.radioBw > 0, config.radioSf > 0, config.radioCr > 0 {
            try? await companion.setRadio(freq: config.radioFreq, bw: config.radioBw,
                                          sf: config.radioSf, cr: config.radioCr)
        }
        await resolveEndpoint()
        startOutgoingWorker()
        withLock { isOnline = true }
    }

    /// If `endpointContact` is an advert name rather than a public-key hex, look it
    /// up in the device contact list and adopt the matching contact's public key —
    /// mirroring the Python driver's `endpoint_contact` advert-name resolution.
    private func resolveEndpoint() async {
        let configured = config.endpointContact
        guard !configured.isEmpty, !Self.looksLikePublicKey(configured) else { return }
        guard let contacts = try? await companion.getContacts() else { return }
        let needle = configured.lowercased()
        if let match = contacts.first(where: { $0.advName.lowercased().contains(needle) }) {
            withLock { resolvedEndpoint = match.publicKey }
        }
    }

    /// A ≥12-hex-char string decodable as bytes is treated as a public-key prefix,
    /// not an advert name (mirrors the Python hex check).
    private static func looksLikePublicKey(_ s: String) -> Bool {
        s.count >= 12 && Data(hexString: s) != nil
    }

    public func stop() {
        withLock { isOnline = false; outContinuation?.finish(); outContinuation = nil }
        let tasks = withLock { () -> [Task<Void, Never>] in let t = backgroundTasks; backgroundTasks.removeAll(); return t }
        tasks.forEach { $0.cancel() }
        companion.stop()
    }

    // MARK: Outbound

    public func send(_ packet: Packet) throws {
        guard isOnline else { return }
        let dest = withLock { resolvedEndpoint }
        guard !dest.isEmpty else { return }                            // no endpoint → drop (as Python)
        let wire = wrapIfac(try packet.pack())
        let (idx, cont) = withLock { () -> (UInt8, AsyncStream<OutItem>.Continuation?) in
            packetIndex = packetIndex &+ 1
            txBytes += wire.count
            txPackets += 1
            return (packetIndex, outContinuation)
        }
        for frag in ContactFragmenter.fragments(wire, index: idx, maxPayload: config.maxPayload) {
            cont?.yield(OutItem(dest: dest, text: frag))
        }
    }

    private func startOutgoingWorker() {
        let (stream, continuation) = AsyncStream.makeStream(of: OutItem.self)
        withLock { outContinuation = continuation }
        let task = Task { [weak self] in
            for await item in stream { await self?.sendFragment(item) }
        }
        withLock { backgroundTasks.append(task) }
    }

    private func sendFragment(_ item: OutItem) async {
        _ = try? await companion.sendDirectMessage(pubkeyPrefix: item.dest, text: item.text)
        if config.fragmentDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(config.fragmentDelay * 1_000_000_000))
        }
    }

    // MARK: Inbound

    private func handleContact(_ msg: MeshCoreContactMessage) {
        guard let frag = ContactFragmenter.decode(msg.text) else { return }
        let full = withLock { reassembler.add(sender: msg.pubkeyPrefix, fragment: frag) }
        guard let full, !full.isEmpty else { return }
        withLock { rxBytes += full.count; rxPackets += 1 }
        if let handler = rawInboundHandler { handler(full, self) }
        else if let packet = try? Packet.unpack(full) { inboundHandler?(packet, self) }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

/// Reassembles contact-variant fragments keyed by `(sender, packet index)`,
/// completing when the final (negative-position) fragment arrives — joining the
/// present positions in ascending order. Mirrors `_handle_incoming_payload`.
struct ContactReassembler {
    private struct Key: Hashable { let sender: String; let index: Int }
    private var buffers: [Key: [Int: Data]] = [:]

    mutating func add(sender: String, fragment: ContactFragment) -> Data? {
        let key = Key(sender: sender, index: fragment.index)
        buffers[key, default: [:]][fragment.sequence] = fragment.payload
        guard fragment.isFinal else { return nil }
        let parts = buffers.removeValue(forKey: key) ?? [:]
        var full = Data()
        for position in parts.keys.sorted() { full.append(parts[position]!) }
        return full.isEmpty ? nil : full
    }
}
