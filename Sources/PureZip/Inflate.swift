import Foundation

/// A pure-Swift DEFLATE (RFC 1951) decompressor.
///
/// Designed for ZIP extraction, where the expected uncompressed size is known
/// in advance: the output buffer is hard-capped at that size, so a lying or
/// malicious stream can never produce more data than the archive declared
/// (and the caller checks the declared size against its security limits
/// before calling).
enum Inflate {
    // MARK: - Huffman decoding table

    /// A flat one-level Huffman decoding table: index with the next `maxBits`
    /// stream bits (LSB-first) to get `(codeLength << 10) | symbol`.
    /// An entry of 0 marks a bit pattern not assigned to any symbol.
    struct Table {
        var entries: [UInt16]
        var maxBits: Int

        var isEmpty: Bool { maxBits == 0 }

        init(codeLengths: ArraySlice<UInt8>) throws {
            var lengthCount = [Int](repeating: 0, count: DeflateSpec.maxCodeBits + 1)
            var maxBits = 0
            for length in codeLengths where length > 0 {
                lengthCount[Int(length)] += 1
                maxBits = max(maxBits, Int(length))
            }
            self.maxBits = maxBits
            if maxBits == 0 {
                self.entries = []
                return
            }

            // Reject over-subscribed codes (Kraft inequality). Incomplete codes
            // are tolerated; their unassigned patterns decode to the 0 sentinel.
            var available = 1
            for bits in 1...DeflateSpec.maxCodeBits {
                available <<= 1
                available -= lengthCount[bits]
                if available < 0 {
                    throw ZipError.corruptedData("over-subscribed Huffman code")
                }
            }

            // First canonical code of each length.
            var nextCode = [Int](repeating: 0, count: DeflateSpec.maxCodeBits + 1)
            var code = 0
            for bits in 1...maxBits {
                code = (code + lengthCount[bits - 1]) << 1
                nextCode[bits] = code
            }

            var entries = [UInt16](repeating: 0, count: 1 << maxBits)
            for (symbol, length) in codeLengths.enumerated() where length > 0 {
                let bits = Int(length)
                let assigned = nextCode[bits]
                nextCode[bits] += 1
                let entry = UInt16((bits << 10) | symbol)
                // Fill every table slot whose low `bits` bits match the (reversed) code.
                var index = DeflateSpec.reverseBits(assigned, bits: bits)
                let step = 1 << bits
                while index < entries.count {
                    entries[index] = entry
                    index += step
                }
            }
            self.entries = entries
        }
    }

    private static let fixedLiteralTable: Table =
        try! Table(codeLengths: DeflateSpec.fixedLiteralLengths[...])
    private static let fixedDistanceTable: Table =
        try! Table(codeLengths: DeflateSpec.fixedDistanceLengths[...])

    // MARK: - Output buffer

    /// A manually managed output buffer with a hard size cap. Grows geometrically
    /// so that a stream lying about its uncompressed size cannot force a giant
    /// upfront allocation.
    struct OutputBuffer {
        private(set) var pointer: UnsafeMutablePointer<UInt8>
        private(set) var capacity: Int
        var count = 0
        /// Hard cap — the size the ZIP entry declared (already limit-checked by the caller).
        let limit: Int

        init(limit: Int) {
            self.limit = limit
            self.capacity = max(1, min(limit, 1 << 20))
            self.pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        }

        /// Ensures space for `n` more bytes, throwing if that would exceed the declared size.
        @inline(__always)
        mutating func ensure(_ n: Int) throws {
            if count + n > capacity {
                try grow(to: count + n)
            }
        }

        private mutating func grow(to needed: Int) throws {
            guard needed <= limit else {
                throw ZipError.corruptedData("decompressed data exceeds declared size")
            }
            let newCapacity = min(limit, max(capacity * 2, needed))
            let newPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            newPointer.update(from: pointer, count: count)
            pointer.deallocate()
            pointer = newPointer
            capacity = newCapacity
        }

        mutating func destroy() {
            pointer.deallocate()
            count = 0
            capacity = 0
        }

