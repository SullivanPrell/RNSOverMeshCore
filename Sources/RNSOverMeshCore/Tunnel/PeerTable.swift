// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation

/// A parsed `RNSBIND` / `RNSBIND_REQ` channel message.
public struct BindMessage: Equatable {
    public var isRequest: Bool
    public var senderName: String
    public var mcPubkey: String
    public var canRoute: Bool
}

/// The demand-driven peer-discovery and RNS→MeshCore routing state of the Dynamic
/// interface: bound peers, reverse pubkey→name lookups (with prefix keys), learned
/// routing capabilities, the token→peer-key map that drives unicast routing, and
/// the pending-token / opportunistic-request bookkeeping. Mirrors the `_peer_table`
/// family in `MeshCore_Dynamic_Interface`. Callers guard access; time is injected.
public struct PeerTable {

    // Tunables (match the Python class constants).
    public static let reversePrefixLengths = [8, 12, 16, 24]
    public static let rnsMapMax = 512
    public static let pendingMaxSenders = 64
    public static let pendingMaxPerSender = 16
    public static let capabilityRouter = "R"
    public static let capabilityEdge = "E"
    static let bindPrefix = "RNSBIND:"
    static let bindReqPrefix = "RNSBIND_REQ:"

    private var peerTable: [String: String] = [:]        // name → mc pubkey
    private var reversePeers: [String: String] = [:]     // pubkey / prefix → name
    private var peerCaps: [String: Bool] = [:]           // name → canRoute
    private var peerLastSeen: [String: TimeInterval] = [:]
    private var rnsToMc: [Data: String] = [:]            // RNS token → mc pubkey
    private var rnsOrder: [Data] = []                    // insertion order for trimming
    private var pendingTokens: [String: Set<Data>] = [:] // sender → tokens seen before bind
    private var lastUnboundReq: [String: TimeInterval] = [:]

    public init() {}

    // MARK: - Parsing

