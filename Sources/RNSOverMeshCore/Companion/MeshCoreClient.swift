import Foundation

/// Errors from the companion command layer.
public enum MeshCoreCompanionError: Error, Equatable {
    /// Firmware returned `PACKET_ERROR` (with its error code, if any).
    case firmwareError(code: UInt8?)
    /// The firmware's response was not the type the command expected.
    case unexpectedResponse
    /// A command was issued while the client was not running / connected.
    case notStarted
}

/// Concrete `MeshCoreCompanion` that speaks the companion frame codec
/// (`MeshCoreFrames`) over an injected `MeshCoreTransport`.
///
/// Implements the command-queue discipline `companion_protocol.md` requires: one
/// command in flight at a time, response matched by packet type, per-command
/// timeout. `MESSAGES_WAITING` pushes trigger a drain loop that repeatedly runs
/// `CMD_SYNC_NEXT_MESSAGE` until `NO_MORE_MSGS`, dispatching each received message
/// to the event callbacks — the analog of `meshcore_py`'s
/// `start_auto_message_fetching`.
///
/// All internal state is confined to a single serial dispatch queue; command
/// methods bridge to it with checked continuations. `@unchecked Sendable` is sound
/// because every mutable field is only ever touched on `queue`.
public final class MeshCoreClient: MeshCoreCompanion, @unchecked Sendable {

    // MARK: Injected
    private let transport: MeshCoreTransport
    private let appName: String
    private let defaultTimeout: TimeInterval

