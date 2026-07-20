import Foundation

/// A forward-only cursor over a `Data` buffer with little-endian integer reads —
/// the Swift analog of the `io.BytesIO` (`dbuf`) reader `meshcore_py` uses in
/// `reader.py` to parse companion frames field-by-field.
///
/// Reads never throw: an over-read returns zero-filled / empty results, matching
/// the defensive `dbuf.read(n)` behaviour in the Python reference (a short frame
/// yields short fields rather than crashing the receive loop). Call sites that
/// need strict validation check `remaining` first.
struct ByteReader {
    private let data: Data
    /// Cursor offset relative to `data.startIndex` (0-based), so this works even
    /// when `data` is a slice whose `startIndex` is not 0.
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    /// Bytes not yet consumed.
    var remaining: Int { max(0, data.count - offset) }

    /// True once the cursor has consumed the whole buffer.
    var isAtEnd: Bool { offset >= data.count }

    /// Read up to `count` bytes, advancing the cursor. Returns fewer bytes than
    /// requested (possibly empty) if the buffer is exhausted — never throws.
    mutating func read(_ count: Int) -> Data {
        guard count > 0, offset < data.count else { return Data() }
        let available = min(count, data.count - offset)
        let start = data.startIndex + offset
        let slice = data[start ..< start + available]
        offset += available
        // Re-base to a 0-indexed standalone Data so callers can index normally.
        return Data(slice)
    }

    /// Read all remaining bytes, advancing the cursor to the end.
    mutating func readAll() -> Data {
        read(remaining)
    }

    /// Read a single byte, or `0` if the buffer is exhausted (mirrors Python's
    /// `dbuf.read(1)[0]` on frames the firmware guarantees are long enough).
    mutating func readUInt8() -> UInt8 {
        let d = read(1)
        return d.first ?? 0
    }

    /// Read a little-endian unsigned integer of `count` bytes (1–8), zero-padded
    /// if the buffer runs short. Little-endian is the companion protocol default
    /// (`companion_protocol.md`: "All multi-byte integers: Little-endian").
    mutating func readUIntLE(_ count: Int) -> UInt64 {
        let d = read(count)
        var value: UInt64 = 0
        for (i, byte) in d.enumerated() {
            value |= UInt64(byte) << (8 * i)
        }
        return value
    }

    /// Read a 32-bit little-endian unsigned integer.
    mutating func readUInt32LE() -> UInt32 { UInt32(truncatingIfNeeded: readUIntLE(4)) }

    /// Read a 16-bit little-endian unsigned integer.
    mutating func readUInt16LE() -> UInt16 { UInt16(truncatingIfNeeded: readUIntLE(2)) }

    /// Read a signed little-endian integer of `count` bytes (used for SNR/RSSI,
    /// latitude/longitude), sign-extending from the high bit of the last byte.
    mutating func readIntLE(_ count: Int) -> Int64 {
        guard count > 0 else { return 0 }
        let raw = readUIntLE(count)
        let signBit: UInt64 = 1 << (8 * count - 1)
        if raw & signBit != 0 {
            // Negative: subtract 2^(8*count).
            let magnitude = (UInt64(1) << (8 * count))
            return Int64(bitPattern: raw &- magnitude)
        }
        return Int64(bitPattern: raw)
    }
}

// MARK: - Little-endian encoding helpers

extension Data {
    /// Append `value` as `count` little-endian bytes (1–8). Mirrors Python's
    /// `int.to_bytes(count, "little")` used throughout `meshcore_py` command builders.
    mutating func appendUIntLE(_ value: UInt64, count: Int) {
        for i in 0 ..< count {
            append(UInt8(truncatingIfNeeded: value >> (8 * i)))
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) { appendUIntLE(UInt64(value), count: 4) }
    mutating func appendUInt16LE(_ value: UInt16) { appendUIntLE(UInt64(value), count: 2) }

    /// Append `value` as `count` little-endian bytes, two's-complement for negatives.
    mutating func appendIntLE(_ value: Int64, count: Int) {
        appendUIntLE(UInt64(bitPattern: value), count: count)
    }
}
