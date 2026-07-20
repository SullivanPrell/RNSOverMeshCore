import XCTest
@testable import RNSOverMeshCore

/// Byte-exact tests for the companion frame codec (Layer A). Fixtures come from
/// `companion_protocol.md` and `meshcore_py` (`commands/*.py`, `reader.py`).
final class MeshCoreFramesTests: XCTestCase {

    private func hex(_ s: String) -> Data { Data(hexString: s)! }

    // MARK: - Command encoders

    func testEncodeSendChannelMessageMatchesDocFixture() {
        // Doc: send "Hello" to channel 1 at timestamp 1234567890 (0x499602D2).
        let frame = MeshCoreFrames.encodeSendChannelMessage(index: 1, text: "Hello",
                                                            timestamp: 1_234_567_890)
        XCTAssertEqual(frame, hex("030001d20296494865 6c6c6f".replacingOccurrences(of: " ", with: "")))
    }

    func testEncodeAppStartMatchesMeshcorePyLayout() {
        // meshcore_py: b"\x01\x03" + 6 spaces + appName.
        let frame = MeshCoreFrames.encodeAppStart(appName: "mccli")
        var expected = Data([0x01, 0x03])
        expected.append(Data(repeating: 0x20, count: 6))
        expected.append(Data("mccli".utf8))
        XCTAssertEqual(frame, expected)
        XCTAssertEqual(frame.hexEncoded, "0103" + "202020202020" + "6d63636c69")  // 0x01,0x03,6×space,"mccli"
    }

    func testEncodeSetRadioLittleEndianScaling() {
        // 915.0 MHz ×1000 = 915000 = 0x000DF638 → LE 38 F6 0D 00
        // 250.0 kHz ×1000 = 250000 = 0x0003D090 → LE 90 D0 03 00
        let frame = MeshCoreFrames.encodeSetRadio(freq: 915.0, bw: 250.0, sf: 10, cr: 5)
        XCTAssertEqual(frame.hexEncoded, "0b" + "38f60d00" + "90d00300" + "0a" + "05")
    }

    func testEncodeSetChannelLayoutAndLength() {
        let secret = hex("c4d2b6c8254e3b11200f57e95dcb1197")
        let frame = MeshCoreFrames.encodeSetChannel(index: 3, name: "RNSTunnel", secret: secret)
        XCTAssertEqual(frame.count, 1 + 1 + 32 + 16)          // type + idx + name(32) + secret(16)
        XCTAssertEqual(frame[frame.startIndex], 0x20)          // CMD_SET_CHANNEL
        XCTAssertEqual(frame[frame.startIndex + 1], 0x03)      // channel index
        // Name null-padded to 32 bytes.
        let nameField = frame.subdata(in: (frame.startIndex + 2) ..< (frame.startIndex + 34))
        XCTAssertEqual(nameField.prefix("RNSTunnel".utf8.count), Data("RNSTunnel".utf8))
        XCTAssertTrue(nameField.dropFirst("RNSTunnel".utf8.count).allSatisfy { $0 == 0 })
        // Secret is the trailing 16 bytes.
        XCTAssertEqual(frame.suffix(16), secret)
    }

    func testEncodeShortCommands() {
        XCTAssertEqual(MeshCoreFrames.encodeSyncNextMessage(), Data([0x0a]))
        XCTAssertEqual(MeshCoreFrames.encodeDeviceQuery(), Data([0x16, 0x03]))
        XCTAssertEqual(MeshCoreFrames.encodeGetChannel(index: 1), Data([0x1f, 0x01]))
        XCTAssertEqual(MeshCoreFrames.encodeGetBattery(), Data([0x14]))
    }

    func testEncodeSendDirectMessageLayout() {
        // meshcore_py: b"\x02\x00" + attempt(1) + ts(4 LE) + dst(6) + text
        let pubkey = "aabbccddeeff00112233"       // ≥6 bytes; first 6 used
        let frame = MeshCoreFrames.encodeSendDirectMessage(pubkeyPrefix: pubkey, text: "Hi",
                                                          timestamp: 0x499602D2, attempt: 2)
        XCTAssertEqual(frame?.hexEncoded, "0200" + "02" + "d2029649" + "aabbccddeeff" + "4869")
    }

