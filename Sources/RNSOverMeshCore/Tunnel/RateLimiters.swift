// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Outgoing rate limiters for the Dynamic interface. All take an explicit `now`
// (monotonic seconds) so they are deterministic under test. Keys are RNS
// destination ids (`Data`).
// ─────────────────────────────────────────────────────────────────────────────

/// Per-destination announce rate limiter (`outgoing_announce_rate`). Suppresses a
/// re-announce that arrives sooner than `rate` seconds after the last — unless the
/// caller signals it is answering a recent path request (see `PathResponseBypass`).
public struct AnnounceRateLimiter {
    private var lastSent: [Data: TimeInterval] = [:]

    public init() {}

    /// Returns true (and records `now`) if an announce for `dest` may be sent;
    /// false if it should be suppressed. `rate <= 0` disables limiting.
    public mutating func allow(dest: Data, now: TimeInterval, rate: TimeInterval) -> Bool {
        guard rate > 0 else { return true }
        if let last = lastSent[dest], now - last < rate { return false }
        lastSent[dest] = now
        return true
    }

    /// Force-record a send time (used when bypassing the limiter for a path response,
    /// so the next spontaneous announce is still throttled relative to it).
    public mutating func record(dest: Data, now: TimeInterval) { lastSent[dest] = now }

    public mutating func evictStale(now: TimeInterval, rate: TimeInterval) {
        guard rate > 0 else { return }
        let deadline = now - rate * 2
        lastSent = lastSent.filter { $0.value >= deadline }
    }
}

/// Per-destination path-request limiter (`outgoing_path_req_rate`) with a burst
/// window that lets RNS Transport's own natural retry cluster through before the
/// long-run anti-spam cooldown applies. Mirrors the `_path_req_sent_times` logic.
public struct PathRequestRateLimiter {
    private var times: [Data: (first: TimeInterval, last: TimeInterval)] = [:]

    public init() {}

    /// Returns true (updating state) if a path request for `dest` may be sent.
    /// `rate <= 0` disables limiting.
    public mutating func allow(dest: Data, now: TimeInterval, rate: TimeInterval,
                               burstWindow: TimeInterval) -> Bool {
        guard rate > 0 else { return true }
        guard let entry = times[dest] else {
            times[dest] = (now, now)          // first request starts a burst
            return true
        }
        if now - entry.first < burstWindow {
            times[dest] = (entry.first, now)  // still in the burst — allow, refresh last
            return true
        }
        if now - entry.last < rate {
            return false                      // burst over, still cooling down — suppress
        }
        times[dest] = (now, now)              // cooldown elapsed — start a fresh burst
        return true
    }

    public mutating func evictStale(now: TimeInterval, rate: TimeInterval) {
        guard rate > 0 else { return }
        let deadline = now - rate * 2
        times = times.filter { $0.value.last >= deadline }
    }
}

/// Records destinations for which an inbound path request was just seen, so the
/// resulting demand-driven announce can bypass the announce rate limiter within a
/// short window. Mirrors `_path_response_pending`.
public struct PathResponseBypass {
    private var pending: [Data: TimeInterval] = [:]   // dest → expiry

    public init() {}

    /// Flag `dest` as expecting a path-response announce within `window` seconds.
    public mutating func markPending(dest: Data, now: TimeInterval, window: TimeInterval) {
        pending[dest] = now + window
    }

    /// Consume the flag for `dest`: returns true if a valid (unexpired) bypass was
    /// pending. The flag is removed either way, matching the Python `.pop()`.
    public mutating func consume(dest: Data, now: TimeInterval) -> Bool {
        guard let expiry = pending.removeValue(forKey: dest) else { return false }
        return now < expiry
    }

    public mutating func evictStale(now: TimeInterval) {
        pending = pending.filter { now < $0.value }
    }
}
