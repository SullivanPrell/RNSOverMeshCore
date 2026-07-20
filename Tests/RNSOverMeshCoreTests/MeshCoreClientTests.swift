import XCTest
@testable import RNSOverMeshCore

/// Tests for `MeshCoreClient` — the command/response engine and auto message
/// fetching — driven entirely through a `MockMeshCoreTransport`, no radio.
final class MeshCoreClientTests: XCTestCase {

    private let key = String(repeating: "ab", count: 32)

    /// Start a client whose mock answers APP_START with SELF_INFO.
    private func startedClient(commandTimeout: TimeInterval = 1.0)
        async throws -> (MeshCoreClient, MockMeshCoreTransport) {
        let mock = MockMeshCoreTransport()
        mock.autoResponder = { frame in
            frame.first == MeshCoreCommand.appStart.rawValue
                ? [MeshCoreTestFrames.selfInfo(name: "Node39", publicKey: self.key)]
                : []
        }
        let client = MeshCoreClient(transport: mock, commandTimeout: commandTimeout)
        _ = try await client.start()
        return (client, mock)
    }

    func testStartPerformsAppStartAndReturnsSelfInfo() async throws {
        let (client, mock) = try await startedClient()
        XCTAssertEqual(client.selfInfo?.name, "Node39")
        XCTAssertEqual(client.selfInfo?.publicKey, key)
        XCTAssertEqual(mock.sent(matching: MeshCoreCommand.appStart.rawValue).count, 1)
    }

    func testSendChannelMessageEmitsFrameAndCompletesOnOK() async throws {
        let (client, mock) = try await startedClient()
        mock.autoResponder = { frame in
            frame.first == MeshCoreCommand.sendChannelTxtMsg.rawValue ? [MeshCoreTestFrames.ok()] : []
        }
        try await client.sendChannelMessage(index: 3, text: "RNS:AAAA")
        let sent = mock.sent(matching: MeshCoreCommand.sendChannelTxtMsg.rawValue)
        XCTAssertEqual(sent.count, 1)
        // 0x03 0x00 <idx=3> <ts:4> "RNS:AAAA"
        XCTAssertEqual(Array(sent[0].prefix(3)), [0x03, 0x00, 0x03])
        XCTAssertTrue(sent[0].suffix(8).elementsEqual(Data("RNS:AAAA".utf8)))
    }

    func testSendDirectMessageReturnsMsgSent() async throws {
        let (client, mock) = try await startedClient()
        mock.autoResponder = { frame in
            frame.first == MeshCoreCommand.sendTxtMsg.rawValue
                ? [MeshCoreTestFrames.msgSent(expectedAck: "deadbeef", suggestedTimeoutMs: 4200)] : []
        }
        let sent = try await client.sendDirectMessage(pubkeyPrefix: key, text: "hi")
        XCTAssertEqual(sent.expectedAckHex, "deadbeef")
        XCTAssertEqual(sent.suggestedTimeoutMs, 4200)
    }

    func testErrorResponseThrowsFirmwareError() async throws {
        let (client, mock) = try await startedClient()
        mock.autoResponder = { frame in
            frame.first == MeshCoreCommand.setChannel.rawValue ? [MeshCoreTestFrames.error(code: 5)] : []
        }
        do {
            try await client.setChannel(index: 1, name: "RNSTunnel",
                                        secret: Data(hexString: "c4d2b6c8254e3b11200f57e95dcb1197")!)
            XCTFail("expected firmwareError")
        } catch MeshCoreCompanionError.firmwareError(let code) {
            XCTAssertEqual(code, 5)
        }
    }

    func testCommandTimesOutWhenNoResponse() async throws {
        let (client, mock) = try await startedClient(commandTimeout: 0.2)
        mock.autoResponder = { _ in [] }   // firmware never answers
        do {
            try await client.sendChannelMessage(index: 0, text: "x")
            XCTFail("expected timeout")
        } catch MeshCoreTransportError.timedOut {
            // expected
        }
    }

    func testWaitForAckResolvesWhenAckArrives() async throws {
        let (client, mock) = try await startedClient()
        async let acked = client.waitForAck(code: "deadbeef", timeout: 2.0)
        // Give the waiter a moment to register, then deliver the ACK.
        try await Task.sleep(nanoseconds: 50_000_000)
        mock.deliver(MeshCoreTestFrames.ack(code: "deadbeef"))
        let result = await acked
        XCTAssertTrue(result)
    }

    func testWaitForAckTimesOutToFalse() async throws {
        let (client, _) = try await startedClient()
        let result = await client.waitForAck(code: "00000000", timeout: 0.2)
        XCTAssertFalse(result)
    }

    func testGetContactsAccumulatesMultiFrameResponse() async throws {
        let (client, mock) = try await startedClient()
        let keyA = String(repeating: "11", count: 32)
        let keyB = String(repeating: "22", count: 32)
        mock.autoResponder = { frame in
            guard frame.first == MeshCoreCommand.getContacts.rawValue else { return [] }
            return [MeshCoreTestFrames.contactStart(count: 2),
                    MeshCoreTestFrames.contact(publicKey: keyA, advName: "Alpha"),
                    MeshCoreTestFrames.contact(publicKey: keyB, advName: "Bravo"),
                    MeshCoreTestFrames.contactEnd()]
        }
        let contacts = try await client.getContacts()
        XCTAssertEqual(contacts.map(\.advName), ["Alpha", "Bravo"])
        XCTAssertEqual(contacts.map(\.publicKey), [keyA, keyB])
    }

    func testWaitForAckHandlesAckThatRacedAhead() async throws {
        let (client, mock) = try await startedClient()
        // ACK arrives *before* anyone waits — the recent-ack cache must still
        // satisfy a subsequent waitForAck within the window.
        mock.deliver(MeshCoreTestFrames.ack(code: "cafebabe"))
        try await Task.sleep(nanoseconds: 30_000_000)
        let result = await client.waitForAck(code: "cafebabe", timeout: 1.0)
        XCTAssertTrue(result)
    }

    func testAutoDrainOnMessagesWaitingDeliversQueuedMessages() async throws {
        let (client, mock) = try await startedClient()

        let received = MessageCollector()
        client.onChannelMessage = { msg in Task { await received.add(msg.text) } }

        // Firmware has one channel message queued, then reports empty.
        let syncCount = Counter()
        mock.autoResponder = { frame in
            guard frame.first == MeshCoreCommand.syncNextMessage.rawValue else { return [] }
            let n = syncCount.next()
            return n == 0
                ? [MeshCoreTestFrames.channelMessage(channelIdx: 3, text: "RNS:HELLO")]
                : [MeshCoreTestFrames.noMoreMessages()]
        }

        mock.deliver(MeshCoreTestFrames.messagesWaiting())

        try await eventually { await received.texts == ["RNS:HELLO"] }
        XCTAssertGreaterThanOrEqual(syncCount.value, 2)   // fetched the msg, then drained empty
    }

    // MARK: - Small async test helpers

    /// Poll `condition` until true or ~2s elapse.
    private func eventually(_ condition: @escaping () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met in time", file: file, line: line)
    }
}

/// Actor collectors so test callbacks (invoked on the client queue) stay race-free.
private actor MessageCollector {
    private(set) var texts: [String] = []
    func add(_ t: String) { texts.append(t) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = _value; _value += 1; return v }
}