    /// Parse a channel message that contains an `RNSBIND`/`RNSBIND_REQ`. Returns nil
    /// if it is neither, if the sender name/pubkey is empty, or if the sender is us.
    /// Mirrors the prefix selection in `_on_channel_msg` + `_handle_bind`.
    public static func parseBind(_ text: String, ownName: String) -> BindMessage? {
        let reqIdx = text.range(of: bindReqPrefix)?.lowerBound
        let bindIdx = text.range(of: bindPrefix)?.lowerBound

        let isReq: Bool
        let prefixStart: String.Index
        let prefixLen: Int
        if let r = reqIdx, bindIdx == nil || r <= bindIdx! {
            isReq = true; prefixStart = r; prefixLen = bindReqPrefix.count
        } else if let b = bindIdx {
            isReq = false; prefixStart = b; prefixLen = bindPrefix.count
        } else {
            return nil
        }

        let senderName = String(text[text.startIndex ..< prefixStart])
            .trimmingTrailing(in: CharacterSet(charactersIn: ": "))
        let valueStart = text.index(prefixStart, offsetBy: prefixLen)
        let rawValue = String(text[valueStart...]).trimmingCharacters(in: .whitespaces)

        guard !senderName.isEmpty, !rawValue.isEmpty, senderName != ownName else { return nil }

        let mcPubkey: String
        let canRoute: Bool
        if let colon = rawValue.range(of: ":", options: .backwards) {
            mcPubkey = String(rawValue[rawValue.startIndex ..< colon.lowerBound])
            let cap = String(rawValue[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            canRoute = cap.uppercased() != capabilityEdge
        } else {
            mcPubkey = rawValue
            canRoute = true                     // legacy format: treat as router
        }
        let key = mcPubkey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return BindMessage(isRequest: isReq, senderName: senderName, mcPubkey: key, canRoute: canRoute)
    }

    // MARK: - Bind handling

    /// Result of applying a bind: whether anything changed (for logging) and how
    /// many stashed tokens were backfilled into the routing map.
    public struct BindResult: Equatable { public var changed: Bool; public var backfilled: Int }

    /// Record/update a peer from a parsed bind, backfilling any tokens stashed
    /// before the peer's key was known. Mirrors `_handle_bind`.
    @discardableResult
    public mutating func applyBind(_ msg: BindMessage, now: TimeInterval) -> BindResult {
        let existing = peerTable[msg.senderName]
        let capChanged = peerCaps[msg.senderName] != msg.canRoute

        if existing != msg.mcPubkey {
            peerTable[msg.senderName] = msg.mcPubkey
            reversePeers[msg.mcPubkey] = msg.senderName
            for len in Self.reversePrefixLengths {
                let pfx = String(msg.mcPubkey.prefix(len))
                if !pfx.isEmpty { reversePeers[pfx] = msg.senderName }
            }
        }
        peerCaps[msg.senderName] = msg.canRoute
        peerLastSeen[msg.senderName] = now

        var backfilled = 0
        if let pending = pendingTokens.removeValue(forKey: msg.senderName) {
            for token in pending where rnsToMc[token] == nil {
                mapToken(token, toMcKey: msg.mcPubkey)
                backfilled += 1
            }
        }
        return BindResult(changed: existing != msg.mcPubkey || capChanged, backfilled: backfilled)
    }

    // MARK: - Routing lookups

    public var hasPeers: Bool { !peerTable.isEmpty }
    public var peerCount: Int { peerTable.count }

    public func mcKey(forSender name: String) -> String? { peerTable[name] }
    public func mcKey(forToken token: Data) -> String? { rnsToMc[token] }
    public func canRoute(_ name: String) -> Bool? { peerCaps[name] }

    /// Resolve a (possibly truncated) MeshCore pubkey to a peer name: exact match,
    /// else any stored key that is a prefix of, or has as prefix, `keyStr`.
    /// Mirrors `_resolve_sender_key`.
    public func resolveSenderKey(_ keyStr: String) -> String {
        guard !keyStr.isEmpty else { return keyStr }
        if let name = reversePeers[keyStr] { return name }
        for (storedKey, storedName) in reversePeers {
            if storedKey.hasPrefix(keyStr) || keyStr.hasPrefix(storedKey) { return storedName }
        }
        return keyStr
    }

    /// Map an RNS token to a peer key (idempotent), trimming the oldest half of the
    /// map when it exceeds `rnsMapMax`. Mirrors the `_rns_to_mc_map` growth guard.
    public mutating func mapToken(_ token: Data, toMcKey mcKey: String) {
        guard rnsToMc[token] == nil else { return }
        rnsToMc[token] = mcKey
        rnsOrder.append(token)
        if rnsToMc.count > Self.rnsMapMax {
            let trimCount = Self.rnsMapMax / 2
            for token in rnsOrder.prefix(trimCount) { rnsToMc[token] = nil }
            rnsOrder.removeFirst(min(trimCount, rnsOrder.count))
        }
    }

    // MARK: - Pending tokens & opportunistic requests

    /// Stash a token seen from a sender we have not yet bound with, bounded by the
    /// per-sender and global caps. Mirrors the `_pending_tokens` bookkeeping.
    public mutating func stashPendingToken(_ token: Data, sender: String) {
        if pendingTokens[sender] == nil {
            guard pendingTokens.count < Self.pendingMaxSenders else { return }
            pendingTokens[sender] = []
        }
        if (pendingTokens[sender]?.count ?? 0) < Self.pendingMaxPerSender {
            pendingTokens[sender]?.insert(token)
        }
    }

    /// Rate-gate an opportunistic `RNSBIND_REQ` for `sender`: returns true (and
    /// records `now`) if the last such request was more than `retryInterval` ago.
    public mutating func allowUnboundRequest(sender: String, now: TimeInterval,
                                             retryInterval: TimeInterval) -> Bool {
        if let last = lastUnboundReq[sender], now - last < retryInterval { return false }
        lastUnboundReq[sender] = now
        return true
    }

    // MARK: - Expiry

    /// Remove peers silent longer than `ttl`, along with their reverse keys and any
    /// tokens routed to them. Returns the expired peer names (for logging). Mirrors
    /// the peer-expiry block of `_cleanup_loop`.
    @discardableResult
    public mutating func expirePeers(now: TimeInterval, ttl: TimeInterval) -> [String] {
        let deadline = now - ttl
        let expired = peerLastSeen.filter { $0.value < deadline }.map(\.key)
        for name in expired {
            let mcKey = peerTable.removeValue(forKey: name)
            peerLastSeen[name] = nil
            peerCaps[name] = nil
            if let mcKey {
                reversePeers[mcKey] = nil
                for len in Self.reversePrefixLengths { reversePeers[String(mcKey.prefix(len))] = nil }
                let staleTokens = rnsToMc.filter { $0.value == mcKey }.map(\.key)
                for token in staleTokens { rnsToMc[token] = nil }
            }
            pendingTokens[name] = nil
        }
        // Prune stale opportunistic-request timestamps on the same window.
        lastUnboundReq = lastUnboundReq.filter { $0.value >= deadline }
        return expired
    }

    // Introspection for tests.
    public var tokenMapCount: Int { rnsToMc.count }
    public func pendingTokenCount(sender: String) -> Int { pendingTokens[sender]?.count ?? 0 }
}

private extension String {
    /// Strip the given characters from the end only (Python's `rstrip(chars)`).
    func trimmingTrailing(in set: CharacterSet) -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            guard let scalar = self[prev].unicodeScalars.first,
                  self[prev].unicodeScalars.count == 1, set.contains(scalar) else { break }
            end = prev
        }
        return String(self[startIndex ..< end])
    }
}
