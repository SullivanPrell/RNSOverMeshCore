import XCTest
import CryptoKit
@testable import RNSOverMeshCore

/// Tests for the shared tunnel helpers: header inspection, the three fragmenters,
/// reassembly + dedup, rate limiters, and the RNSBIND peer table.
final class TunnelHelpersTests: XCTestCase {

    private func hex(_ s: String) -> Data { Data(hexString: s)! }

    // MARK: - RNSHeaderInspector

    func testPacketAndDestinationType() {
        // b0 bits: dtype = (b0>>2)&3, ptype = b0&3.
        XCTAssertEqual(RNSHeaderInspector.packetType(Data([0x01])), .announce)
        XCTAssertEqual(RNSHeaderInspector.packetType(Data([0x02])), .linkRequest)
        XCTAssertEqual(RNSHeaderInspector.destinationType(Data([0x08])), .plain)   // 0b1000 → dtype 2
        XCTAssertEqual(RNSHeaderInspector.destinationType(Data([0x00])), .single)
    }

    func testIsBroadcast() {
        XCTAssertTrue(RNSHeaderInspector.isBroadcast(Data([0x01])))          // announce
        XCTAssertTrue(RNSHeaderInspector.isBroadcast(Data([0x08])))          // data + plain = path request
        XCTAssertFalse(RNSHeaderInspector.isBroadcast(Data([0x00])))         // data + single
        XCTAssertFalse(RNSHeaderInspector.isBroadcast(Data([0x03])))         // proof
        XCTAssertTrue(RNSHeaderInspector.isBroadcast(Data()))                // empty → broadcast
    }

    func testExtractTokenSingleAddressHeader() {
        let dest = Data(repeating: 0xCC, count: 16)
        let packet = Data([0x00, 0x00]) + dest + Data("payload".utf8)
        XCTAssertEqual(RNSHeaderInspector.extractToken(packet), dest)
    }

    func testExtractTokenTwoAddressHeader() {
        // header_type bit is 0x40; token is the SECOND 16-byte address.
        let addr1 = Data(repeating: 0xAA, count: 16)
        let addr2 = Data(repeating: 0xBB, count: 16)
        let packet = Data([0x42, 0x00]) + addr1 + addr2 + Data("x".utf8)
        XCTAssertEqual(RNSHeaderInspector.extractToken(packet), addr2)
    }

    func testLinkIDMatchesReferenceHash() {
        // Single-address LINK_REQUEST: SHA256([b0 & 0x0F] + bytes[2:])[:16].
        let b0: UInt8 = 0x02
        let tail = Data("linkreqbody".utf8)
        let packet = Data([b0, 0x00]) + Data(repeating: 0x11, count: 16) + tail
        var hashable = Data([b0 & 0x0F])
        hashable.append(Data(packet[(packet.startIndex + 2)...]))
        let expected = Data(SHA256.hash(data: hashable).prefix(16))
        XCTAssertEqual(RNSHeaderInspector.linkID(fromLinkRequest: packet), expected)
    }

    // MARK: - Base64URL

    func testBase64URLRoundTripAndCharset() {
        let data = Data((0 ..< 20).map { UInt8($0 * 13 & 0xff) })
        let enc = Base64URL.encode(data)
        XCTAssertFalse(enc.contains("="))
        XCTAssertFalse(enc.contains("+"))
        XCTAssertFalse(enc.contains("/"))
        XCTAssertEqual(Base64URL.decode(enc), data)
    }

    // MARK: - DynamicFragmenter

    func testDynamicFragmenterByteExactFixture() {
        // payload "AB", pkt_id=1, total=1, idx=0 → header 00 00000001 01 (BE) + 4142.
        // raw = 0000000001014142 → base64url (no pad) = "AAAAAAEBQUI".
        let frags = DynamicFragmenter.fragments(Data([0x41, 0x42]), packetID: 1)
        XCTAssertEqual(frags, ["RNS:AAAAAAEBQUI"])
    }

    func testDynamicFragmenterRoundTripMultiFragment() {
        let packet = Data((0 ..< 200).map { UInt8($0 & 0xff) })
        let frags = DynamicFragmenter.fragments(packet, packetID: 0xDEADBEEF, payloadSize: 64)
        XCTAssertEqual(frags.count, 4)                       // ceil(200/64)
        var reassembled = Data()
        for (i, f) in frags.enumerated() {
            let frag = DynamicFragmenter.decode(f)!
            XCTAssertEqual(frag.index, i)
            XCTAssertEqual(frag.packetID, 0xDEADBEEF)
            XCTAssertEqual(frag.total, 4)
            reassembled.append(frag.payload)
        }
        XCTAssertEqual(reassembled, packet)
    }

    func testDynamicFragmenterRejectsBadInput() {
        XCTAssertNil(DynamicFragmenter.decode("nope"))
        XCTAssertNil(DynamicFragmenter.decode("RNS:!!!!"))
    }

