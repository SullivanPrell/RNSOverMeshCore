import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Layer A high-level seam: the command/event surface the three RNS interfaces use.
//
// This is the Swift analog of `meshcore_py`'s `MeshCore.commands.*` methods plus
// its `subscribe(EventType.…)` event stream. `MeshCoreClient` implements it over a
// raw `MeshCoreTransport`; tunnel interfaces are written against this protocol so
// they can be unit-tested against a mock companion with no radio.
// ─────────────────────────────────────────────────────────────────────────────

/// High-level, transport-agnostic interface to a MeshCore companion device.
///
/// Command methods are `async` and complete when the firmware's matching response
/// frame arrives (or throw on `ERROR`/timeout). Inbound messages and delivery
/// acknowledgements are delivered through the callback properties, which the host
/// sets before calling ``start()``.
public protocol MeshCoreCompanion: AnyObject {

    // MARK: Event callbacks (set before start)

    /// A channel (broadcast) message was received. Firmware prepends the sender's
    /// node name to `text` (e.g. `"Node39: RNS:…"`).
    var onChannelMessage: ((MeshCoreChannelMessage) -> Void)? { get set }

    /// A direct/contact message was received.
    var onContactMessage: ((MeshCoreContactMessage) -> Void)? { get set }

    /// An over-air delivery acknowledgement arrived (matches a prior
    /// `MeshCoreMsgSent.expectedAckHex`).
    var onAck: ((MeshCoreAck) -> Void)? { get set }

    /// The connection to the device dropped.
    var onDisconnect: ((Error?) -> Void)? { get set }

    /// The device identity learned during ``start()`` (own node name + public key),
    /// or nil before start completes.
    var selfInfo: MeshCoreSelfInfo? { get }

    // MARK: Lifecycle & commands

    /// Connect the transport and run `CMD_APP_START`, returning the device
    /// self-info. Also begins auto message fetching (drains queued messages on
    /// each `MESSAGES_WAITING` push).
    func start() async throws -> MeshCoreSelfInfo

    /// Disconnect and stop all activity.
    func stop()

    /// Configure the radio (only when all four values are non-zero — callers gate this).
    func setRadio(freq: Double, bw: Double, sf: Int, cr: Int) async throws

    /// Create/update a channel slot with a 16-byte secret.
    func setChannel(index: Int, name: String, secret: Data) async throws

    /// Broadcast a text message on a channel slot.
    func sendChannelMessage(index: Int, text: String) async throws

    /// Send a direct/contact text message to a peer public-key prefix. Returns the
    /// firmware's `MSG_SENT` confirmation (whose `expectedAckHex` can be awaited
    /// with ``waitForAck(code:timeout:)`` for true over-air delivery).
    @discardableResult
    func sendDirectMessage(pubkeyPrefix: String, text: String) async throws -> MeshCoreMsgSent

    /// Wait up to `timeout` seconds for an `ACK` whose code equals `code`. Returns
    /// true if the ack arrived (including one that arrived just before this call),
    /// false on timeout.
    func waitForAck(code: String, timeout: TimeInterval) async -> Bool

    /// Fetch the device contact list (`CMD_GET_CONTACTS`), accumulating the
    /// `CONTACT_START`/`CONTACT`…/`CONTACT_END` frame sequence into one array.
    func getContacts() async throws -> [MeshCoreContact]
}

public extension MeshCoreCompanion {
    /// Default: no contacts. Lets lightweight companions (and older conformers)
    /// opt out of contact-list support without a stored implementation.
    func getContacts() async throws -> [MeshCoreContact] { [] }
}
