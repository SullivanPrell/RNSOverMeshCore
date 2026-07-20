// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation

/// Reassembles fragmented RNS packets keyed by `(sender, packet-id)` and suppresses
/// duplicate delivery within a sliding time window — the shared logic behind the
/// Dynamic and Channel interfaces' `_process_tunnel_text` reassembly + `_seen_pkts`
/// dedup. Time is supplied by the caller (`now`, a monotonic seconds value) so the
/// reassembler is fully deterministic under test.
///
/// Generic over the key type because the variants key differently: the Dynamic
/// interface by `(senderName, UInt32 pkt_id)`, the Channel interface by
/// `(src_id hex, UInt8 pkt_id)`.
public struct FragmentReassembler<Key: Hashable> {

    /// Seconds a completed `(sender, pkt_id)` stays deduplicated after delivery.
    public let dedupTTL: TimeInterval
    /// Seconds a partial reassembly buffer is kept before eviction.
    public let fragmentTimeout: TimeInterval

    private var assembly: [Key: [Int: Data]] = [:]
    private var meta: [Key: (total: Int, timestamp: TimeInterval)] = [:]
    private var seen: [Key: TimeInterval] = [:]   // key → expiry (now + dedupTTL)

    public init(dedupTTL: TimeInterval = 30, fragmentTimeout: TimeInterval = 300) {
        self.dedupTTL = dedupTTL
        self.fragmentTimeout = fragmentTimeout
    }

    /// Ingest one fragment. Returns the fully-reassembled packet when this fragment
    /// completes it, otherwise nil (incomplete, duplicate fragment, duplicate packet,
    /// or invalid index). Mirrors `_process_tunnel_text`'s ordering: dedup check →
    /// buffer → completion → mark seen.
    public mutating func add(key: Key, index: Int, total: Int, payload: Data,
                             now: TimeInterval) -> Data? {
        guard total > 0, index >= 0, index < total else { return nil }

        // Already delivered within the dedup window?
        if let expiry = seen[key] {
            if now < expiry { return nil }
            seen[key] = nil
        }

        if assembly[key] == nil {
            assembly[key] = [:]
            meta[key] = (total, now)
        }
        // Duplicate fragment for an in-progress packet.
        if assembly[key]?[index] != nil { return nil }
        assembly[key]?[index] = payload

        let expectedTotal = meta[key]?.total ?? total
        guard let parts = assembly[key], parts.count >= expectedTotal else { return nil }

        // Complete: concatenate in index order (bail if a gap somehow remains).
        var full = Data()
        for i in 0 ..< expectedTotal {
            guard let piece = parts[i] else {
                assembly[key] = nil; meta[key] = nil
                return nil
            }
            full.append(piece)
        }
        assembly[key] = nil
        meta[key] = nil
        seen[key] = now + dedupTTL
        return full
    }

    /// Drop partial buffers older than `fragmentTimeout` and expired dedup records.
    /// Mirrors the interface `_cleanup_loop`.
    public mutating func evictStale(now: TimeInterval) {
        let deadline = now - fragmentTimeout
        for (key, m) in meta where m.timestamp < deadline {
            assembly[key] = nil
            meta[key] = nil
        }
        for (key, expiry) in seen where now >= expiry {
            seen[key] = nil
        }
    }

    // Introspection for tests.
    public var pendingKeyCount: Int { assembly.count }
    public var seenKeyCount: Int { seen.count }
}
