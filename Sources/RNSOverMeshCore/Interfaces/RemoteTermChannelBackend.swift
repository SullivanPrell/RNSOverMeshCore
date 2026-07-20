// SPDX-License-Identifier: GPL-3.0-or-later
// Swift port of comms-engineer/RNS_Over_Meshcore (GPL-3.0). See LICENSE / README.md.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Channel backend that drives a running **Remote-Terminal-for-MeshCore** instance
/// over its REST + WebSocket API instead of owning the radio — the `remoteterm`
/// transport mode of `MeshCore_Channel_Interface`. Useful when RemoteTerm already
/// holds the serial/BLE/TCP connection.
///
///   TX: `POST /api/messages/channel  {channel_key, text}`
///   RX: WebSocket `/api/ws` → `{type:"message", data:{type:"CHAN", conversation_key, outgoing, text}}`
///
/// Not exercised by the unit suite (it needs a live RemoteTerm server); the channel
/// tunnel logic is covered via `CompanionChannelBackend` and a mock backend.
public final class RemoteTermChannelBackend: NSObject, MeshCoreChannelBackend, URLSessionDelegate, @unchecked Sendable {
    public var onChannelText: ((String) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    public struct Config: Sendable {
        public var baseURL: String = "http://localhost:8000"
        public var wsPath: String = "/api/ws"
        public var channelName: String = "RNSTunnel"
        public var channelSecretHex: String = ""
        public var username: String?
        public var password: String?
        /// Skip TLS certificate validation (self-signed RemoteTerm servers).
        public var allowSelfSignedTLS: Bool = false
        public init() {}
    }

    private let config: Config
    private let lock = NSLock()
    private var conversationKey: String
    private var session: URLSession!
    private var wsTask: URLSessionWebSocketTask?
    private var listenerTask: Task<Void, Never>?
    private var running = false

    public init(config: Config) {
        self.config = config
        self.conversationKey = config.channelSecretHex.lowercased()
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    public func start() async throws -> String? {
        try await ensureChannel()
        lock.withLock { running = true }
        startListener()
        return nil     // RemoteTerm exposes no node pubkey → src_id derives from the secret
    }

    public func stop() {
        lock.withLock { running = false }
        wsTask?.cancel(with: .goingAway, reason: nil)
        listenerTask?.cancel()
    }

    public func sendChannelText(_ text: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "channel_key": config.channelSecretHex, "text": text
        ])
        var req = request("/api/messages/channel")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try await session.data(for: req)
    }

    // MARK: - REST helpers

    private func ensureChannel() async throws {
        // Look for our channel by key; create it if missing.
        if let (data, _) = try? await session.data(for: request("/api/channels")),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for ch in list where (ch["key"] as? String)?.lowercased() == conversationKey {
                return
            }
        }
        var req = request("/api/channels")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": config.channelName, "key": config.channelSecretHex
        ])
        _ = try? await session.data(for: req)
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: config.baseURL + path)!)
        if let user = config.username, let pass = config.password,
           let cred = "\(user):\(pass)".data(using: .utf8) {
            req.setValue("Basic \(cred.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - WebSocket listener

    private func startListener() {
        listenerTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 2
            while self.lock.withLock({ self.running }), !Task.isCancelled {
                let wsURL = self.config.baseURL
                    .replacingOccurrences(of: "http://", with: "ws://")
                    .replacingOccurrences(of: "https://", with: "wss://") + self.config.wsPath
                guard let url = URL(string: wsURL) else { return }
                var req = URLRequest(url: url)
                if let user = self.config.username, let pass = self.config.password,
                   let cred = "\(user):\(pass)".data(using: .utf8) {
                    req.setValue("Basic \(cred.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
                let task = self.session.webSocketTask(with: req)
                self.lock.withLock { self.wsTask = task }
                task.resume()
                do {
                    while self.lock.withLock({ self.running }) {
                        let message = try await task.receive()
                        if case .string(let text) = message { self.handleWSMessage(text) }
                        backoff = 2
                    }
                } catch {
                    self.onDisconnect?(error)
                }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func handleWSMessage(_ raw: String) {
        if let text = Self.channelText(fromWSMessage: raw, conversationKey: conversationKey) {
            onChannelText?(text)
        }
    }

    /// Pure filter for a RemoteTerm WebSocket event: returns the channel text only
    /// for an inbound (`outgoing != true`) `CHAN` message on our conversation key.
    /// Extracted so the (bug-prone) filtering logic is unit-testable without a server.
    static func channelText(fromWSMessage raw: String, conversationKey: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "message",
              let msg = event["data"] as? [String: Any],
              msg["type"] as? String == "CHAN",
              (msg["conversation_key"] as? String)?.lowercased() == conversationKey.lowercased(),
              (msg["outgoing"] as? Bool) != true,
              let text = msg["text"] as? String
        else { return nil }
        return text
    }

    // MARK: - URLSessionDelegate (optional self-signed TLS)

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if config.allowSelfSignedTLS, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