        /// Transfers ownership of the buffer into a `Data` without copying.
        mutating func takeData() -> Data {
            let data = Data(
                bytesNoCopy: pointer,
                count: count,
                deallocator: .custom { pointer, _ in
                    pointer.assumingMemoryBound(to: UInt8.self).deallocate()
                }
            )
            return data
        }
    }

    // MARK: - Decompression

    /// Decompresses a raw DEFLATE stream whose uncompressed size is known.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes.
    ///   - expectedSize: The exact uncompressed size the container declared.
    /// - Throws: `ZipError` if the stream is invalid, truncated, or produces
    ///   more or less data than `expectedSize`.
    static func decompress(_ input: UnsafeRawBufferPointer, expectedSize: Int) throws -> Data {
        guard !input.isEmpty else { throw ZipError.truncatedData }
        var output = OutputBuffer(limit: expectedSize)
        do {
            var reader = BitReader(input)
            try decode(&reader, into: &output)
            guard output.count == expectedSize else {
                throw ZipError.corruptedData("decompressed size does not match declared size")
            }
        } catch {
            output.destroy()
            throw error
        }
        return output.takeData()
    }

    private static func decode(_ reader: inout BitReader, into output: inout OutputBuffer) throws {
        while true {
            let isFinal = try reader.take(1) == 1
            let blockType = try reader.take(2)
            switch blockType {
            case 0:
                try copyStoredBlock(&reader, into: &output)
            case 1:
                try decodeBlock(&reader, into: &output,
                                literals: fixedLiteralTable, distances: fixedDistanceTable)
            case 2:
                let (literals, distances) = try readDynamicTables(&reader)
                try decodeBlock(&reader, into: &output, literals: literals, distances: distances)
            default:
                throw ZipError.corruptedData("invalid block type")
            }
            if isFinal { return }
        }
    }

    private static func copyStoredBlock(_ reader: inout BitReader, into output: inout OutputBuffer) throws {
        try reader.alignToByte()
        let length = try reader.take(16)
        let lengthComplement = try reader.take(16)
        guard length == (~lengthComplement & 0xFFFF) else {
            throw ZipError.corruptedData("stored block length check failed")
        }
        try output.ensure(length)
        try reader.readBytes(to: output.pointer + output.count, count: length)
        output.count += length
    }