    // MARK: Callbacks (set before start; see MeshCoreCompanion contract)
    public var onChannelMessage: ((MeshCoreChannelMessage) -> Void)?
    public var onContactMessage: ((MeshCoreContactMessage) -> Void)?
    public var onAck: ((MeshCoreAck) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?
    public private(set) var selfInfo: MeshCoreSelfInfo?

    // MARK: Serial state (touch only on `queue`)
    private let queue = DispatchQueue(label: "network.reticulum.rnsomc.meshcore-client")

    private struct Command {
        let frame: Data
        let expect: Set<UInt8>
        let continuation: CheckedContinuation<MeshCoreEvent, Error>
        let timeout: TimeInterval
    }
    private var pendingCommands: [Command] = []
    private var inflight: Command?
    private var inflightTimeout: DispatchWorkItem?

    private struct AckWaiter { let id: UUID; let continuation: CheckedContinuation<Bool, Never> }
    private var ackWaiters: [String: [AckWaiter]] = [:]
    private var recentAcks: [String: Date] = [:]

    private var running = false
    private var draining = false

    // Multi-frame CONTACT accumulation while a getContacts command is in flight.
    private var collectingContacts = false
    private var contactsBuffer: [MeshCoreContact] = []

    // MARK: Init

    /// - Parameters:
    ///   - transport: the raw byte transport (TCP/serial/BLE), injected by the host.
    ///   - appName: identifier sent in `CMD_APP_START` (default "rnsomc").
    ///   - commandTimeout: per-command response timeout (default 5s, per the protocol doc).
    public init(transport: MeshCoreTransport, appName: String = "rnsomc",
                commandTimeout: TimeInterval = 5.0) {
        self.transport = transport
        self.appName = appName
        self.defaultTimeout = commandTimeout
    }

    // MARK: Lifecycle

    public func start() async throws -> MeshCoreSelfInfo {
        transport.onFrame = { [weak self] frame in
            guard let self else { return }
            self.queue.async { self.handleFrame(frame) }
        }
        transport.onDisconnect = { [weak self] err in
            guard let self else { return }
            self.queue.async { self.handleDisconnect(err) }
        }

        try await transport.start()
        queue.async { self.running = true }

        let event = try await sendCommand(MeshCoreFrames.encodeAppStart(appName: appName),
                                          expect: [MeshCorePacket.selfInfo.rawValue],
                                          timeout: max(defaultTimeout, 10))
        guard case .selfInfo(let info) = event else { throw MeshCoreCompanionError.unexpectedResponse }
        // Publish synchronously so `selfInfo` is visible the instant `start()`
        // returns. Safe: the awaiting continuation resumed off `queue`, so this
        // `sync` cannot deadlock.
        queue.sync { self.selfInfo = info }
        return info
    }

    public func stop() {
        queue.async {
            self.running = false
            self.failAllPending(MeshCoreTransportError.notConnected)
        }
        transport.stop()
    }

    // MARK: Commands

    public func setRadio(freq: Double, bw: Double, sf: Int, cr: Int) async throws {
        _ = try await sendCommand(MeshCoreFrames.encodeSetRadio(freq: freq, bw: bw, sf: sf, cr: cr),
                                  expect: [MeshCorePacket.ok.rawValue])
    }

    public func setChannel(index: Int, name: String, secret: Data) async throws {
        _ = try await sendCommand(MeshCoreFrames.encodeSetChannel(index: index, name: name, secret: secret),
                                  expect: [MeshCorePacket.ok.rawValue])
    }

    public func sendChannelMessage(index: Int, text: String) async throws {
        // Firmware answers OK (some builds MSG_SENT); accept either.
        _ = try await sendCommand(MeshCoreFrames.encodeSendChannelMessage(index: index, text: text,
                                                                          timestamp: Self.unixNow()),
                                  expect: [MeshCorePacket.ok.rawValue, MeshCorePacket.msgSent.rawValue])
    }

    @discardableResult
    public func sendDirectMessage(pubkeyPrefix: String, text: String) async throws -> MeshCoreMsgSent {
        guard let frame = MeshCoreFrames.encodeSendDirectMessage(pubkeyPrefix: pubkeyPrefix, text: text,
                                                                 timestamp: Self.unixNow()) else {
            throw MeshCoreCompanionError.unexpectedResponse
        }
        let event = try await sendCommand(frame, expect: [MeshCorePacket.msgSent.rawValue])
        guard case .msgSent(let sent) = event else { throw MeshCoreCompanionError.unexpectedResponse }
        return sent
    }

    public func waitForAck(code: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                // Already delivered within the window (ACK raced ahead of this call)?
                if let seen = self.recentAcks[code], Date().timeIntervalSince(seen) < timeout {
                    cont.resume(returning: true)
                    return
                }
                let id = UUID()
                self.ackWaiters[code, default: []].append(AckWaiter(id: id, continuation: cont))
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard var list = self.ackWaiters[code],
                          let idx = list.firstIndex(where: { $0.id == id }) else { return }
                    let waiter = list.remove(at: idx)
                    self.ackWaiters[code] = list.isEmpty ? nil : list
                    waiter.continuation.resume(returning: false)
                }
                self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
            }
        }
    }

    public func getContacts() async throws -> [MeshCoreContact] {
        queue.sync { self.collectingContacts = true; self.contactsBuffer.removeAll() }
        defer { queue.sync { self.collectingContacts = false } }
        _ = try await sendCommand(MeshCoreFrames.encodeGetContacts(),
                                  expect: [MeshCorePacket.contactEnd.rawValue])
        return queue.sync { self.contactsBuffer }
    }

    // MARK: Command engine (all on `queue`)

    private func sendCommand(_ frame: Data, expect: Set<UInt8>,
                             timeout: TimeInterval? = nil) async throws -> MeshCoreEvent {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.pendingCommands.append(Command(frame: frame, expect: expect,
                                                    continuation: cont,
                                                    timeout: timeout ?? self.defaultTimeout))
                self.pump()
            }
        }
    }

    private func pump() {
        guard running, inflight == nil, !pendingCommands.isEmpty else { return }
        let cmd = pendingCommands.removeFirst()
        inflight = cmd
        do {
            try transport.send(cmd.frame)
        } catch {
            inflight = nil
            cmd.continuation.resume(throwing: error)
            pump()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.timeoutInflight() }
        inflightTimeout = work
        queue.asyncAfter(deadline: .now() + cmd.timeout, execute: work)
    }

    private func finishInflight() {
        inflightTimeout?.cancel()
        inflightTimeout = nil
        inflight = nil
    }

    private func timeoutInflight() {
        guard let cmd = inflight else { return }
        finishInflight()
        cmd.continuation.resume(throwing: MeshCoreTransportError.timedOut)
        pump()
    }

    private func handleFrame(_ frame: Data) {
        guard let event = MeshCoreFrames.parse(frame), let type = frame.first else { return }

        // Delivery ACKs are always asynchronous pushes (never a command response).
        if case .ack(let ack) = event {
            pruneRecentAcks()
            recentAcks[ack.code] = Date()
            if let waiters = ackWaiters.removeValue(forKey: ack.code) {
                waiters.forEach { $0.continuation.resume(returning: true) }
            }
            onAck?(ack)
            return
        }

        // While a getContacts command is in flight, accumulate the CONTACT_START /
        // CONTACT stream; CONTACT_END falls through to complete the command below.
        if collectingContacts {
            switch event {
            case .contactStart:
                contactsBuffer.removeAll()
                return
            case .contact(let c):
                contactsBuffer.append(c)
                return
            default:
                break
            }
        }

        // Complete the in-flight command if this frame satisfies it.
        if let cmd = inflight {
            if type == MeshCorePacket.error.rawValue {
                let code: UInt8? = { if case .error(let c) = event { return c } else { return nil } }()
                finishInflight()
                cmd.continuation.resume(throwing: MeshCoreCompanionError.firmwareError(code: code))
                pump()
                return
            }
            if cmd.expect.contains(type) {
                finishInflight()
                cmd.continuation.resume(returning: event)
                pump()
                return
            }
        }

        // Otherwise it is an asynchronous push.
        switch event {
        case .messagesWaiting:
            startDrain()
        case .channelMessage(let m):
            onChannelMessage?(m)
        case .contactMessage(let m):
            onContactMessage?(m)
        default:
            break
        }
    }

    private func handleDisconnect(_ error: Error?) {
        running = false
        failAllPending(error ?? MeshCoreTransportError.notConnected)
        onDisconnect?(error)
    }

    private func failAllPending(_ error: Error) {
        finishInflight()
        let dropped = pendingCommands
        pendingCommands.removeAll()
        for cmd in dropped { cmd.continuation.resume(throwing: error) }
        // Release ack waiters (report not-delivered).
        let waiters = ackWaiters
        ackWaiters.removeAll()
        for (_, list) in waiters { for w in list { w.continuation.resume(returning: false) } }
    }

    // MARK: Auto message fetching (drain on MESSAGES_WAITING)

    private func startDrain() {
        guard running, !draining else { return }
        draining = true
        Task { [weak self] in await self?.drainMessages() }
    }

    private func drainMessages() async {
        defer { queue.async { self.draining = false } }
        while true {
            let stillRunning: Bool = queue.sync { self.running }
            guard stillRunning else { return }
            let event: MeshCoreEvent
            do {
                event = try await sendCommand(
                    MeshCoreFrames.encodeSyncNextMessage(),
                    expect: [MeshCorePacket.channelMsgRecv.rawValue,
                             MeshCorePacket.channelMsgRecvV3.rawValue,
                             MeshCorePacket.contactMsgRecv.rawValue,
                             MeshCorePacket.contactMsgRecvV3.rawValue,
                             MeshCorePacket.noMoreMsgs.rawValue])
            } catch {
                return
            }
            switch event {
            case .noMoreMessages:
                return
            case .channelMessage(let m):
                queue.async { self.onChannelMessage?(m) }
            case .contactMessage(let m):
                queue.async { self.onContactMessage?(m) }
            default:
                return
            }
        }
    }

    // MARK: Helpers

    private func pruneRecentAcks() {
        let cutoff = Date().addingTimeInterval(-60)
        recentAcks = recentAcks.filter { $0.value >= cutoff }
    }

    /// Current Unix time (seconds) for message timestamps. Isolated here so it is
    /// the single source of wall-clock time in the client.
    private static func unixNow() -> UInt32 {
        UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
    }
}
