import Foundation

/// Constant tables from the DEFLATE specification (RFC 1951), shared by the
/// compressor and decompressor.
enum DeflateSpec {
    /// Base match length for length codes 257...285 (index 0 = code 257).
    static let lengthBase: [UInt16] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]

    /// Number of extra bits for length codes 257...285.
    static let lengthExtra: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]

    /// Base match distance for distance codes 0...29.
    static let distanceBase: [UInt16] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ]

    /// Number of extra bits for distance codes 0...29.
    static let distanceExtra: [UInt8] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    /// Transmission order of the code-length-alphabet code lengths in a dynamic block header.
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Code lengths of the fixed literal/length Huffman code (288 symbols).
    static let fixedLiteralLengths: [UInt8] = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        return lengths
    }()

    /// Code lengths of the fixed distance Huffman code (30 usable symbols; the
    /// spec defines 32 five-bit codes but codes 30 and 31 never occur in valid data).
    static let fixedDistanceLengths: [UInt8] = [UInt8](repeating: 5, count: 32)

    /// Maximum bits in a literal/length or distance code.
    static let maxCodeBits = 15
    /// Maximum bits in a code-length-alphabet code.
    static let maxCodeLengthBits = 7
    /// Maximum backreference distance.
    static let windowSize = 32768
    /// Maximum match length.
    static let maxMatchLength = 258
    /// Minimum match length.
    static let minMatchLength = 3

    /// Reverses the low `bits` bits of `code` (DEFLATE stores Huffman codes MSB-first
    /// in an otherwise LSB-first stream).
    static func reverseBits(_ code: Int, bits: Int) -> Int {
        var value = code
        var reversed = 0
        for _ in 0..<bits {
            reversed = (reversed << 1) | (value & 1)
            value >>= 1
        }
        return reversed
    }
}
