// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// RNS packet-header inspection used for MeshCore routing decisions.
//
// Reads only the leading header bytes of a Reticulum packet — the same fields the
// Python `MeshCore_Dynamic_Interface` inspects in `_is_broadcast_packet`,
// `_extract_rns_token`, and `_link_id_from_lr_packet`. These operate on the bytes
// the interface actually transmits/receives (the IFAC-wrapped wire bytes in the
// general case; identical to raw packet bytes in the common no-IFAC MeshCore
// tunnel configuration, exactly as in the Python reference).
//
// RNS single-header byte bit layout:
//   bit 7    : header type flag contributes to bits, but header_type = (b0 & 0x40) >> 6
//   bits 5-4 : transport flags
//   bits 3-2 : destination type   → (b0 >> 2) & 0x03
//   bits 1-0 : packet type        →  b0        & 0x03
// ─────────────────────────────────────────────────────────────────────────────

/// Pure inspectors over Reticulum packet header bytes.
enum RNSHeaderInspector {

    /// Reticulum destination-hash / address length (bytes).
    static let destinationLength = 16

    /// RNS packet types (`b0 & 0x03`).
    enum PacketType: UInt8 {
        case data      = 0x00
        case announce  = 0x01
        case linkRequest = 0x02
        case proof     = 0x03
    }

    /// RNS destination types (`(b0 >> 2) & 0x03`).
    enum DestinationType: UInt8 {
        case single = 0x00
        case group  = 0x01
        case plain  = 0x02
        case link   = 0x03
    }

    static func packetType(_ data: Data) -> PacketType? {
        guard let b0 = data.first else { return nil }
        return PacketType(rawValue: b0 & 0x03)
    }

    static func destinationType(_ data: Data) -> DestinationType? {
        guard let b0 = data.first else { return nil }
        return DestinationType(rawValue: (b0 >> 2) & 0x03)
    }

    /// True for packets that can only be flooded on the channel (never unicast):
    /// ANNOUNCE packets and DATA+PLAIN path requests. Empty data is treated as
    /// broadcast (mirrors Python's `len < 1` guard).
    static func isBroadcast(_ data: Data) -> Bool {
        guard let b0 = data.first else { return true }
        let ptype = b0 & 0x03
        let dtype = (b0 >> 2) & 0x03
        if ptype == PacketType.announce.rawValue { return true }
        if ptype == PacketType.data.rawValue && dtype == DestinationType.plain.rawValue { return true }
        return false
    }

    /// Extract the routing token used to key the RNS→MeshCore direct-route map.
    /// For a single-address header (`header_type == 0`) this is the 16-byte
    /// destination hash at `[2..18]`; for a two-address header (`header_type == 1`)
    /// it is the second 16-byte field at `[18..34]`. Returns nil if the packet is
    /// too short. Mirrors `_extract_rns_token`.
    static func extractToken(_ data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        let headerType = (data[base] & 0x40) >> 6
        let dstLen = destinationLength
        if headerType == 1 {
            let end = 2 + 2 * dstLen
            guard data.count >= end else { return nil }
            return Data(data[(base + 2 + dstLen) ..< (base + end)])
        } else {
            let end = 2 + dstLen
            guard data.count >= end else { return nil }
            return Data(data[(base + 2) ..< (base + end)])
        }
    }

    /// Derive the RNS link id from a LINK_REQUEST packet: `SHA-256` of
    /// `[b0 & 0x0F] + <payload after the addressing fields>`, truncated to 16 bytes.
    /// Mirrors `_link_id_from_lr_packet`. Returns nil if too short.
    static func linkID(fromLinkRequest data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        let dstLen = destinationLength
        let headerType = (data[base] & 0x40) >> 6
        var hashable = Data([data[base] & 0x0F])
        if headerType == 1 {
            guard data.count >= 2 + dstLen else { return nil }
            hashable.append(Data(data[(base + 2 + dstLen)...]))
        } else {
            hashable.append(Data(data[(base + 2)...]))
        }
        return Data(SHA256.hash(data: hashable).prefix(dstLen))
    }
}
