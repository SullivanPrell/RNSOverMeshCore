import Foundation

// Hex helpers kept independent of ReticulumSwift so the Layer A companion codec
// has no RNS dependency. Names are deliberately distinct from ReticulumSwift's
// `Data.hexString` (encoder-only) to avoid any ambiguous-member collision in
// files that import both modules.
extension Data {
    /// Lowercase hex encoding, e.g. `Data([0xDE,0xAD]).hexEncoded == "dead"`.
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Decode a hex string (case-insensitive, optional `0x` prefix, no separators)
    /// into bytes. Returns nil for odd length or non-hex characters.
    init?(hexString: String) {
        var s = Substring(hexString)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
