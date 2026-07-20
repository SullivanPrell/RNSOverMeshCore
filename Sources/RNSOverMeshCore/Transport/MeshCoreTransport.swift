import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Layer C: the byte-transport seam to a MeshCore companion radio.
//
// Mirrors the `RNodeTransport` / `BLEMeshTransport` injection pattern already in
// ReticulumSwift: platform-concrete radio I/O (CoreBluetooth, serial hardware) is
// supplied by the host app, so the tunnel logic stays pure and unit-testable
// against a mock. A conforming transport speaks in *complete, unwrapped companion
// frames* — it is responsible for any medium-specific wrapping:
//
//   • BLE  — each GATT notification/write IS exactly one companion frame
//            (companion_protocol.md: "one protocol frame per BLE write/notification").
//            No wrapper; deliver/write frames verbatim.
//   • serial / TCP — frames are length-prefixed on the wire. Use `MeshCoreSerialFraming`
//            to add the `0x3c`+len header on send and to recover frames on receive.
// ─────────────────────────────────────────────────────────────────────────────

/// A raw connection to a MeshCore companion device that exchanges whole companion
/// frames. Injected into `MeshCoreClient`.
public protocol MeshCoreTransport: AnyObject {
    /// Invoked for each complete companion frame received from the firmware
    /// (already unwrapped — no serial length prefix). Never a partial frame.
    var onFrame: ((Data) -> Void)? { get set }

    /// Invoked when the underlying connection drops (with the error if known).
    var onDisconnect: ((Error?) -> Void)? { get set }

    /// Whether the transport currently has a live connection.
    var isConnected: Bool { get }

    /// Establish the connection. Resolves once the device is ready to accept
    /// commands (throws on failure/timeout). Idempotent transports may no-op if
    /// already connected.
    func start() async throws

    /// Tear down the connection and stop delivering frames.
    func stop()

    /// Send one complete companion frame. The transport adds any medium-specific
    /// wrapper (e.g. the serial `0x3c`+length header); callers pass unwrapped frames.
    func send(_ frame: Data) throws
}

/// BLE GATT identifiers for the MeshCore companion service (Nordic UART-style),
/// from `companion_protocol.md`. A CoreBluetooth `MeshCoreTransport` in the host
/// app (e.g. RetiOS) uses these; kept here so every conforming transport agrees.
public enum MeshCoreBLEUUID {
    /// Companion service UUID.
    public static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// RX characteristic — the app writes commands here (App → Firmware).
    public static let rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// TX characteristic — the firmware notifies responses here (Firmware → App).
    public static let tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
}

/// Errors surfaced by transports and the companion client.
public enum MeshCoreTransportError: Error, Equatable {
    case notConnected
    case connectionFailed(String)
    case timedOut
}

// ─────────────────────────────────────────────────────────────────────────────
// Serial / TCP length-prefix framing.
//
// Mirrors `meshcore_py` `serial_cx.py` / `tcp_cx.py`:
//   • send    :  0x3c ('<') + uint16 LE length + frame bytes
//   • receive :  scan for 0x3e ('>') start marker, then uint16 LE length, then body.
//                Junk bytes before the marker are discarded (radios interleave
//                console text on the same UART). A declared length > 300 is treated
//                as corruption: the partial header is dropped and scanning resumes.
// ─────────────────────────────────────────────────────────────────────────────

/// Pure helpers for the serial/TCP companion frame wrapper. Used by
/// `MeshCoreTCPTransport` (and any serial transport a host app supplies).
public enum MeshCoreSerialFraming {

    /// Outbound start marker: `<` (App → Firmware).
    public static let sendMarker: UInt8 = 0x3c
    /// Inbound start marker: `>` (Firmware → App).
    public static let recvMarker: UInt8 = 0x3e
    /// Firmware rejects frames larger than this; used as a resync guard.
    public static let maxFrameSize = 300

    /// Wrap one companion frame for transmission: `0x3c` + uint16-LE length + frame.
    public static func wrap(_ frame: Data) -> Data {
        var out = Data([sendMarker])
        out.appendUInt16LE(UInt16(truncatingIfNeeded: frame.count))
        out.append(frame)
        return out
    }

    /// Incremental receive-side decoder. Feed raw bytes as they arrive; get back
    /// zero or more complete, unwrapped companion frames. Faithfully reproduces the
    /// `handle_rx` state machine (marker scan, 3-byte header, oversize resync,
    /// leftover re-processing).
    public struct Decoder {
        private var header = Data()          // accumulates [marker, lenLo, lenHi]
        private var inframe = Data()
        private var expectedSize = 0

        public init() {}

        public mutating func feed(_ data: Data) -> [Data] {
            var frames = [Data]()
            var buffer = data
            while !buffer.isEmpty {
                if let frame = step(&buffer) {
                    frames.append(frame)
                }
                // step() either consumed bytes and possibly yielded a frame, or
                // signalled "need more" by emptying `buffer`.
                if needsMore { break }
            }
            return frames
        }

        /// True when the decoder has consumed everything and is waiting for more.
        private var needsMore = false

        /// Process as much of `buffer` as possible for one frame boundary. Returns a
        /// completed frame if one finished on this pass; mutates `buffer` to the
        /// unconsumed remainder and sets `needsMore` when it must wait for more bytes.
        private mutating func step(_ buffer: inout Data) -> Data? {
            needsMore = false

            // 1. Find the start-of-frame marker if we don't have header bytes yet.
            if header.isEmpty {
                guard let idx = buffer.firstIndex(of: MeshCoreSerialFraming.recvMarker) else {
                    buffer.removeAll(keepingCapacity: true)   // discard junk, wait for more
                    needsMore = true
                    return nil
                }
                // Drop leading junk up to and including the marker byte.
                buffer = Data(buffer[buffer.index(after: idx)...])
                header.append(MeshCoreSerialFraming.recvMarker)
            }

            // 2. Complete the 3-byte header (marker + uint16 LE length).
            while header.count < 3 && !buffer.isEmpty {
                header.append(buffer.removeFirst())
            }
            if header.count < 3 {
                needsMore = true
                return nil
            }
            if expectedSize == 0 {
                expectedSize = Int(header[header.startIndex + 1]) | (Int(header[header.startIndex + 2]) << 8)
                if expectedSize > MeshCoreSerialFraming.maxFrameSize {
                    // Corrupt length — reset and resync on the remaining bytes.
                    reset()
                    return nil
                }
            }

            // 3. Accumulate the frame body.
            let need = expectedSize - inframe.count
            if buffer.count < need {
                inframe.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                needsMore = true
                return nil
            }
            inframe.append(buffer.prefix(need))
            buffer = Data(buffer.dropFirst(need))
            let frame = inframe
            reset()
            return frame
        }

        private mutating func reset() {
            header.removeAll(keepingCapacity: true)
            inframe.removeAll(keepingCapacity: true)
            expectedSize = 0
        }
    }
}