    // MARK: - ChannelFragmenter

    func testChannelFragmenterRoundTripAndMagic() {
        let src = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = Data((0 ..< 150).map { UInt8($0 & 0xff) })
        let frags = ChannelFragmenter.fragments(packet, sourceID: src, packetID: 7, payloadSize: 64)
        XCTAssertEqual(frags.count, 3)
        var reassembled = Data()
        for (i, f) in frags.enumerated() {
            let frag = ChannelFragmenter.decode(f)!
            XCTAssertEqual(frag.index, i)
            XCTAssertEqual(frag.sourceID, src)
            XCTAssertEqual(frag.packetID, 7)
            XCTAssertEqual(frag.total, 3)
            reassembled.append(frag.payload)
        }
        XCTAssertEqual(reassembled, packet)
    }

    func testChannelFragmenterRejectsWrongMagic() {
        // Encode a fragment whose 2-byte magic is not "RN".
        var raw = Data([0x58, 0x58, 0x00]) + Data([1, 2, 3, 4]) + Data([0x00, 0x01]) + Data("hi".utf8)
        let text = "RNS:" + Base64URL.encode(raw)
        XCTAssertNil(ChannelFragmenter.decode(text))
        raw.removeAll()
    }

    // MARK: - ContactFragmenter

    func testContactFragmenterNearEvenSplit() {
        let data = Data(repeating: 0x5A, count: 10)
        let frags = ContactFragmenter.fragments(data, index: 42, maxPayload: 4)
        // num_packets = 10//4+1 = 3; packet_size = 10//3+1 = 4 → chunks 4,4,2.
        XCTAssertEqual(frags.count, 3)
        let decoded = frags.map { ContactFragmenter.decode($0)! }
        XCTAssertEqual(decoded.map(\.position), [1, 2, -3])
        XCTAssertTrue(decoded.last!.isFinal)
        XCTAssertEqual(decoded.map { $0.index }, [42, 42, 42])
        XCTAssertEqual(decoded.map { $0.payload.count }, [4, 4, 2])
        XCTAssertEqual(decoded.reduce(Data()) { $0 + $1.payload }, data)
    }

    func testContactFragmenterEmptyData() {
        XCTAssertEqual(ContactFragmenter.fragments(Data(), index: 0), [])
    }

    // MARK: - FragmentReassembler

    func testReassemblerCompletesOutOfOrder() {
        var r = FragmentReassembler<String>(dedupTTL: 30, fragmentTimeout: 300)
        XCTAssertNil(r.add(key: "a", index: 1, total: 2, payload: Data([0xBB]), now: 0))
        let full = r.add(key: "a", index: 0, total: 2, payload: Data([0xAA]), now: 1)
        XCTAssertEqual(full, Data([0xAA, 0xBB]))
    }

    func testReassemblerIgnoresDuplicateFragmentAndPacket() {
        var r = FragmentReassembler<String>(dedupTTL: 30, fragmentTimeout: 300)
        _ = r.add(key: "a", index: 0, total: 2, payload: Data([0xAA]), now: 0)
        XCTAssertNil(r.add(key: "a", index: 0, total: 2, payload: Data([0x99]), now: 0)) // dup fragment
        XCTAssertEqual(r.add(key: "a", index: 1, total: 2, payload: Data([0xBB]), now: 0), Data([0xAA, 0xBB]))
        // A fresh single-fragment packet under the same key within the dedup window is dropped.
        XCTAssertNil(r.add(key: "a", index: 0, total: 1, payload: Data([0xCC]), now: 5))
        // After the window it is accepted again.
        XCTAssertEqual(r.add(key: "a", index: 0, total: 1, payload: Data([0xCC]), now: 40), Data([0xCC]))
    }

    func testReassemblerEvictsStalePartials() {
        var r = FragmentReassembler<String>(dedupTTL: 30, fragmentTimeout: 300)
        _ = r.add(key: "a", index: 0, total: 2, payload: Data([0xAA]), now: 0)
        XCTAssertEqual(r.pendingKeyCount, 1)
        r.evictStale(now: 400)
        XCTAssertEqual(r.pendingKeyCount, 0)
    }

    // MARK: - RateLimiters

    func testAnnounceRateLimiter() {
        var lim = AnnounceRateLimiter()
        let dest = hex("00112233")
        XCTAssertTrue(lim.allow(dest: dest, now: 0, rate: 600))
        XCTAssertFalse(lim.allow(dest: dest, now: 100, rate: 600))   // < 600s → suppressed
        XCTAssertTrue(lim.allow(dest: dest, now: 700, rate: 600))    // ≥ 600s → allowed
        XCTAssertTrue(lim.allow(dest: dest, now: 700, rate: 0))      // disabled → always allowed
    }