    func testEncodeSendDirectMessageRejectsShortKey() {
        XCTAssertNil(MeshCoreFrames.encodeSendDirectMessage(pubkeyPrefix: "aabb", text: "x",
                                                            timestamp: 0))
    }

    // MARK: - Response parsers

    func testParseMsgSent() {
        // [0x06][routeType=1][expected_ack=deadbeef][suggested_timeout=5000ms LE]
        let frame = hex("06" + "01" + "deadbeef" + "88130000")
        guard case .msgSent(let m)? = MeshCoreFrames.parse(frame) else { return XCTFail("not msgSent") }
        XCTAssertEqual(m.routeType, 1)
        XCTAssertEqual(m.expectedAck, hex("deadbeef"))
        XCTAssertEqual(m.expectedAckHex, "deadbeef")
        XCTAssertEqual(m.suggestedTimeoutMs, 5000)
    }

    func testParseAckMatchesMsgSentTag() {
        let frame = hex("82" + "deadbeef")
        guard case .ack(let a)? = MeshCoreFrames.parse(frame) else { return XCTFail("not ack") }
        XCTAssertEqual(a.code, "deadbeef")
        XCTAssertNil(a.tripTimeMs)
        // With trip time appended.
        let framed2 = hex("82" + "deadbeef" + "64000000")
        guard case .ack(let a2)? = MeshCoreFrames.parse(framed2) else { return XCTFail("not ack") }
        XCTAssertEqual(a2.code, "deadbeef")
        XCTAssertEqual(a2.tripTimeMs, 100)
    }

    func testParseChannelMessageStripsTrailingNulls() {
        // [0x08][chan=1][plen=0][txt_type=0][ts=1234567890 LE]["RNS:AAA"\0\0]
        var frame = hex("08" + "01" + "00" + "00" + "d2029649")
        frame.append(Data("RNS:AAA".utf8))
        frame.append(Data([0x00, 0x00]))
        guard case .channelMessage(let c)? = MeshCoreFrames.parse(frame) else { return XCTFail("not chan") }
        XCTAssertEqual(c.channelIdx, 1)
        XCTAssertEqual(c.text, "RNS:AAA")              // trailing nulls stripped
        XCTAssertEqual(c.senderTimestamp, 1_234_567_890)
        XCTAssertNil(c.snr)
    }

    func testParseChannelMessageV3HasSNR() {
        // [0x11][snr=+40 → +10.0dB][res2][chan=2][plen=0][txt_type=0][ts][text]
        var frame = hex("11" + "28" + "0000" + "02" + "00" + "00" + "d2029649")
        frame.append(Data("hey".utf8))
        guard case .channelMessage(let c)? = MeshCoreFrames.parse(frame) else { return XCTFail("not chan v3") }
        XCTAssertEqual(c.channelIdx, 2)
        XCTAssertEqual(c.text, "hey")
        XCTAssertEqual(c.snr, 10.0)                    // 0x28 = 40, /4 = 10.0
    }

    func testParseContactMessageAndSignatureSkip() {
        // txt_type 0: [0x07][pubkey6][plen=255 direct][txt_type=0][ts][text]
        var f0 = hex("07" + "aabbccddeeff" + "ff" + "00" + "d2029649")
        f0.append(Data("ping".utf8))
        guard case .contactMessage(let c0)? = MeshCoreFrames.parse(f0) else { return XCTFail("not contact") }
        XCTAssertEqual(c0.pubkeyPrefix, "aabbccddeeff")
        XCTAssertEqual(c0.pathLen, 255)
        XCTAssertEqual(c0.pathHashMode, -1)
        XCTAssertEqual(c0.text, "ping")

        // txt_type 2: a 4-byte signature must be skipped before the text.
        var f2 = hex("07" + "112233445566" + "00" + "02" + "d2029649" + "cafebabe")
        f2.append(Data("signed".utf8))
        guard case .contactMessage(let c2)? = MeshCoreFrames.parse(f2) else { return XCTFail("not contact2") }
        XCTAssertEqual(c2.text, "signed")
        XCTAssertEqual(c2.txtType, 2)
    }

