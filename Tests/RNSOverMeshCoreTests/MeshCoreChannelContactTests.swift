import XCTest
@testable import RNSOverMeshCore
import ReticulumSwift

/// A mock `MeshCoreChannelBackend` for channel-interface tests.
private final class MockChannelBackend: MeshCoreChannelBackend, @unchecked Sendable {
    var onChannelText: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var startPubkey: String?
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.withLock { _sent } }

    func start() async throws -> String? { startPubkey }
    func stop() {}
    func sendChannelText(_ text: String) async throws { lock.withLock { _sent.append(text) } }
    func deliver(_ text: String) { onChannelText?(text) }
}

final class MeshCoreChannelContactTests: XCTestCase {

    private func makePacket(_ dest: Packet.DestinationType, _ type: Packet.PacketType,
                            destHash: Data, payload: String) -> Packet {
        Packet(destinationType: dest, packetType: type, destinationHash: destHash, data: Data(payload.utf8))
    }

    private func eventually(_ cond: @escaping () -> Bool) async throws {
        for _ in 0 ..< 300 { if cond() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("condition not met in time")
    }

    private func channelConfig(nodeIdentity: String = "testhost") -> MeshCoreChannelConfig {
        var c = MeshCoreChannelConfig()
        c.fragmentDelay = 0; c.rateLimitBps = 0; c.cleanupInterval = 999
        c.nodeIdentity = nodeIdentity
        return c
    }

    // MARK: - Channel interface

    func testChannelSendFragmentsCarryPubkeyDerivedSrcID() async throws {
        let backend = MockChannelBackend()
        backend.startPubkey = "aabbccddeeff00112233445566778899" + String(repeating: "0", count: 32)
        let iface = MeshCoreChannelInterface(backend: backend, config: channelConfig())
        try await iface.bringUp()

        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xD1, count: 16),
                                  payload: String(repeating: "y", count: 130)).pack()
        let expected = ChannelFragmenter.fragments(wire, sourceID: Data([0, 0, 0, 0]),
                                                   packetID: 0, payloadSize: 64).count
        try iface.send(makePacket(.single, .data, destHash: Data(repeating: 0xD1, count: 16),
                                  payload: String(repeating: "y", count: 130)))
        try await eventually { backend.sent.count == expected }

