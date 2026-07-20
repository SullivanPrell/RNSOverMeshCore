import XCTest
@testable import RNSOverMeshCore
import ReticulumSwift

/// End-to-end tests for `MeshCoreDynamicInterface` against a mock companion:
/// bring-up, hybrid routing, reassembly, dedup, RNSBIND discovery, and the
/// direct→channel ACK fallback.
final class MeshCoreDynamicInterfaceTests: XCTestCase {

    private let secretHex = "c4d2b6c8254e3b11200f57e95dcb1197"
    private let peerKey = "1122334455667788"
    private let ownKey = String(repeating: "ab", count: 32)

    /// Config with pacing/backoff shrunk and proactive loops parked far in the
    /// future, so only behaviours the test triggers occur.
    private func testConfig() -> MeshCoreDynamicConfig {
        var c = MeshCoreDynamicConfig()
        c.channelSecretHex = secretHex
        c.fragmentDelay = 0; c.directFragDelay = 0; c.rateLimitBps = 0
        c.announceRetransmitExtra = 0; c.pathReqRetransmitExtra = 0
        c.announceRate = 0; c.pathReqRate = 0
        c.bindBackoffMin = 0.01; c.bindBackoffMax = 0.02
        c.discoverySettleDelay = 999; c.bindHeartbeat = 999; c.cleanupInterval = 999
        return c
    }

    private func makePacket(_ dest: Packet.DestinationType, _ type: Packet.PacketType,
                            destHash: Data, payload: String) -> Packet {
        Packet(destinationType: dest, packetType: type, destinationHash: destHash,
               data: Data(payload.utf8))
    }

    private func eventually(_ cond: @escaping () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met in time")
    }

    // MARK: - Bring-up

    func testBringUpConfiguresChannelRadioAndGoesOnline() async throws {
        var cfg = testConfig()
        cfg.radioFreq = 915; cfg.radioBw = 250; cfg.radioSf = 10; cfg.radioCr = 5
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreDynamicInterface(companion: mock, config: cfg)
        try await iface.bringUp()

        XCTAssertTrue(iface.isOnline)
        XCTAssertEqual(iface.displayName, "MeshCoreDynamicInterface[MeshCore Dynamic]")
        XCTAssertEqual(iface.hwMtu, Constants.mtu)
        XCTAssertEqual(mock.setRadioCalls.count, 1)
        XCTAssertEqual(mock.setChannelCalls.count, 1)
        XCTAssertEqual(mock.setChannelCalls.first?.secret, Data(hexString: secretHex))
        iface.stop()
    }

    // MARK: - Outbound routing

    func testAnnounceRoutesToChannel() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreDynamicInterface(companion: mock, config: testConfig())
        try await iface.bringUp()

        try iface.send(makePacket(.single, .announce, destHash: Data(repeating: 0xA1, count: 16),
                                  payload: "announce-body"))
        try await eventually { !mock.channelTexts.isEmpty }
        XCTAssertTrue(mock.channelTexts.allSatisfy { $0.hasPrefix("RNS:") })
        XCTAssertTrue(mock.directSends.isEmpty)   // broadcast never goes direct
        iface.stop()
    }

    // MARK: - Inbound reassembly

    func testReceiveReassemblesAndDeliversUpward() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreDynamicInterface(companion: mock, config: testConfig())

        let delivered = Box()
        iface.rawInboundHandler = { data, _ in delivered.append(data) }
        try await iface.bringUp()

        // A 150-byte wire packet → 3 fragments delivered with a sender-name prefix.
        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xD1, count: 16),
                                  payload: String(repeating: "x", count: 150)).pack()
        for frag in DynamicFragmenter.fragments(wire, packetID: 1, payloadSize: 64) {
            mock.deliverChannel(text: "Peer1: \(frag)")
        }
        try await eventually { delivered.values.count == 1 }
        XCTAssertEqual(delivered.values.first, wire)
        iface.stop()
    }

    func testDuplicatePacketDeliveredOnce() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreDynamicInterface(companion: mock, config: testConfig())
        let delivered = Box()
        iface.rawInboundHandler = { data, _ in delivered.append(data) }
        try await iface.bringUp()

        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xD2, count: 16),
                                  payload: "dupe").pack()
        let frags = DynamicFragmenter.fragments(wire, packetID: 7)
        frags.forEach { mock.deliverChannel(text: "Peer1: \($0)") }
        frags.forEach { mock.deliverChannel(text: "Peer1: \($0)") }   // replay
        try await eventually { delivered.values.count == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(delivered.values.count, 1)
        iface.stop()
    }

    // MARK: - Peer discovery

    func testRNSBINDRequestTriggersResponse() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreDynamicInterface(companion: mock, config: testConfig())
        try await iface.bringUp()

        mock.deliverChannel(text: "GW: RNSBIND_REQ:\(peerKey):R")
        try await eventually {
            mock.channelTexts.contains { $0.hasPrefix("RNSBIND:\(self.ownKey):R") }
        }
        iface.stop()
    }

    // MARK: - Direct routing + fallback

    /// Bind a peer and feed it an inbound packet so its destination token is learned
    /// and mapped to the peer's MeshCore key.
    private func learnPeerRoute(_ mock: MockMeshCoreCompanion, destHash: Data) {
        mock.deliverChannel(text: "Peer1: RNSBIND:\(peerKey):R")
        let inbound = try! makePacket(.single, .data, destHash: destHash, payload: "learn").pack()
        for frag in DynamicFragmenter.fragments(inbound, packetID: 99) {
            mock.deliverChannel(text: "Peer1: \(frag)")
        }
    }

    func testDirectRoutingAfterLearningPeerToken() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreDynamicInterface(companion: mock, config: testConfig())
        iface.rawInboundHandler = { _, _ in }
        try await iface.bringUp()

        let dest = Data(repeating: 0xE7, count: 16)
        learnPeerRoute(mock, destHash: dest)

        try iface.send(makePacket(.single, .data, destHash: dest, payload: "route-me"))
        try await eventually { !mock.directSends.isEmpty }
        XCTAssertEqual(mock.directSends.first?.key, peerKey)
        XCTAssertTrue(mock.directSends.allSatisfy { $0.text.hasPrefix("RNS:") })
        iface.stop()
    }

    func testDirectFallsBackToChannelWhenNoAck() async throws {
        let mock = MockMeshCoreCompanion()
        mock.ackShouldSucceed = false            // firmware never confirms delivery
        let iface = MeshCoreDynamicInterface(companion: mock, config: testConfig())
        iface.rawInboundHandler = { _, _ in }
        try await iface.bringUp()

        let dest = Data(repeating: 0xE8, count: 16)
        learnPeerRoute(mock, destHash: dest)

        try iface.send(makePacket(.single, .data, destHash: dest, payload: "fallback"))
        // Direct is attempted, then the same fragment is re-queued on the channel.
        try await eventually { !mock.directSends.isEmpty && !mock.channelTexts.isEmpty }
        XCTAssertEqual(mock.directSends.first?.text, mock.channelTexts.first)
        iface.stop()
    }
}

/// Thread-safe collector for delivered inbound packets.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Data] = []
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ d: Data) { lock.lock(); _values.append(d); lock.unlock() }
}