    /// Reads the compressed Huffman code descriptions of a dynamic block.
    private static func readDynamicTables(_ reader: inout BitReader) throws -> (Table, Table) {
        let literalCount = try reader.take(5) + 257
        let distanceCount = try reader.take(5) + 1
        let codeLengthCount = try reader.take(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else {
            throw ZipError.corruptedData("invalid dynamic block header")
        }

        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<codeLengthCount {
            codeLengthLengths[DeflateSpec.codeLengthOrder[i]] = UInt8(try reader.take(3))
        }
        let codeLengthTable = try Table(codeLengths: codeLengthLengths[...])
        guard !codeLengthTable.isEmpty else {
            throw ZipError.corruptedData("empty code-length Huffman code")
        }

        let total = literalCount + distanceCount
        var lengths = [UInt8](repeating: 0, count: total)
        var i = 0
        while i < total {
            let symbol = try decodeSymbol(&reader, codeLengthTable)
            switch symbol {
            case 0...15:
                lengths[i] = UInt8(symbol)
                i += 1
            case 16:
                guard i > 0 else { throw ZipError.corruptedData("code-length repeat with no previous length") }
                let repeatCount = 3 + (try reader.take(2))
                guard i + repeatCount <= total else { throw ZipError.corruptedData("code-length repeat overflow") }
                let previous = lengths[i - 1]
                for _ in 0..<repeatCount { lengths[i] = previous; i += 1 }
            case 17:
                let repeatCount = 3 + (try reader.take(3))
                guard i + repeatCount <= total else { throw ZipError.corruptedData("code-length repeat overflow") }
                i += repeatCount
            case 18:
                let repeatCount = 11 + (try reader.take(7))
                guard i + repeatCount <= total else { throw ZipError.corruptedData("code-length repeat overflow") }
                i += repeatCount
            default:
                throw ZipError.corruptedData("invalid code-length symbol")
            }
        }

        let literalTable = try Table(codeLengths: lengths[0..<literalCount])
        guard !literalTable.isEmpty else {
            throw ZipError.corruptedData("empty literal/length Huffman code")
        }
        let distanceTable = try Table(codeLengths: lengths[literalCount...])
        return (literalTable, distanceTable)
    }

    @inline(__always)
    private static func decodeSymbol(_ reader: inout BitReader, _ table: Table) throws -> Int {
        reader.refill()
        let entry = table.entries[reader.peek(table.maxBits)]
        guard entry != 0 else { throw ZipError.corruptedData("invalid Huffman code") }
        reader.consume(Int(entry >> 10))
        if reader.overran { throw ZipError.truncatedData }
        return Int(entry & 0x3FF)
    }

    /// The hot loop: decodes one compressed block's literal/match stream.
    private static func decodeBlock(
        _ reader: inout BitReader,
        into output: inout OutputBuffer,
        literals: Table,
        distances: Table
    ) throws {
        try literals.entries.withUnsafeBufferPointer { literalEntries in
            let literalMaxBits = literals.maxBits
            let distanceMaxBits = distances.maxBits
            // Copy so an empty distance table still gives a valid (unused) buffer.
            let distanceEntries = distances.entries

            while true {
                reader.refill()
                if reader.overran { throw ZipError.truncatedData }

                let literalEntry = literalEntries[reader.peek(literalMaxBits)]
                guard literalEntry != 0 else { throw ZipError.corruptedData("invalid Huffman code") }
                reader.consume(Int(literalEntry >> 10))
                let symbol = Int(literalEntry & 0x3FF)

                if symbol < 256 {
                    try output.ensure(1)
                    output.pointer[output.count] = UInt8(truncatingIfNeeded: symbol)
                    output.count += 1
                    continue
                }
                if symbol == 256 {
                    if reader.overran { throw ZipError.truncatedData }
                    return
                }

                // Match: length code 257...285.
                let lengthIndex = symbol - 257
                guard lengthIndex < 29 else { throw ZipError.corruptedData("invalid length code") }
                let lengthExtra = Int(DeflateSpec.lengthExtra[lengthIndex])
                let length = Int(DeflateSpec.lengthBase[lengthIndex]) + reader.peek(lengthExtra)
                reader.consume(lengthExtra)

                guard distanceMaxBits > 0 else {
                    throw ZipError.corruptedData("match with empty distance code")
                }
                let distanceEntry = distanceEntries[reader.peek(distanceMaxBits)]
                guard distanceEntry != 0 else { throw ZipError.corruptedData("invalid Huffman code") }
                reader.consume(Int(distanceEntry >> 10))
                let distanceSymbol = Int(distanceEntry & 0x3FF)
                guard distanceSymbol < 30 else { throw ZipError.corruptedData("invalid distance code") }
                let distanceExtra = Int(DeflateSpec.distanceExtra[distanceSymbol])
                let distance = Int(DeflateSpec.distanceBase[distanceSymbol]) + reader.peek(distanceExtra)
                reader.consume(distanceExtra)

                if reader.overran { throw ZipError.truncatedData }
                guard distance <= output.count else {
                    throw ZipError.corruptedData("match distance before start of output")
                }

                try output.ensure(length)
                let destination = output.pointer + output.count
                let source = destination - distance
                if distance >= length {
                    destination.update(from: source, count: length)
                } else if distance == 1 {
                    destination.update(repeating: source.pointee, count: length)
                } else {
                    // Overlapping copy: replicate the period, doubling each pass.
                    destination.update(from: source, count: distance)
                    var copied = distance
                    while copied < length {
                        let chunk = min(copied, length - copied)
                        (destination + copied).update(from: destination, count: chunk)
                        copied += chunk
                    }
                }
                output.count += length
            }
        }
    }
}
