// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation

/// Pluggable backend for `MeshCoreChannelInterface`: something that can broadcast a
/// channel text and report channel texts received. Two implementations mirror the
/// Python `MeshCore_Channel_Interface` transport modes — a direct radio companion
/// (`CompanionChannelBackend`) and a RemoteTerm HTTP/WebSocket bridge
/// (`RemoteTermChannelBackend`).
public protocol MeshCoreChannelBackend: AnyObject {
    /// Invoked for each channel message text received (may include a sender-name prefix).
    var onChannelText: ((String) -> Void)? { get set }
    /// Invoked when the backend connection drops.
    var onDisconnect: ((Error?) -> Void)? { get set }

    /// Connect and configure. Returns the own node public-key hex if the backend
    /// knows it (used to derive the 4-byte src_id), else nil.
    func start() async throws -> String?
    func stop()

    /// Broadcast one channel message text.
    func sendChannelText(_ text: String) async throws
}

/// Channel backend over a direct MeshCore radio (`MeshCoreCompanion`) — the
/// `serial` / `ble` / `tcp` modes. Sets the radio (if configured) and channel slot
/// on `start`, forwards received channel-message text, and broadcasts via
/// `sendChannelMessage`.
public final class CompanionChannelBackend: MeshCoreChannelBackend, @unchecked Sendable {
    public var onChannelText: ((String) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let companion: MeshCoreCompanion
    private let channelIndex: Int
    private let channelName: String
    private let channelSecret: Data?
    private let radio: (freq: Double, bw: Double, sf: Int, cr: Int)?

    public init(companion: MeshCoreCompanion, channelIndex: Int, channelName: String,
                channelSecret: Data?, radio: (freq: Double, bw: Double, sf: Int, cr: Int)? = nil) {
        self.companion = companion
        self.channelIndex = channelIndex
        self.channelName = channelName
        self.channelSecret = channelSecret
        self.radio = radio
    }

    public func start() async throws -> String? {
        companion.onChannelMessage = { [weak self] msg in self?.onChannelText?(msg.text) }
        companion.onDisconnect = { [weak self] err in self?.onDisconnect?(err) }
        let info = try await companion.start()
        if let radio, radio.freq > 0, radio.bw > 0, radio.sf > 0, radio.cr > 0 {
            try? await companion.setRadio(freq: radio.freq, bw: radio.bw, sf: radio.sf, cr: radio.cr)
        }
        if let channelSecret {
            try? await companion.setChannel(index: channelIndex, name: channelName, secret: channelSecret)
        }
        return info.publicKey
    }

    public func stop() { companion.stop() }

    public func sendChannelText(_ text: String) async throws {
        try await companion.sendChannelMessage(index: channelIndex, text: text)
    }
}
