import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MeshCore companion protocol frame codec (Layer A).
//
// Pure encode/decode of the companion frames documented in
// `reference_implementations/MeshCore/docs/companion_protocol.md` and implemented
// by `meshcore_py` (`commands/*.py`, `reader.py`). These are the *unwrapped*
// companion frames — the `[packet_type][payload…]` bodies. The transport-level
// serial/TCP framing (`0x3c`/`0x3e` + 2-byte LE length) lives in Layer C
// (`MeshCoreSerialFraming`); over BLE each notification is already one frame.
//
// All multi-byte integers are little-endian (companion protocol default).
// Opcodes/layouts mirror `meshcore_py` exactly for ecosystem compatibility.
// ─────────────────────────────────────────────────────────────────────────────

/// Command opcodes sent app → firmware. Values from `meshcore_py`
/// `packets.CommandType`. Only the subset the three RNS interfaces use is listed.
public enum MeshCoreCommand: UInt8 {
    case appStart            = 1    // 0x01 → SELF_INFO
    case sendTxtMsg          = 2    // 0x02 → MSG_SENT   (direct/contact message)
    case sendChannelTxtMsg   = 3    // 0x03 → OK         (channel message)
    case getContacts         = 4    // 0x04 → CONTACT_START, CONTACT…, CONTACT_END
    case syncNextMessage     = 10   // 0x0A → *_MSG_RECV / NO_MORE_MSGS
    case setRadioParams      = 11   // 0x0B → OK
    case getBattAndStorage   = 20   // 0x14 → BATTERY
    case deviceQuery         = 22   // 0x16 → DEVICE_INFO
    case getChannel          = 31   // 0x1F → CHANNEL_INFO
    case setChannel          = 32   // 0x20 → OK
}

/// Response / push packet type codes received firmware → app. Values from
/// `meshcore_py` `packets.PacketType`.
public enum MeshCorePacket: UInt8 {
    case ok               = 0x00
    case error            = 0x01
    case contactStart     = 0x02
    case contact          = 0x03
    case contactEnd       = 0x04
    case selfInfo         = 0x05
    case msgSent          = 0x06
    case contactMsgRecv   = 0x07
    case channelMsgRecv   = 0x08
    case currentTime      = 0x09
    case noMoreMsgs       = 0x0A
    case battery          = 0x0C
    case deviceInfo       = 0x0D
    case contactMsgRecvV3 = 0x10
    case channelMsgRecvV3 = 0x11
    case channelInfo      = 0x12
    case advertisement    = 0x80
    case pathUpdate       = 0x81
    case ack              = 0x82
    case messagesWaiting  = 0x83
    case logData          = 0x88
}

// MARK: - Parsed value types

/// Firmware self-identity from `PACKET_SELF_INFO` (0x05). Fields per
/// `reader.py` SELF_INFO parse. `publicKey` is the full 32-byte key as lowercase hex.
public struct MeshCoreSelfInfo: Equatable, Sendable {
    public var advType: UInt8
    public var txPower: UInt8
    public var maxTxPower: UInt8
    public var publicKey: String     // 64 hex chars (32 bytes)
    public var advLat: Double
    public var advLon: Double
    public var radioFreq: Double     // MHz
    public var radioBw: Double       // kHz
    public var radioSf: UInt8
    public var radioCr: UInt8
    public var name: String
}

/// Local-radio send confirmation from `PACKET_MSG_SENT` (0x06). `expectedAck` is
/// the 4-byte tag echoed back later in a `PACKET_ACK` `code` field once (if ever)
/// the frame is delivered over-air. `suggestedTimeoutMs` is the firmware's own
/// airtime-based delivery-wait hint. Per `reader.py` MSG_SENT parse.
public struct MeshCoreMsgSent: Equatable, Sendable {
    /// Route flag: 0 = direct path known, 1 = flood.
    public var routeType: UInt8
    public var expectedAck: Data          // 4 bytes
    public var suggestedTimeoutMs: UInt32
    /// Lowercase hex of `expectedAck`, matched against `MeshCoreAck.code`.
    public var expectedAckHex: String { expectedAck.hexEncoded }
}

