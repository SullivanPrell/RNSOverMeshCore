import Foundation
#if canImport(Network)
import Network

/// A `MeshCoreTransport` over TCP, for MeshCore nodes exposing a companion TCP
/// endpoint (the `transport = tcp` mode of the Python interfaces). Uses
/// `Network.framework`, so it is available on all Apple platforms and needs no
/// host-supplied radio adapter — this is the transport the package ships for
/// desktop use and integration testing. BLE/serial adapters are injected by the
/// host app (RetiOS), mirroring `RNodeTransport`/`BLEMeshTransport`.
///
/// Applies the serial/TCP length-prefix framing (`MeshCoreSerialFraming`): frames
/// are wrapped with `0x3c`+length on send and recovered from the `0x3e`+length
/// stream on receive.
public final class MeshCoreTCPTransport: MeshCoreTransport, @unchecked Sendable {

    public var onFrame: ((Data) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "network.reticulum.rnsomc.tcp")
    private var connection: NWConnection?
    private var decoder = MeshCoreSerialFraming.Decoder()
    private var connected = false
    private var startContinuation: CheckedContinuation<Void, Error>?

    public var isConnected: Bool { queue.sync { connected } }

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let conn = NWConnection(host: NWEndpoint.Host(self.host),
                                        port: NWEndpoint.Port(rawValue: self.port) ?? .any,
                                        using: .tcp)
                self.connection = conn
                self.startContinuation = cont
                conn.stateUpdateHandler = { [weak self] state in
                    self?.queue.async { self?.handleState(state) }
                }
                conn.start(queue: self.queue)
                self.receiveLoop(on: conn)
            }
        }
    }

    public func stop() {
        queue.async {
            self.connected = false
            self.connection?.cancel()
            self.connection = nil
        }
    }

    public func send(_ frame: Data) throws {
        let conn: NWConnection? = queue.sync { connected ? connection : nil }
        guard let conn else { throw MeshCoreTransportError.notConnected }
        conn.send(content: MeshCoreSerialFraming.wrap(frame), completion: .idempotent)
    }

    // MARK: - Internals (on `queue`)

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connected = true
            startContinuation?.resume()
            startContinuation = nil
        case .failed(let error):
            connected = false
            if let cont = startContinuation {
                startContinuation = nil
                cont.resume(throwing: MeshCoreTransportError.connectionFailed("\(error)"))
            } else {
                onDisconnect?(error)
            }
            connection?.cancel()
            connection = nil
        case .cancelled:
            connected = false
        default:
            break
        }
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    for frame in self.decoder.feed(data) {
                        self.onFrame?(frame)
                    }
                }
                if let error {
                    self.connected = false
                    self.onDisconnect?(error)
                    return
                }
                if isComplete {
                    self.connected = false
                    self.onDisconnect?(nil)
                    return
                }
                self.receiveLoop(on: conn)
            }
        }
    }
}
#endif
