import XCTest
@testable import RNSOverMeshCore

/// Tests for the serial/TCP length-prefix framing (`0x3c`/`0x3e` + uint16-LE len),
/// mirroring `meshcore_py` `serial_cx.py`/`tcp_cx.py` `handle_rx`.
final class MeshCoreSerialFramingTests: XCTestCase {

    /// Build an inbound wire frame: `0x3e` + uint16-LE length + body.
    private func inbound(_ body: Data) -> Data {
        var d = Data([MeshCoreSerialFraming.recvMarker])
        d.appendUInt16LE(UInt16(body.count))
        d.append(body)
        return d
    }

    func testWrapUsesSendMarkerAndLength() {
        let wrapped = MeshCoreSerialFraming.wrap(Data([0xaa, 0xbb, 0xcc]))
        XCTAssertEqual(wrapped, Data([0x3c, 0x03, 0x00, 0xaa, 0xbb, 0xcc]))
    }

    func testDecodeSingleFrame() {
        var dec = MeshCoreSerialFraming.Decoder()
        let frames = dec.feed(inbound(Data([0x05, 0x01, 0x02])))
        XCTAssertEqual(frames, [Data([0x05, 0x01, 0x02])])
    }

    func testDecodeTwoFramesInOneFeed() {
        var dec = MeshCoreSerialFraming.Decoder()
        var wire = inbound(Data([0x00]))
        wire.append(inbound(Data([0x83])))
        XCTAssertEqual(dec.feed(wire), [Data([0x00]), Data([0x83])])
    }

    func testDecodeDiscardsJunkBeforeMarker() {
        var dec = MeshCoreSerialFraming.Decoder()
        var wire = Data("boot log noise\r\n".utf8)   // UART console junk
        wire.append(inbound(Data([0x0a])))
        XCTAssertEqual(dec.feed(wire), [Data([0x0a])])
    }

    func testDecodeFrameSplitAcrossFeeds() {
        var dec = MeshCoreSerialFraming.Decoder()
        let whole = inbound(Data([0x11, 0x22, 0x33, 0x44]))
        // Split mid-header and mid-body across three chunks.
        XCTAssertEqual(dec.feed(whole.prefix(2)), [])
        XCTAssertEqual(dec.feed(whole.subdata(in: 2 ..< 5)), [])
        XCTAssertEqual(dec.feed(Data(whole.suffix(from: 5))), [Data([0x11, 0x22, 0x33, 0x44])])
    }

    func testDecodeResyncsAfterOversizeLength() {
        var dec = MeshCoreSerialFraming.Decoder()
        // Declared length 301 (> 300 guard) must be dropped, then the next valid
        // frame recovered.
        var wire = Data([MeshCoreSerialFraming.recvMarker, 0x2d, 0x01])  // len 301
        wire.append(inbound(Data([0xab])))
        XCTAssertEqual(dec.feed(wire), [Data([0xab])])
    }

    func testDecodeByteAtATime() {
        var dec = MeshCoreSerialFraming.Decoder()
        let whole = inbound(Data([0xde, 0xad, 0xbe, 0xef]))
        var out = [Data]()
        for byte in whole { out += dec.feed(Data([byte])) }
        XCTAssertEqual(out, [Data([0xde, 0xad, 0xbe, 0xef])])
    }
}
