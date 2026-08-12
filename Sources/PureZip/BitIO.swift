import Foundation

/// A little-endian bit reader over a byte buffer, as required by DEFLATE (RFC 1951).
///
/// The reader keeps up to 64 bits in an accumulator and refills it in bulk
/// (one unaligned 64-bit load) whenever possible. Reads past the end of the
/// input are served with zero bits so that the hot decode loop stays
/// branch-light; `remainingRealBits` goes negative in that case, which callers
/// check once per decoded symbol to detect truncated input.
struct BitReader {
    private let base: UnsafePointer<UInt8>
    private let count: Int
    /// Index of the next byte to load into the accumulator.
    private var pos: Int = 0
    /// Bit accumulator; the next bit of the stream is bit 0.
    private var bitBuffer: UInt64 = 0
    /// Number of valid (possibly zero-padded) bits in `bitBuffer`.
    private var bitCount: Int = 0
    /// Actual unconsumed bits left in the input; negative after an over-read.
    private var remainingRealBits: Int

    /// - Precondition: `buffer` is non-empty.
    init(_ buffer: UnsafeRawBufferPointer) {
        precondition(!buffer.isEmpty)
        self.base = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        self.count = buffer.count
        self.remainingRealBits = buffer.count * 8
    }

    /// True once more bits were consumed than the input contained.
    var overran: Bool { remainingRealBits < 0 }

    /// Tops the accumulator up to at least 56 valid bits, padding with zeros past the end.
    @inline(__always)
    mutating func refill() {
        if bitCount >= 56 { return }
        if pos + 8 <= count {
            let chunk = UnsafeRawPointer(base + pos).loadUnaligned(as: UInt64.self).littleEndian
            bitBuffer |= chunk &<< UInt64(bitCount)
            pos += (63 - bitCount) >> 3
            bitCount |= 56
        } else {
            while bitCount <= 56 {
                if pos < count {
                    bitBuffer |= UInt64(base[pos]) &<< UInt64(bitCount)
                    pos += 1
                }
                bitCount += 8
            }
        }
    }

    /// Returns the next `n` bits without consuming them. Requires a prior `refill()`.
    @inline(__always)
    func peek(_ n: Int) -> Int {
        Int(bitBuffer & ((1 &<< UInt64(n)) &- 1))
    }

    @inline(__always)
    mutating func consume(_ n: Int) {
        bitBuffer &>>= UInt64(n)
        bitCount &-= n
        remainingRealBits &-= n
    }

    /// Reads `n` bits (n ≤ 32), throwing if the input is exhausted.
    mutating func take(_ n: Int) throws -> Int {
        refill()
        let value = peek(n)
        consume(n)
        if remainingRealBits < 0 { throw ZipError.truncatedData }
        return value
    }

    /// Skips forward to the next byte boundary of the underlying stream.
    mutating func alignToByte() throws {
        guard remainingRealBits >= 0 else { throw ZipError.truncatedData }
        consume(remainingRealBits & 7)
    }

    /// Copies `n` raw bytes to `destination`. The reader must be byte-aligned.
    mutating func readBytes(to destination: UnsafeMutablePointer<UInt8>, count n: Int) throws {
        var out = destination
        var need = n
        // Drain whole bytes still sitting in the accumulator.
        while bitCount >= 8, need > 0 {
            out.pointee = UInt8(truncatingIfNeeded: bitBuffer)
            consume(8)
            out += 1
            need -= 1
        }
        if remainingRealBits < 0 { throw ZipError.truncatedData }
        if need == 0 { return }
        // Any bits left in the accumulator now are zero padding; discard them.
        bitBuffer = 0
        bitCount = 0
        guard count - pos >= need else { throw ZipError.truncatedData }
        memcpy(out, base + pos, need)
        pos += need
        remainingRealBits -= need * 8
    }
}

/// A little-endian bit writer producing a DEFLATE-compatible bit stream.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    mutating func reserveCapacity(_ n: Int) {
        bytes.reserveCapacity(n)
    }

    /// Writes the low `count` bits of `value` (count ≤ 32).
    @inline(__always)
    mutating func write(_ value: Int, bits count: Int) {
        bitBuffer |= (UInt64(value) & ((1 &<< UInt64(count)) &- 1)) &<< UInt64(bitCount)
        bitCount += count
        while bitCount >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: bitBuffer))
            bitBuffer &>>= 8
            bitCount -= 8
        }
    }

    /// Pads with zero bits up to the next byte boundary.
    mutating func alignToByte() {
        if bitCount > 0 {
            bytes.append(UInt8(truncatingIfNeeded: bitBuffer))
            bitBuffer = 0
            bitCount = 0
        }
    }

    /// Appends raw bytes. The writer must be byte-aligned.
    mutating func writeBytes(_ buffer: UnsafeBufferPointer<UInt8>) {
        assert(bitCount == 0)
        bytes.append(contentsOf: buffer)
    }
}