/// Delivery acknowledgement from `PACKET_ACK` (0x82). `code` is 4 bytes as
/// lowercase hex — compared against `MeshCoreMsgSent.expectedAckHex`.
public struct MeshCoreAck: Equatable, Sendable {
    public var code: String
    public var tripTimeMs: UInt32?
}

/// A received direct/contact text message (`PACKET_CONTACT_MSG_RECV` 0x07 or the
/// V3 SNR variant 0x10). `pubkeyPrefix` is the 6-byte sender key prefix as hex.
public struct MeshCoreContactMessage: Equatable, Sendable {
    public var pubkeyPrefix: String   // 12 hex chars (6 bytes)
    public var pathLen: Int
    public var pathHashMode: Int
    public var txtType: UInt8
    public var senderTimestamp: UInt32
    public var text: String
    public var snr: Float?
}

/// A received channel text message (`PACKET_CHANNEL_MSG_RECV` 0x08 or the V3 SNR
/// variant 0x11). Note: firmware prepends the sender's node name to `text`
/// (e.g. `"Node39: RNS:…"`) — the tunnel layer strips it by locating the marker.
public struct MeshCoreChannelMessage: Equatable, Sendable {
    public var channelIdx: Int
    public var pathLen: Int
    public var txtType: UInt8
    public var senderTimestamp: UInt32
    public var text: String
    public var snr: Float?
}

/// One entry from the device contact list (`PACKET_CONTACT` 0x03), per `reader.py`.
/// `publicKey` is the full 32-byte key as hex; `advName` is the advertised name.
/// `outPathLen` is -1 for a flood-only contact (no known route).
public struct MeshCoreContact: Equatable, Sendable {
    public var publicKey: String
    public var type: UInt8
    public var flags: UInt8
    public var outPathLen: Int
    public var advName: String
}

/// The full decoded set of companion frames this codec understands. Frames the
/// codec does not model are surfaced as `.unknown` (never dropped silently) so the
/// client layer can log them.
public enum MeshCoreEvent: Equatable, Sendable {
    case ok(value: UInt32?)
    case error(code: UInt8?)
    case selfInfo(MeshCoreSelfInfo)
    case msgSent(MeshCoreMsgSent)
    case contactMessage(MeshCoreContactMessage)
    case channelMessage(MeshCoreChannelMessage)
    case ack(MeshCoreAck)
    case messagesWaiting
    case noMoreMessages
    case currentTime(UInt32)
    case contactStart(count: Int)
    case contact(MeshCoreContact)
    case contactEnd(lastmod: UInt32)
    case unknown(type: UInt8, payload: Data)
}

// MARK: - Codec

/// Stateless encoder/decoder for companion frames. All methods are pure.
public enum MeshCoreFrames {

    // ── Command encoders (app → firmware) ────────────────────────────────────

    /// `CMD_APP_START` (0x01). Layout mirrors `meshcore_py` `send_appstart`:
    /// `0x01, 0x03, <6 reserved bytes>, <appName UTF-8>`. Byte 1 (0x03) and the
    /// 6 reserved bytes are ignored by firmware; we replicate meshcore_py's exact
    /// bytes (0x03 + six spaces) for maximum ecosystem compatibility.
    public static func encodeAppStart(appName: String) -> Data {
        var d = Data([MeshCoreCommand.appStart.rawValue, 0x03])
        d.append(Data(repeating: 0x20, count: 6))   // reserved (spaces, as meshcore_py)
        d.append(Data(appName.utf8))
        return d
    }

    /// `CMD_DEVICE_QUERY` (0x16 0x03). → DEVICE_INFO.
    public static func encodeDeviceQuery() -> Data {
        Data([MeshCoreCommand.deviceQuery.rawValue, 0x03])
    }