    func testParseSelfInfoRoundTrip() {
        // Build a SELF_INFO frame per reader.py layout and read it back.
        var f = Data([0x05])
        f.append(contentsOf: [0x01, 0x14, 0x16])                        // adv_type, tx, max_tx
        let pk = hex(String(repeating: "ab", count: 32))
        f.append(pk)                                                    // public_key (32)
        f.appendIntLE(0, count: 4); f.appendIntLE(0, count: 4)          // lat, lon
        f.append(contentsOf: [0x00, 0x00, 0x00, 0x00])                 // multi_acks, loc_policy, telemetry, manual_add
        f.appendUInt32LE(915000)                                        // freq ×1000
        f.appendUInt32LE(250000)                                        // bw ×1000
        f.append(contentsOf: [10, 5])                                   // sf, cr
        f.append(Data("TestNode".utf8))
        guard case .selfInfo(let s)? = MeshCoreFrames.parse(f) else { return XCTFail("not selfInfo") }
        XCTAssertEqual(s.publicKey, String(repeating: "ab", count: 32))
        XCTAssertEqual(s.radioFreq, 915.0)
        XCTAssertEqual(s.radioBw, 250.0)
        XCTAssertEqual(s.radioSf, 10)
        XCTAssertEqual(s.radioCr, 5)
        XCTAssertEqual(s.name, "TestNode")
    }

    func testParseSmallControlFrames() {
        XCTAssertEqual(MeshCoreFrames.parse(Data([0x00])), .ok(value: nil))
        XCTAssertEqual(MeshCoreFrames.parse(hex("00" + "07000000")), .ok(value: 7))
        XCTAssertEqual(MeshCoreFrames.parse(hex("01" + "05")), .error(code: 5))
        XCTAssertEqual(MeshCoreFrames.parse(Data([0x83])), .messagesWaiting)
        XCTAssertEqual(MeshCoreFrames.parse(Data([0x0a])), .noMoreMessages)
        XCTAssertEqual(MeshCoreFrames.parse(hex("09" + "d2029649")), .currentTime(1_234_567_890))
    }

    func testParseUnknownFrameIsNotDropped() {
        let frame = hex("88" + "0102030405")   // LOG_DATA — modelled as unknown
        guard case .unknown(let type, let payload)? = MeshCoreFrames.parse(frame) else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(type, 0x88)
        XCTAssertEqual(payload, hex("0102030405"))
    }

    func testParseEmptyFrameIsNil() {
        XCTAssertNil(MeshCoreFrames.parse(Data()))
    }

    func testParseContactListFrames() {
        // CONTACT_START(count) / CONTACT(pubkey,type,flags,plen,out_path,adv_name) / CONTACT_END(lastmod)
        XCTAssertEqual(MeshCoreFrames.parse(hex("02" + "02000000")), .contactStart(count: 2))
        XCTAssertEqual(MeshCoreFrames.parse(hex("04" + "e8030000")), .contactEnd(lastmod: 1000))

        var f = Data([0x03])
        f.append(hex(String(repeating: "ab", count: 32)))          // public_key
        f.append(contentsOf: [0x01, 0x00, 0xff])                    // type, flags, plen=255 (flood)
        f.append(Data(repeating: 0, count: 64))                     // out_path
        var name = Data("BaseStation".utf8); name.append(Data(repeating: 0, count: 32 - name.count))
        f.append(name)
        guard case .contact(let c)? = MeshCoreFrames.parse(f) else { return XCTFail("not contact") }
        XCTAssertEqual(c.publicKey, String(repeating: "ab", count: 32))
        XCTAssertEqual(c.advName, "BaseStation")
        XCTAssertEqual(c.outPathLen, -1)                            // 255 → flood
        XCTAssertEqual(c.type, 1)
    }

    // MARK: - Hex util

    func testHexRoundTrip() {
        XCTAssertEqual(Data([0xde, 0xad, 0xbe, 0xef]).hexEncoded, "deadbeef")
        XCTAssertEqual(Data(hexString: "DEADBEEF"), Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(Data(hexString: "0xdead"), Data([0xde, 0xad]))
        XCTAssertNil(Data(hexString: "abc"))     // odd length
        XCTAssertNil(Data(hexString: "zz"))      // non-hex
    }
}
