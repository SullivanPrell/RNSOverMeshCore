// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Fragmentation / reassembly for the three RNS-over-MeshCore wire formats.
//
// Each RNS packet is split into MeshCore-sized chunks, each carrying a small
// binary header, then encoded to a message string. The three upstream interfaces
// use *different* header layouts, so their fragmenters are kept distinct and
// byte-exact against the Python reference.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Dynamic (MeshCore_Dynamic_Interface)

/// One decoded Dynamic-variant fragment.
public struct DynamicFragment: Equatable {
    public var index: Int
    public var packetID: UInt32
    public var total: Int
    public var payload: Data
}

/// Dynamic wire format: `"RNS:" + base64url( [idx:1][pkt_id:4 BE][total:1] + payload )`.
/// Header packed big-endian (`struct.pack(">BIB", …)`); no base64 padding.
public enum DynamicFragmenter {
    public static let prefix = "RNS:"
    public static let headerSize = 6
    public static let defaultPayloadSize = 64

    /// Build the fragment strings for one packet. `payloadSize <= 0` uses the default.
    public static func fragments(_ data: Data, packetID: UInt32, payloadSize: Int = 0) -> [String] {
        let ps = payloadSize > 0 ? payloadSize : defaultPayloadSize
        let chunks = data.chunked(into: ps)
        let total = chunks.count
        return chunks.enumerated().map { idx, chunk in
            var header = Data([UInt8(truncatingIfNeeded: idx)])
            header.append(bigEndian4(packetID))
            header.append(UInt8(truncatingIfNeeded: total))
            return prefix + Base64URL.encode(header + chunk)
        }
    }

    /// Decode a fragment string that begins at the `"RNS:"` marker. Returns nil for
    /// bad base64, short header, or an out-of-range index (`total == 0` or `idx >= total`).
    public static func decode(_ text: String) -> DynamicFragment? {
        guard text.hasPrefix(prefix) else { return nil }
        let body = String(text.dropFirst(prefix.count))
        guard let raw = Base64URL.decode(body), raw.count >= headerSize else { return nil }
        var r = ByteReader(raw)
        let idx = Int(r.readUInt8())
        let pktID = UInt32(bigEndian: r.read(4))
        let total = Int(r.readUInt8())
        let payload = r.readAll()
        guard total > 0, idx < total else { return nil }
        return DynamicFragment(index: idx, packetID: pktID, total: total, payload: payload)
    }
}

// MARK: - Channel (MeshCore_Channel_Interface)

/// One decoded Channel-variant fragment.
public struct ChannelFragment: Equatable {
    public var index: Int
    public var sourceID: Data     // 4 bytes
    public var packetID: UInt8
    public var total: Int
    public var payload: Data
}

/// Channel wire format:
/// `"RNS:" + base64url( magic 'RN' + [idx:1] + src_id:4 + [pkt_id:1] + [total:1] + payload )`.
/// The 4-byte `src_id` is embedded because MeshCore channel messages do not expose
/// the sender's pubkey (meshcore_py issue #59).
public enum ChannelFragmenter {
    public static let prefix = "RNS:"
    public static let magic = Data([0x52, 0x4E])   // "RN"
    public static let headerSize = 9
    public static let defaultPayloadSize = 64

    public static func fragments(_ data: Data, sourceID: Data, packetID: UInt8,
                                 payloadSize: Int = 0) -> [String] {
        precondition(sourceID.count == 4, "Channel src_id must be 4 bytes")
        let ps = payloadSize > 0 ? payloadSize : defaultPayloadSize
        let chunks = data.chunked(into: ps)
        let total = chunks.count
        return chunks.enumerated().map { idx, chunk in
            var header = magic
            header.append(UInt8(truncatingIfNeeded: idx))
            header.append(sourceID)
            header.append(packetID)
            header.append(UInt8(truncatingIfNeeded: total))
            return prefix + Base64URL.encode(header + chunk)
        }
    }

    /// Decode a fragment string beginning at `"RNS:"`. Returns nil for bad base64,
    /// short header, wrong magic, or an out-of-range index.
    public static func decode(_ text: String) -> ChannelFragment? {
        guard text.hasPrefix(prefix) else { return nil }
        let body = String(text.dropFirst(prefix.count))
        guard let raw = Base64URL.decode(body), raw.count >= headerSize else { return nil }
        var r = ByteReader(raw)
        guard r.read(2) == magic else { return nil }
        let idx = Int(r.readUInt8())
        let srcID = r.read(4)
        let pktID = r.readUInt8()
        let total = Int(r.readUInt8())
        let payload = r.readAll()
        guard total > 0, idx < total else { return nil }
        return ChannelFragment(index: idx, sourceID: srcID, packetID: pktID, total: total, payload: payload)
    }
}

// MARK: - Contact (MeshCore_Interface)

/// One decoded Contact-variant fragment. `position` is 1-based; a negative value
/// marks the final fragment (its magnitude is the sequence number).
public struct ContactFragment: Equatable {
    public var index: Int         // per-packet index (0-255)
    public var position: Int      // signed; < 0 == final fragment
    public var payload: Data
    public var isFinal: Bool { position < 0 }
    public var sequence: Int { abs(position) }
}

/// Contact wire format: `base64( [index:1][pos:1 signed] + chunk )`, sent as a
/// direct MeshCore message body (no `"RNS:"` prefix). Uses the same near-even
/// split as `MeshCore_Interface.PacketHandler.split_data`.
public enum ContactFragmenter {
    public static let defaultMaxPayload = 160

    public static func fragments(_ data: Data, index: UInt8, maxPayload: Int = 0) -> [String] {
        guard !data.isEmpty else { return [] }
        let maxP = maxPayload > 0 ? maxPayload : defaultMaxPayload
        let numPackets = data.count / maxP + 1
        let packetSize = data.count / numPackets + 1
        let chunks = data.chunked(into: packetSize)
        return chunks.enumerated().map { i, chunk in
            var pos = i + 1
            if pos == chunks.count { pos = -pos }     // final fragment → negative
            var frame = Data([index, UInt8(bitPattern: Int8(truncatingIfNeeded: pos))])
            frame.append(chunk)
            return frame.base64EncodedString()
        }
    }

    /// Decode a base64 direct-message body into a Contact fragment. Returns nil on
    /// bad base64 or a body shorter than the 2-byte header.
    public static func decode(_ text: String) -> ContactFragment? {
        guard let raw = Data(base64Encoded: text), raw.count >= 2 else { return nil }
        var r = ByteReader(raw)
        let index = Int(r.readUInt8())
        let pos = Int(Int8(bitPattern: r.readUInt8()))
        let payload = r.readAll()
        return ContactFragment(index: index, position: pos, payload: payload)
    }
}

// MARK: - Shared byte helpers

private func bigEndian4(_ value: UInt32) -> Data {
    Data([UInt8(truncatingIfNeeded: value >> 24),
          UInt8(truncatingIfNeeded: value >> 16),
          UInt8(truncatingIfNeeded: value >> 8),
          UInt8(truncatingIfNeeded: value)])
}

extension UInt32 {
    /// Read a big-endian UInt32 from up to 4 bytes (zero-padded if shorter).
    init(bigEndian data: Data) {
        var v: UInt32 = 0
        for byte in data.prefix(4) { v = (v << 8) | UInt32(byte) }
        self = v
    }
}

extension Data {
    /// Split into consecutive chunks of at most `size` bytes (last may be shorter).
    func chunked(into size: Int) -> [Data] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result = [Data]()
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Data(self[start ..< end]))
            start = end
        }
        return result
    }
}