    func testPathRequestBurstWindow() {
        var lim = PathRequestRateLimiter()
        let dest = hex("aabb")
        XCTAssertTrue(lim.allow(dest: dest, now: 0, rate: 1800, burstWindow: 60))   // first
        XCTAssertTrue(lim.allow(dest: dest, now: 30, rate: 1800, burstWindow: 60))  // in burst
        XCTAssertTrue(lim.allow(dest: dest, now: 55, rate: 1800, burstWindow: 60))  // in burst
        XCTAssertFalse(lim.allow(dest: dest, now: 120, rate: 1800, burstWindow: 60)) // burst over, cooldown
        XCTAssertTrue(lim.allow(dest: dest, now: 2000, rate: 1800, burstWindow: 60)) // cooldown elapsed
    }

    func testPathResponseBypassConsumeOnce() {
        var b = PathResponseBypass()
        let dest = hex("cc")
        b.markPending(dest: dest, now: 0, window: 15)
        XCTAssertTrue(b.consume(dest: dest, now: 5))     // within window
        XCTAssertFalse(b.consume(dest: dest, now: 6))    // already consumed
        b.markPending(dest: dest, now: 0, window: 15)
        XCTAssertFalse(b.consume(dest: dest, now: 20))   // expired
    }

    // MARK: - PeerTable

    func testParseBindVariants() {
        let router = PeerTable.parseBind("Node39: RNSBIND:aabbccddeeff:R", ownName: "Me")
        XCTAssertEqual(router, BindMessage(isRequest: false, senderName: "Node39",
                                           mcPubkey: "aabbccddeeff", canRoute: true))
        let edge = PeerTable.parseBind("Edge1: RNSBIND:112233:E", ownName: "Me")
        XCTAssertEqual(edge?.canRoute, false)
        let req = PeerTable.parseBind("Gw: RNSBIND_REQ:deadbeef:R", ownName: "Me")
        XCTAssertEqual(req?.isRequest, true)
        let legacy = PeerTable.parseBind("Old: RNSBIND:abcdef", ownName: "Me")   // no cap field
        XCTAssertEqual(legacy?.canRoute, true)
        XCTAssertNil(PeerTable.parseBind("Me: RNSBIND:aa:R", ownName: "Me"))     // own name ignored
        XCTAssertNil(PeerTable.parseBind("just chatter", ownName: "Me"))
    }

    func testApplyBindBackfillsPendingTokens() {
        var pt = PeerTable()
        let token = hex("0011223344556677889900aabbccddee")
        // Token seen before the peer bound → stashed, not yet routable.
        pt.stashPendingToken(token, sender: "Node39")
        XCTAssertNil(pt.mcKey(forToken: token))
        let result = pt.applyBind(BindMessage(isRequest: false, senderName: "Node39",
                                              mcPubkey: "aabbccddeeff0011", canRoute: true), now: 0)
        XCTAssertEqual(result.backfilled, 1)
        XCTAssertEqual(pt.mcKey(forToken: token), "aabbccddeeff0011")
        XCTAssertEqual(pt.mcKey(forSender: "Node39"), "aabbccddeeff0011")
    }

    func testResolveSenderKeyByPrefix() {
        var pt = PeerTable()
        pt.applyBind(BindMessage(isRequest: false, senderName: "Node39",
                                 mcPubkey: "aabbccddeeff00112233", canRoute: true), now: 0)
        XCTAssertEqual(pt.resolveSenderKey("aabbccdd"), "Node39")        // 8-char prefix key
        XCTAssertEqual(pt.resolveSenderKey("aabbccddeeff00112233"), "Node39")  // full
        XCTAssertEqual(pt.resolveSenderKey("ffffffff"), "ffffffff")      // unknown → echoed
    }

    func testExpirePeersRemovesReverseAndTokens() {
        var pt = PeerTable()
        let token = hex("0011223344556677889900aabbccddee")
        pt.applyBind(BindMessage(isRequest: false, senderName: "Node39",
                                 mcPubkey: "aabbccddeeff0011", canRoute: true), now: 0)
        pt.mapToken(token, toMcKey: "aabbccddeeff0011")
        XCTAssertEqual(pt.tokenMapCount, 1)
        let expired = pt.expirePeers(now: 100_000, ttl: 86_400)
        XCTAssertEqual(expired, ["Node39"])
        XCTAssertNil(pt.mcKey(forToken: token))
        XCTAssertNil(pt.mcKey(forSender: "Node39"))
        XCTAssertEqual(pt.resolveSenderKey("aabbccdd"), "aabbccdd")      // reverse prefix gone
    }

    func testUnboundRequestRateGate() {
        var pt = PeerTable()
        XCTAssertTrue(pt.allowUnboundRequest(sender: "X", now: 0, retryInterval: 120))
        XCTAssertFalse(pt.allowUnboundRequest(sender: "X", now: 60, retryInterval: 120))
        XCTAssertTrue(pt.allowUnboundRequest(sender: "X", now: 200, retryInterval: 120))
    }
}