    /// `CMD_SET_RADIO_PARAMS` (0x0B): freq·1000 (4 LE) + bw·1000 (4 LE) + sf(1) + cr(1).
    /// freq in MHz, bw in kHz — both scaled ×1000 to integer Hz/Hz-equivalent.
    public static func encodeSetRadio(freq: Double, bw: Double, sf: Int, cr: Int) -> Data {
        var d = Data([MeshCoreCommand.setRadioParams.rawValue])
        d.appendUInt32LE(UInt32(truncatingIfNeeded: Int((freq * 1000).rounded())))
        d.appendUInt32LE(UInt32(truncatingIfNeeded: Int((bw * 1000).rounded())))
        d.append(UInt8(truncatingIfNeeded: sf))
        d.append(UInt8(truncatingIfNeeded: cr))
        return d
    }

    /// `CMD_SET_CHANNEL` (0x20): idx(1) + name(32, UTF-8, null-padded/truncated) + secret(16).
    /// Total 50 bytes. `secret` must be exactly 16 bytes.
    public static func encodeSetChannel(index: Int, name: String, secret: Data) -> Data {
        precondition(secret.count == 16, "MeshCore channel secret must be exactly 16 bytes")
        var d = Data([MeshCoreCommand.setChannel.rawValue, UInt8(truncatingIfNeeded: index)])
        var nameBytes = Data(name.utf8.prefix(32))
        if nameBytes.count < 32 { nameBytes.append(Data(repeating: 0x00, count: 32 - nameBytes.count)) }
        d.append(nameBytes)
        d.append(secret)
        return d
    }

    /// `CMD_GET_CHANNEL` (0x1F): idx(1). → CHANNEL_INFO.
    public static func encodeGetChannel(index: Int) -> Data {
        Data([MeshCoreCommand.getChannel.rawValue, UInt8(truncatingIfNeeded: index)])
    }

    /// `CMD_SEND_CHANNEL_TXT_MSG` (0x03): 0x00 subtype + idx(1) + timestamp(4 LE) + text UTF-8.
    public static func encodeSendChannelMessage(index: Int, text: String, timestamp: UInt32) -> Data {
        var d = Data([MeshCoreCommand.sendChannelTxtMsg.rawValue, 0x00, UInt8(truncatingIfNeeded: index)])
        d.appendUInt32LE(timestamp)
        d.append(Data(text.utf8))
        return d
    }

    /// `CMD_SEND_TXT_MSG` (0x02) direct/contact: 0x00 subtype + attempt(1) + timestamp(4 LE)
    /// + destination pubkey prefix (6 bytes) + text UTF-8. `pubkeyPrefix` may be a full
    /// hex key or a ≥6-byte prefix; the first 6 bytes are used.
    public static func encodeSendDirectMessage(pubkeyPrefix: String, text: String,
                                               timestamp: UInt32, attempt: UInt8 = 0) -> Data? {
        guard let key = Data(hexString: pubkeyPrefix), key.count >= 6 else { return nil }
        var d = Data([MeshCoreCommand.sendTxtMsg.rawValue, 0x00, attempt])
        d.appendUInt32LE(timestamp)
        d.append(key.prefix(6))
        d.append(Data(text.utf8))
        return d
    }

    /// `CMD_SYNC_NEXT_MESSAGE` (0x0A): pull the next queued message from firmware.
    public static func encodeSyncNextMessage() -> Data {
        Data([MeshCoreCommand.syncNextMessage.rawValue])
    }

    /// `CMD_GET_BATT_AND_STORAGE` (0x14).
    public static func encodeGetBattery() -> Data {
        Data([MeshCoreCommand.getBattAndStorage.rawValue])
    }

