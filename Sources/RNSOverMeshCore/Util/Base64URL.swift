import Foundation

/// URL-safe base64 without padding — the exact encoding the Python interfaces use
/// for fragment bodies: `base64.urlsafe_b64encode(x).rstrip(b"=")` on encode, and
/// re-padding with `"=" * (-len % 4)` before `urlsafe_b64decode` on decode.
enum Base64URL {

    /// Encode `data` as URL-safe base64 with padding stripped.
    static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// Decode URL-safe base64, restoring stripped padding first. Returns nil on
    /// malformed input.
    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
