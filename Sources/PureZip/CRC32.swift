import Foundation

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320) as used by ZIP and gzip.
///
/// Uses the "slicing-by-8" technique: eight 256-entry tables allow processing
/// eight input bytes per iteration instead of one.
enum CRC32 {
    /// Eight concatenated 256-entry tables (table `k` occupies indices `k*256..<(k+1)*256`).
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            t[i] = c
        }
        for i in 0..<256 {
            var c = t[i]
            for slice in 1..<8 {
                c = t[Int(c & 0xFF)] ^ (c >> 8)
                t[slice * 256 + i] = c
            }
        }
        return t
    }()

    /// Computes the CRC-32 of `buffer`, optionally continuing from a previous checksum.
    static func checksum(_ buffer: UnsafeRawBufferPointer, seed: UInt32 = 0) -> UInt32 {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return seed }
        var crc = ~seed
        let count = buffer.count
        table.withUnsafeBufferPointer { t in
            var i = 0
            while i + 8 <= count {
                let low = crc ^ base.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian
                let high = base.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self).littleEndian
                crc = t[7 * 256 + Int(low & 0xFF)]
                    ^ t[6 * 256 + Int((low >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((low >> 16) & 0xFF)]
                    ^ t[4 * 256 + Int(low >> 24)]
                    ^ t[3 * 256 + Int(high & 0xFF)]
                    ^ t[2 * 256 + Int((high >> 8) & 0xFF)]
                    ^ t[256 + Int((high >> 16) & 0xFF)]
                    ^ t[Int(high >> 24)]
                i += 8
            }
            while i < count {
                crc = t[Int((crc ^ UInt32(base.load(fromByteOffset: i, as: UInt8.self))) & 0xFF)] ^ (crc >> 8)
                i += 1
            }
        }
        return ~crc
    }

    static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { checksum($0, seed: seed) }
    }

    static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBytes { checksum($0, seed: seed) }
    }
}