    /// `CMD_GET_CONTACTS` (0x04): request the contact list. Optional `since` (unix
    /// seconds) fetches only contacts modified after it (appended as 4 LE bytes).
    /// Response is a `CONTACT_START` / `CONTACT`… / `CONTACT_END` sequence.
    public static func encodeGetContacts(since: UInt32 = 0) -> Data {
        var d = Data([MeshCoreCommand.getContacts.rawValue])
        if since > 0 { d.appendUInt32LE(since) }
        return d
    }

    // ── Response/push parser (firmware → app) ────────────────────────────────

    /// Parse one unwrapped companion frame. Returns `.unknown` for frame types not
    /// modelled here (rather than nil) so nothing is silently dropped; returns nil
    /// only for an empty frame.
    public static func parse(_ frame: Data) -> MeshCoreEvent? {
        guard let type = frame.first else { return nil }
        var r = ByteReader(frame)
        _ = r.readUInt8()   // consume the packet-type byte

        switch MeshCorePacket(rawValue: type) {
        case .ok:
            // Optional 4-byte LE value when the frame is exactly 5 bytes.
            let value: UInt32? = frame.count == 5 ? r.readUInt32LE() : nil
            return .ok(value: value)

        case .error:
            let code: UInt8? = frame.count > 1 ? r.readUInt8() : nil
            return .error(code: code)

        case .selfInfo:
            return .selfInfo(parseSelfInfo(&r))

        case .msgSent:
            let routeType = r.readUInt8()
            let expectedAck = r.read(4)
            let suggested = r.readUInt32LE()
            return .msgSent(MeshCoreMsgSent(routeType: routeType,
                                            expectedAck: expectedAck,
                                            suggestedTimeoutMs: suggested))

        case .ack:
            // code(4) then optional trip_time(4 LE) since companion-v1.0.0a.
            let code = frame.count >= 5 ? r.read(4).hexEncoded : ""
            let trip: UInt32? = r.remaining >= 4 ? r.readUInt32LE() : nil
            return .ack(MeshCoreAck(code: code, tripTimeMs: trip))

        case .messagesWaiting:
            return .messagesWaiting

        case .noMoreMsgs:
            return .noMoreMessages

        case .currentTime:
            return .currentTime(r.readUInt32LE())

        case .contactMsgRecv:
            return .contactMessage(parseContactMessage(&r, hasSNR: false))

        case .contactMsgRecvV3:
            return .contactMessage(parseContactMessage(&r, hasSNR: true))

        case .channelMsgRecv:
            return .channelMessage(parseChannelMessage(&r, hasSNR: false, stripNulls: true))

        case .channelMsgRecvV3:
            return .channelMessage(parseChannelMessage(&r, hasSNR: true, stripNulls: false))

        case .contactStart:
            return .contactStart(count: Int(r.readUInt32LE()))

        case .contact:
            return .contact(parseContact(&r))

        case .contactEnd:
            return .contactEnd(lastmod: r.readUInt32LE())

        default:
            return .unknown(type: type, payload: r.readAll())
        }
    }

    // ── Field parsers (mirror reader.py exactly) ─────────────────────────────

    private static func parseSelfInfo(_ r: inout ByteReader) -> MeshCoreSelfInfo {
        let advType = r.readUInt8()
        let txPower = r.readUInt8()
        let maxTxPower = r.readUInt8()
        let publicKey = r.read(32).hexEncoded
        let lat = Double(r.readIntLE(4)) / 1e6
        let lon = Double(r.readIntLE(4)) / 1e6
        _ = r.readUInt8()          // multi_acks
        _ = r.readUInt8()          // adv_loc_policy
        _ = r.readUInt8()          // telemetry_mode bitfield
        _ = r.readUInt8()          // manual_add_contacts
        let freq = Double(r.readUInt32LE()) / 1000.0
        let bw = Double(r.readUInt32LE()) / 1000.0
        let sf = r.readUInt8()
        let cr = r.readUInt8()
        let name = String(decoding: r.readAll(), as: UTF8.self)
        return MeshCoreSelfInfo(advType: advType, txPower: txPower, maxTxPower: maxTxPower,
                                publicKey: publicKey, advLat: lat, advLon: lon,
                                radioFreq: freq, radioBw: bw, radioSf: sf, radioCr: cr,
                                name: name)
    }

