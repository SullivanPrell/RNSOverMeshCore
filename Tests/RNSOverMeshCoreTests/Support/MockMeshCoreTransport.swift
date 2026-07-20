import Foundation
@testable import RNSOverMeshCore

/// In-memory `MeshCoreTransport` for unit tests. Records every frame the client
/// sends and lets the test inject inbound frames — optionally via an
/// `autoResponder` that maps a just-sent frame to the frames the "firmware" would
/// reply with (invoked synchronously inside `send`, exactly as a real radio would
/// notify on its own queue after a write).
final class MockMeshCoreTransport: MeshCoreTransport, @unchecked Sendable {
    var onFrame: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private(set) var isConnected: Bool = false

    private(set) var sentFrames: [Data] = []
    private let lock = NSLock()

    /// Given a frame the client just sent, return frames to deliver back.
    var autoResponder: ((Data) -> [Data])?
    /// If set, `send` throws this instead of recording.
    var sendError: Error?

    func start() async throws { isConnected = true }
    func stop() { isConnected = false }

    func send(_ frame: Data) throws {
        if let sendError { throw sendError }
        lock.lock(); sentFrames.append(frame); lock.unlock()
        if let responses = autoResponder?(frame) {
            for f in responses { deliver(f) }
        }
    }

    /// Simulate an inbound companion frame from the firmware.
    func deliver(_ frame: Data) { onFrame?(frame) }

    /// Simulate a dropped connection.
    func drop(_ error: Error? = nil) { isConnected = false; onDisconnect?(error) }

    func sent(matching opcode: UInt8) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames.filter { $0.first == opcode }
    }
}

/// Builders for the companion response/push frames tests inject. Kept beside the
/// mock so both the client and interface suites share them.
enum MeshCoreTestFrames {

    static func selfInfo(name: String, publicKey: String,
                         freq: Double = 915.0, bw: Double = 250.0,
                         sf: UInt8 = 10, cr: UInt8 = 5) -> Data {
        var f = Data([MeshCorePacket.selfInfo.rawValue])
        f.append(contentsOf: [0x01, 0x14, 0x16])                 // adv_type, tx, max_tx
        f.append(Data(hexString: publicKey)!)                    // 32-byte key
        f.appendIntLE(0, count: 4); f.appendIntLE(0, count: 4)   // lat, lon
        f.append(contentsOf: [0, 0, 0, 0])                       // multi_acks, loc_policy, telemetry, manual_add
        f.appendUInt32LE(UInt32((freq * 1000).rounded()))
        f.appendUInt32LE(UInt32((bw * 1000).rounded()))
        f.append(contentsOf: [sf, cr])
        f.append(Data(name.utf8))
        return f
    }

    static func ok() -> Data { Data([MeshCorePacket.ok.rawValue]) }
    static func error(code: UInt8) -> Data { Data([MeshCorePacket.error.rawValue, code]) }
    static func noMoreMessages() -> Data { Data([MeshCorePacket.noMoreMsgs.rawValue]) }
    static func messagesWaiting() -> Data { Data([MeshCorePacket.messagesWaiting.rawValue]) }

    static func contactStart(count: UInt32) -> Data {
        var f = Data([MeshCorePacket.contactStart.rawValue]); f.appendUInt32LE(count); return f
    }
    static func contactEnd(lastmod: UInt32 = 0) -> Data {
        var f = Data([MeshCorePacket.contactEnd.rawValue]); f.appendUInt32LE(lastmod); return f
    }
    /// A `PACKET_CONTACT` (0x03): pubkey(32) + type(1) + flags(1) + plen(1) + out_path(64) + adv_name(32).
    static func contact(publicKey: String, advName: String, outPathLen: UInt8 = 0) -> Data {
        var f = Data([MeshCorePacket.contact.rawValue])
        f.append(Data(hexString: publicKey)!)
        f.append(contentsOf: [0x00, 0x00, outPathLen])          // type, flags, plen
        f.append(Data(repeating: 0, count: 64))                 // out_path
        var name = Data(advName.utf8.prefix(32))
        name.append(Data(repeating: 0, count: 32 - name.count))
        f.append(name)
        return f
    }

    static func msgSent(expectedAck: String, suggestedTimeoutMs: UInt32 = 4000, route: UInt8 = 0) -> Data {
        var f = Data([MeshCorePacket.msgSent.rawValue, route])
        f.append(Data(hexString: expectedAck)!)
        f.appendUInt32LE(suggestedTimeoutMs)
        return f
    }

    static func ack(code: String) -> Data {
        var f = Data([MeshCorePacket.ack.rawValue])
        f.append(Data(hexString: code)!)
        return f
    }

    /// A `PACKET_CHANNEL_MSG_RECV` (0x08): idx + plen + txt_type + ts + text.
    static func channelMessage(channelIdx: UInt8, text: String,
                               timestamp: UInt32 = 1_700_000_000) -> Data {
        var f = Data([MeshCorePacket.channelMsgRecv.rawValue, channelIdx, 0x00, 0x00])
        f.appendUInt32LE(timestamp)
        f.append(Data(text.utf8))
        return f
    }

    /// A `PACKET_CONTACT_MSG_RECV` (0x07): pubkey6 + plen + txt_type + ts + text.
    static func contactMessage(pubkeyPrefix: String, text: String,
                               timestamp: UInt32 = 1_700_000_000) -> Data {
        var f = Data([MeshCorePacket.contactMsgRecv.rawValue])
        f.append(Data(hexString: pubkeyPrefix)!.prefix(6))
        f.append(contentsOf: [0xff, 0x00])                       // plen=255 (direct), txt_type=0
        f.appendUInt32LE(timestamp)
        f.append(Data(text.utf8))
        return f
    }
}
