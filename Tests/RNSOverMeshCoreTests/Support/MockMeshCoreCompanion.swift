import Foundation
@testable import RNSOverMeshCore

/// In-memory `MeshCoreCompanion` for interface tests: records outbound commands and
/// lets the test inject inbound channel/contact messages, with no radio or codec.
final class MockMeshCoreCompanion: MeshCoreCompanion, @unchecked Sendable {
    var onChannelMessage: ((MeshCoreChannelMessage) -> Void)?
    var onContactMessage: ((MeshCoreContactMessage) -> Void)?
    var onAck: ((MeshCoreAck) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private(set) var selfInfo: MeshCoreSelfInfo?

    private let lock = NSLock()

    // What `start()` reports.
    var startInfo = MeshCoreSelfInfo(advType: 1, txPower: 20, maxTxPower: 22,
                                     publicKey: String(repeating: "ab", count: 32),
                                     advLat: 0, advLon: 0, radioFreq: 915, radioBw: 250,
                                     radioSf: 10, radioCr: 5, name: "SwiftNode")

    // Behaviour knobs.
    var directSendError: Error?
    var ackShouldSucceed = true
    var msgSentTemplate = MeshCoreMsgSent(routeType: 0,
                                          expectedAck: Data([0xde, 0xad, 0xbe, 0xef]),
                                          suggestedTimeoutMs: 3000)

    // Records.
    private var _channelSends: [(index: Int, text: String)] = []
    private var _directSends: [(key: String, text: String)] = []
    private var _setChannelCalls: [(index: Int, name: String, secret: Data)] = []
    private var _setRadioCalls: [(freq: Double, bw: Double, sf: Int, cr: Int)] = []

    var channelSends: [(index: Int, text: String)] { lock.withLock { _channelSends } }
    var directSends: [(key: String, text: String)] { lock.withLock { _directSends } }
    var setChannelCalls: [(index: Int, name: String, secret: Data)] { lock.withLock { _setChannelCalls } }
    var setRadioCalls: [(freq: Double, bw: Double, sf: Int, cr: Int)] { lock.withLock { _setRadioCalls } }

    /// All channel-message texts sent, for convenience.
    var channelTexts: [String] { channelSends.map(\.text) }

    // MARK: MeshCoreCompanion

    func start() async throws -> MeshCoreSelfInfo {
        lock.withLock { selfInfo = startInfo }
        return startInfo
    }
    func stop() {}

    func setRadio(freq: Double, bw: Double, sf: Int, cr: Int) async throws {
        lock.withLock { _setRadioCalls.append((freq, bw, sf, cr)) }
    }
    func setChannel(index: Int, name: String, secret: Data) async throws {
        lock.withLock { _setChannelCalls.append((index, name, secret)) }
    }
    /// Optional forwarding hook fired after recording a channel send — used by the
    /// loopback interop test to bridge two companions over a shared "channel".
    var channelSendHook: ((Int, String) -> Void)?

    func sendChannelMessage(index: Int, text: String) async throws {
        lock.withLock { _channelSends.append((index, text)) }
        channelSendHook?(index, text)
    }
    @discardableResult
    func sendDirectMessage(pubkeyPrefix: String, text: String) async throws -> MeshCoreMsgSent {
        if let directSendError { throw directSendError }
        lock.withLock { _directSends.append((pubkeyPrefix, text)) }
        return msgSentTemplate
    }
    func waitForAck(code: String, timeout: TimeInterval) async -> Bool { ackShouldSucceed }

    /// Contact list returned by `getContacts()`; set by tests exercising advert-name
    /// resolution. `getContactsCalled` records that a lookup happened.
    var contacts: [MeshCoreContact] = []
    private(set) var getContactsCalled = false
    func getContacts() async throws -> [MeshCoreContact] {
        lock.withLock { getContactsCalled = true }
        return contacts
    }

    // MARK: Inbound simulation

    func deliverChannel(text: String, channelIdx: Int = 0) {
        onChannelMessage?(MeshCoreChannelMessage(channelIdx: channelIdx, pathLen: 0, txtType: 0,
                                                 senderTimestamp: 0, text: text, snr: nil))
    }
    func deliverContact(pubkeyPrefix: String, text: String) {
        onContactMessage?(MeshCoreContactMessage(pubkeyPrefix: pubkeyPrefix, pathLen: 255,
                                                 pathHashMode: -1, txtType: 0,
                                                 senderTimestamp: 0, text: text, snr: nil))
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