    private static func parseContactMessage(_ r: inout ByteReader, hasSNR: Bool) -> MeshCoreContactMessage {
        var snr: Float?
        if hasSNR {
            snr = Float(r.readIntLE(1)) / 4.0
            _ = r.read(2)          // reserved
        }
        let prefix = r.read(6).hexEncoded
        let (pathLen, pathHashMode) = decodePathLen(r.readUInt8())
        let txtType = r.readUInt8()
        let ts = r.readUInt32LE()
        if txtType == 2 { _ = r.read(4) }   // signature (unused here)
        let text = String(decoding: r.readAll(), as: UTF8.self)
        return MeshCoreContactMessage(pubkeyPrefix: prefix, pathLen: pathLen,
                                      pathHashMode: pathHashMode, txtType: txtType,
                                      senderTimestamp: ts, text: text, snr: snr)
    }

    private static func parseChannelMessage(_ r: inout ByteReader, hasSNR: Bool,
                                            stripNulls: Bool) -> MeshCoreChannelMessage {
        var snr: Float?
        if hasSNR {
            snr = Float(r.readIntLE(1)) / 4.0
            _ = r.read(2)          // reserved
        }
        let channelIdx = Int(r.readUInt8())
        let (pathLen, _) = decodePathLen(r.readUInt8())
        let txtType = r.readUInt8()
        let ts = r.readUInt32LE()
        var textBytes = r.readAll()
        if stripNulls {
            // reader.py strips both ends: `dbuf.read().strip(b"\0")`.
            while textBytes.first == 0x00 { textBytes.removeFirst() }
            while textBytes.last == 0x00 { textBytes.removeLast() }
        }
        let text = String(decoding: textBytes, as: UTF8.self)
        return MeshCoreChannelMessage(channelIdx: channelIdx, pathLen: pathLen,
                                      txtType: txtType, senderTimestamp: ts,
                                      text: text, snr: snr)
    }

    /// Decode the combined path-length byte (`plen`): 255 means a direct message
    /// (path_hash_mode = -1); otherwise the top 2 bits are the hash mode and the
    /// low 6 bits the path length. Mirrors `reader.py`.
    private static func decodePathLen(_ plen: UInt8) -> (pathLen: Int, pathHashMode: Int) {
        if plen == 255 { return (255, -1) }
        return (Int(plen & 0x3F), Int(plen >> 6))
    }

    /// Parse a `PACKET_CONTACT` (0x03) record: pubkey(32) + type(1) + flags(1) +
    /// plen(1) + out_path(64) + adv_name(32, null-stripped). Trailing fields
    /// (last_advert, lat/lon, …) are not needed here and are left unread. Mirrors
    /// `reader.py`; `out_path_len` is -1 for a flood-only contact (`plen == 255`).
    private static func parseContact(_ r: inout ByteReader) -> MeshCoreContact {
        let publicKey = r.read(32).hexEncoded
        let type = r.readUInt8()
        let flags = r.readUInt8()
        let plen = r.readUInt8()
        let outPathLen = plen == 255 ? -1 : Int(plen & 0x3F)
        _ = r.read(64)             // out_path (unused here)
        var nameBytes = r.read(32)
        if let nul = nameBytes.firstIndex(of: 0x00) { nameBytes = nameBytes[nameBytes.startIndex ..< nul] }
        let advName = String(decoding: nameBytes, as: UTF8.self)
        return MeshCoreContact(publicKey: publicKey, type: type, flags: flags,
                               outPathLen: outPathLen, advName: advName)
    }
}