        var reassembled = Data()
        for text in backend.sent {
            let frag = ChannelFragmenter.decode(text)!
            XCTAssertEqual(frag.sourceID, Data([0xaa, 0xbb, 0xcc, 0xdd]))   // pubkey[:4]
            reassembled.append(frag.payload)
        }
        XCTAssertEqual(reassembled, wire)
        iface.stop()
    }

    func testChannelReceiveReassembles() async throws {
        let backend = MockChannelBackend()
        backend.startPubkey = "aabbccddeeff00112233445566778899" + String(repeating: "0", count: 32)
        let iface = MeshCoreChannelInterface(backend: backend, config: channelConfig())
        let delivered = Collector()
        iface.rawInboundHandler = { data, _ in delivered.append(data) }
        try await iface.bringUp()

        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xD3, count: 16),
                                  payload: String(repeating: "z", count: 140)).pack()
        for frag in ChannelFragmenter.fragments(wire, sourceID: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                                                packetID: 5, payloadSize: 64) {
            backend.deliver("PeerX: \(frag)")
        }
        try await eventually { delivered.values.count == 1 }
        XCTAssertEqual(delivered.values.first, wire)
        iface.stop()
    }

    func testChannelDropsOwnEcho() async throws {
        let backend = MockChannelBackend()
        backend.startPubkey = "aabbccddeeff00112233445566778899" + String(repeating: "0", count: 32)
        let iface = MeshCoreChannelInterface(backend: backend, config: channelConfig())
        let delivered = Collector()
        iface.rawInboundHandler = { data, _ in delivered.append(data) }
        try await iface.bringUp()

        // A fragment stamped with OUR src_id (aabbccdd) must be dropped.
        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xD4, count: 16),
                                  payload: "echo").pack()
        for frag in ChannelFragmenter.fragments(wire, sourceID: Data([0xaa, 0xbb, 0xcc, 0xdd]),
                                                packetID: 9) {
            backend.deliver("RNS-self: \(frag)")
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(delivered.values.count, 0)
        iface.stop()
    }

    func testChannelSrcIDFallsBackToSecretHash() async throws {
        let backend = MockChannelBackend()
        backend.startPubkey = nil                        // no pubkey → derive from secret
        let config = channelConfig(nodeIdentity: "host-abc")
        let iface = MeshCoreChannelInterface(backend: backend, config: config)
        try await iface.bringUp()

        try iface.send(makePacket(.single, .data, destHash: Data(repeating: 0xD5, count: 16),
                                  payload: "hello"))
        try await eventually { !backend.sent.isEmpty }
        let expected = MeshCoreChannelInterface.deriveSrcID(pubkey: nil, config: config)
        XCTAssertEqual(ChannelFragmenter.decode(backend.sent.first!)?.sourceID, expected)
        iface.stop()
    }

    // MARK: - Contact interface

    private func contactConfig(endpoint: String) -> MeshCoreContactConfig {
        var c = MeshCoreContactConfig()
        c.endpointContact = endpoint
        c.fragmentDelay = 0
        return c
    }

    func testContactSendsFragmentsToEndpointAndSetsRadio() async throws {
        let mock = MockMeshCoreCompanion()
        let endpoint = "112233445566778899aa"
        let iface = MeshCoreContactInterface(companion: mock, config: contactConfig(endpoint: endpoint))
        try await iface.bringUp()
        XCTAssertEqual(mock.setRadioCalls.count, 1)             // Python contact variant sets radio
        XCTAssertEqual(iface.hwMtu, 184)

        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xC1, count: 16),
                                  payload: String(repeating: "q", count: 300)).pack()
        let expected = ContactFragmenter.fragments(wire, index: 0, maxPayload: 160).count
        try iface.send(makePacket(.single, .data, destHash: Data(repeating: 0xC1, count: 16),
                                  payload: String(repeating: "q", count: 300)))
        try await eventually { mock.directSends.count == expected }
        XCTAssertTrue(mock.directSends.allSatisfy { $0.key == endpoint })

        var reassembled = Data()
        for send in mock.directSends {
            reassembled.append(ContactFragmenter.decode(send.text)!.payload)
        }
        XCTAssertEqual(reassembled, wire)
        iface.stop()
    }

    func testContactDropsOutboundWithoutEndpoint() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreContactInterface(companion: mock, config: contactConfig(endpoint: ""))
        try await iface.bringUp()
        try iface.send(makePacket(.single, .data, destHash: Data(repeating: 0xC2, count: 16), payload: "x"))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(mock.directSends.isEmpty)
        iface.stop()
    }

    func testContactResolvesEndpointByAdvertName() async throws {
        let mock = MockMeshCoreCompanion()
        let baseKey = String(repeating: "1a", count: 32)
        mock.contacts = [
            MeshCoreContact(publicKey: String(repeating: "99", count: 32), type: 0, flags: 0, outPathLen: 0, advName: "Handheld"),
            MeshCoreContact(publicKey: baseKey, type: 0, flags: 0, outPathLen: 2, advName: "BaseStation"),
        ]
        // Configured as an advert-name substring, not a pubkey → must resolve via getContacts.
        let iface = MeshCoreContactInterface(companion: mock, config: contactConfig(endpoint: "base"))
        try await iface.bringUp()
        XCTAssertTrue(mock.getContactsCalled)

        try iface.send(makePacket(.single, .data, destHash: Data(repeating: 0xC4, count: 16), payload: "hi"))
        try await eventually { !mock.directSends.isEmpty }
        XCTAssertTrue(mock.directSends.allSatisfy { $0.key == baseKey })   // routed to resolved pubkey
        iface.stop()
    }

    func testContactPubkeyEndpointSkipsResolution() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreContactInterface(companion: mock,
                                             config: contactConfig(endpoint: "112233445566778899aa"))
        try await iface.bringUp()
        XCTAssertFalse(mock.getContactsCalled)   // hex pubkey → no advert lookup
        iface.stop()
    }

    func testContactReceiveReassembles() async throws {
        let mock = MockMeshCoreCompanion()
        let iface = MeshCoreContactInterface(companion: mock, config: contactConfig(endpoint: "112233445566"))
        let delivered = Collector()
        iface.rawInboundHandler = { data, _ in delivered.append(data) }
        try await iface.bringUp()

        let wire = try makePacket(.single, .data, destHash: Data(repeating: 0xC3, count: 16),
                                  payload: String(repeating: "w", count: 250)).pack()
        for frag in ContactFragmenter.fragments(wire, index: 5, maxPayload: 100) {
            mock.deliverContact(pubkeyPrefix: "aabbccddeeff", text: frag)
        }
        try await eventually { delivered.values.count == 1 }
        XCTAssertEqual(delivered.values.first, wire)
        iface.stop()
    }
}

/// Thread-safe delivered-packet collector.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Data] = []
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ d: Data) { lock.lock(); _values.append(d); lock.unlock() }
}
