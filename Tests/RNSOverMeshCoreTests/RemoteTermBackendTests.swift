import XCTest
@testable import RNSOverMeshCore

/// Tests the pure RemoteTerm WebSocket-event filter (the bug-prone part of the
/// backend). The REST/WebSocket transport plumbing itself needs a live server and
/// is integration-only.
final class RemoteTermBackendTests: XCTestCase {

    private let convKey = "c4d2b6c8254e3b11200f57e95dcb1197"

    private func event(type: String = "message", msgType: String = "CHAN",
                       convKey: String? = nil, outgoing: Bool = false,
                       text: String = "RNS:AAAA") -> String {
        var data: [String: Any] = ["type": msgType, "outgoing": outgoing, "text": text]
        if let convKey { data["conversation_key"] = convKey }
        let obj: [String: Any] = ["type": type, "data": data]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private func filter(_ raw: String) -> String? {
        RemoteTermChannelBackend.channelText(fromWSMessage: raw, conversationKey: convKey)
    }

    func testAcceptsInboundChanMessageOnOurKey() {
        XCTAssertEqual(filter(event(convKey: convKey)), "RNS:AAAA")
        // Key comparison is case-insensitive.
        XCTAssertEqual(filter(event(convKey: convKey.uppercased())), "RNS:AAAA")
    }

    func testRejectsWrongTypeChannelKeyOrOutgoing() {
        XCTAssertNil(filter(event(type: "status", convKey: convKey)))       // not a message event
        XCTAssertNil(filter(event(msgType: "PRIV", convKey: convKey)))      // not a channel message
        XCTAssertNil(filter(event(convKey: "deadbeef")))                    // different channel
        XCTAssertNil(filter(event(convKey: nil)))                          // missing key
        XCTAssertNil(filter(event(convKey: convKey, outgoing: true)))       // our own echo
        XCTAssertNil(filter("not json"))
    }
}
