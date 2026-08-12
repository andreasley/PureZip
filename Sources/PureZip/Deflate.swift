import Foundation

/// Trade-off between compression speed and ratio.
public enum CompressionLevel: Sendable {
    /// Greedy matching with short hash chains. Fastest, lowest ratio.
    case fastest
    /// Lazy matching with moderate search depth. Good balance (default).
    case normal
    /// Exhaustive lazy matching. Slowest, best ratio.
    case maximum

    var parameters: (maxChain: Int, maxLazy: Int, niceLength: Int) {
        switch self {
        case .fastest: return (maxChain: 8, maxLazy: 0, niceLength: 16)
        case .normal: return (maxChain: 128, maxLazy: 32, niceLength: 128)
        case .maximum: return (maxChain: 2048, maxLazy: 258, niceLength: 258)
        }
    }
}

/// A pure-Swift DEFLATE (RFC 1951) compressor.
///
/// LZ77 matching uses hash chains over 4-byte prefixes with optional lazy
/// evaluation. Tokens are buffered and emitted in Huffman blocks; for each
/// block the encoder picks whichever of stored/fixed/dynamic encoding is
/// smallest, so output is never much larger than the input.
enum Deflate {
    private static let hashBits = 15
    private static let hashSize = 1 << hashBits
    private static let windowMask = DeflateSpec.windowSize - 1
    /// Tokens buffered before a Huffman block is emitted.
    private static let maxTokensPerBlock = 1 << 15

    // MARK: - Encoder lookup tables

    /// Maps `length - 3` (0...255) to the DEFLATE length code index 0...28.
    private static let lengthCodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for code in 0..<28 {
            let base = Int(DeflateSpec.lengthBase[code])
            let span = 1 << Int(DeflateSpec.lengthExtra[code])
            for length in base..<min(base + span, 259) where length - 3 < 256 {
                table[length - 3] = UInt8(code)
            }
        }
        table[255] = 28 // length 258 has its own code
        return table
    }()

    /// Distance code for distances 1...256, indexed by `distance - 1`.
    private static let distanceCodeSmall: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for code in 0..<30 {
            let base = Int(DeflateSpec.distanceBase[code])
            let span = 1 << Int(DeflateSpec.distanceExtra[code])
            for distance in base..<(base + span) where distance <= 256 {
                table[distance - 1] = UInt8(code)
            }
        }
        return table
    }()

    /// Distance code for distances 257...32768, indexed by `(distance - 1) >> 7`.
    private static let distanceCodeLarge: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for code in 0..<30 {
            let base = Int(DeflateSpec.distanceBase[code])
            let span = 1 << Int(DeflateSpec.distanceExtra[code])
            for distance in base..<(base + span) where distance > 256 {
                table[(distance - 1) >> 7] = UInt8(code)
            }
        }
        return table
    }()

    @inline(__always)
    private static func distanceCode(_ distance: Int) -> Int {
        distance <= 256
            ? Int(distanceCodeSmall[distance - 1])
            : Int(distanceCodeLarge[(distance - 1) >> 7])
    }

    private static let fixedLiteralCodes = canonicalCodes(lengths: DeflateSpec.fixedLiteralLengths)
    private static let fixedDistanceCodes = canonicalCodes(lengths: Array(DeflateSpec.fixedDistanceLengths[0..<30]))
    private static let fixedDistanceLengths30 = Array(DeflateSpec.fixedDistanceLengths[0..<30])

    // MARK: - Public entry points

    static func compress(_ data: Data, level: CompressionLevel = .normal) -> [UInt8] {
        data.withUnsafeBytes { raw in
            compress(raw.bindMemory(to: UInt8.self), level: level)
        }
    }

    static func compress(_ input: UnsafeBufferPointer<UInt8>, level: CompressionLevel = .normal) -> [UInt8] {
        let n = input.count
        var writer = BitWriter()
        writer.reserveCapacity(n / 2 + 64)

        var tokens = [UInt32](repeating: 0, count: maxTokensPerBlock)
        var tokenCount = 0
        var literalFrequencies = [Int](repeating: 0, count: 286)
        var distanceFrequencies = [Int](repeating: 0, count: 30)
        var blockStart = 0

        func flush(final: Bool, coveredEnd: Int) {
            tokens.withUnsafeBufferPointer { tokenBuffer in
                emitBlock(
                    &writer,
                    tokens: tokenBuffer, tokenCount: tokenCount,
                    literalFrequencies: &literalFrequencies,
                    distanceFrequencies: &distanceFrequencies,
                    input: input, range: blockStart..<coveredEnd, isFinal: final
                )
            }
            tokenCount = 0
            literalFrequencies = [Int](repeating: 0, count: 286)
            distanceFrequencies = [Int](repeating: 0, count: 30)
            blockStart = coveredEnd
        }

        if n == 0 {
            flush(final: true, coveredEnd: 0)
            writer.alignToByte()
            return writer.bytes
        }

        let parameters = level.parameters
        var head = [Int32](repeating: -1, count: hashSize)
        var previous = [Int32](repeating: -1, count: DeflateSpec.windowSize)

        head.withUnsafeMutableBufferPointer { head in
            previous.withUnsafeMutableBufferPointer { previous in
                let bytes = input.baseAddress!

                func hashValue(_ position: Int) -> Int {
                    let value = UnsafeRawPointer(bytes + position).loadUnaligned(as: UInt32.self).littleEndian
                    return Int((value &* 2_654_435_761) >> (32 - UInt32(hashBits)))
                }

                // Positions [0, nextInsert) are already in the hash chains.
                var nextInsert = 0
                let insertLimit = n - 3 // a position needs 4 readable bytes to be hashed

                func insert(upTo end: Int) {
                    let stop = min(end, insertLimit)
                    var position = nextInsert
                    while position < stop {
                        let hash = hashValue(position)
                        previous[position & windowMask] = head[hash]
                        head[hash] = Int32(position)
                        position += 1
                    }
                    if stop > nextInsert { nextInsert = stop }
                }

                /// Finds the longest match at `position` that beats `toBeat`.
                func findMatch(at position: Int, toBeat: Int) -> (length: Int, distance: Int) {
                    guard position + 4 <= n else { return (0, 0) }
                    let maxLength = min(DeflateSpec.maxMatchLength, n - position)
                    var best = max(DeflateSpec.minMatchLength - 1, toBeat)
                    guard best < maxLength else { return (0, 0) }
                    var bestDistance = 0
                    var candidate = Int(head[hashValue(position)])
                    let windowLimit = position - DeflateSpec.windowSize
                    var chainsLeft = parameters.maxChain
                    let niceLength = min(parameters.niceLength, maxLength)
                    while candidate >= 0, candidate >= windowLimit, chainsLeft > 0 {
                        chainsLeft -= 1
                        // Quick reject: a longer match must improve on byte `best`.
                        if bytes[candidate + best] == bytes[position + best] {
                            let length = matchLength(bytes, candidate, position, maxLength)
                            if length > best {
                                best = length
                                bestDistance = position - candidate
                                if length >= niceLength { break }
                            }
                        }
                        candidate = Int(previous[candidate & windowMask])
                    }
                    guard bestDistance > 0 else { return (0, 0) }
                    return (best, bestDistance)
                }

                func addLiteral(at position: Int) {
                    let byte = bytes[position]
                    tokens[tokenCount] = UInt32(byte)
                    tokenCount += 1
                    literalFrequencies[Int(byte)] += 1
                    if tokenCount == maxTokensPerBlock { flush(final: false, coveredEnd: position + 1) }
                }

                func addMatch(at position: Int, length: Int, distance: Int) {
                    tokens[tokenCount] = (UInt32(distance) << 16) | UInt32(length - 3)
                    tokenCount += 1
                    literalFrequencies[257 + Int(lengthCodeTable[length - 3])] += 1
                    distanceFrequencies[distanceCode(distance)] += 1
                    if tokenCount == maxTokensPerBlock { flush(final: false, coveredEnd: position + length) }
                }

                var i = 0
                while i < n {
                    insert(upTo: i)
                    var match = findMatch(at: i, toBeat: 0)
                    if match.length == 0 {
                        addLiteral(at: i)
                        i += 1
                        continue
                    }
                    // Lazy evaluation: prefer a longer match starting one byte later.
                    while match.length < parameters.maxLazy, i + 1 < n {
                        insert(upTo: i + 1)
                        let next = findMatch(at: i + 1, toBeat: match.length)
                        guard next.length > match.length else { break }
                        addLiteral(at: i)
                        i += 1
                        match = next
                    }
                    addMatch(at: i, length: match.length, distance: match.distance)
                    insert(upTo: i + match.length)
                    i += match.length
                }
            }
        }

        flush(final: true, coveredEnd: n)
        // DEFLATE streams are zero-padded to a whole byte at the end.
        writer.alignToByte()
        return writer.bytes
    }

    @inline(__always)
    private static func matchLength(
        _ bytes: UnsafePointer<UInt8>, _ a: Int, _ b: Int, _ maxLength: Int
    ) -> Int {
        var length = 0
        // Compare 8 bytes at a time; the differing byte is found via trailing zeros
        // (valid on little-endian hardware, which all Swift platforms are).
        while length + 8 <= maxLength {
            let difference = UnsafeRawPointer(bytes + a + length).loadUnaligned(as: UInt64.self)
                ^ UnsafeRawPointer(bytes + b + length).loadUnaligned(as: UInt64.self)
            if difference != 0 { return length + (difference.trailingZeroBitCount >> 3) }
            length += 8
        }
        while length < maxLength, bytes[a + length] == bytes[b + length] { length += 1 }
        return length
    }

    // MARK: - Block emission

    private static func emitBlock(
        _ writer: inout BitWriter,
        tokens: UnsafeBufferPointer<UInt32>, tokenCount: Int,
        literalFrequencies: inout [Int], distanceFrequencies: inout [Int],
        input: UnsafeBufferPointer<UInt8>, range: Range<Int>, isFinal: Bool
    ) {
        literalFrequencies[256] += 1 // end-of-block marker

        let literalLengths = buildCodeLengths(frequencies: literalFrequencies, maxBits: DeflateSpec.maxCodeBits)
        let distanceLengths = buildCodeLengths(frequencies: distanceFrequencies, maxBits: DeflateSpec.maxCodeBits)

        var literalCount = 286
        while literalCount > 257, literalLengths[literalCount - 1] == 0 { literalCount -= 1 }
        var distanceCount = 30
        while distanceCount > 1, distanceLengths[distanceCount - 1] == 0 { distanceCount -= 1 }

        let rle = runLengthEncode(Array(literalLengths[0..<literalCount]) + distanceLengths[0..<distanceCount])
        var codeLengthFrequencies = [Int](repeating: 0, count: 19)
        for token in rle { codeLengthFrequencies[Int(token.symbol)] += 1 }
        let codeLengthLengths = buildCodeLengths(
            frequencies: codeLengthFrequencies, maxBits: DeflateSpec.maxCodeLengthBits
        )
        var codeLengthCount = 19
        while codeLengthCount > 4,
              codeLengthLengths[DeflateSpec.codeLengthOrder[codeLengthCount - 1]] == 0 {
            codeLengthCount -= 1
        }

        func bodyBits(_ literalLengths: [UInt8], _ distanceLengths: [UInt8]) -> Int {
            var bits = 0
            for symbol in 0..<286 where literalFrequencies[symbol] > 0 {
                bits += literalFrequencies[symbol] * Int(literalLengths[symbol])
                if symbol >= 257 {
                    bits += literalFrequencies[symbol] * Int(DeflateSpec.lengthExtra[symbol - 257])
                }
            }
            for code in 0..<30 where distanceFrequencies[code] > 0 {
                bits += distanceFrequencies[code]
                    * (Int(distanceLengths[code]) + Int(DeflateSpec.distanceExtra[code]))
            }
            return bits
        }

        var headerBits = 14 + 3 * codeLengthCount
        for token in rle {
            headerBits += Int(codeLengthLengths[Int(token.symbol)]) + Int(token.extraBits)
        }
        let dynamicBits = 3 + headerBits + bodyBits(literalLengths, distanceLengths)
        let fixedBits = 3 + bodyBits(DeflateSpec.fixedLiteralLengths, fixedDistanceLengths30)
        let storedChunks = max(1, (range.count + 65534) / 65535)
        let storedBits = storedChunks * (3 + 7 + 32) + range.count * 8

        if storedBits < dynamicBits, storedBits < fixedBits {
            writeStoredBlocks(&writer, input: input, range: range, isFinal: isFinal)
            return
        }

        writer.write(isFinal ? 1 : 0, bits: 1)
        if fixedBits <= dynamicBits {
            writer.write(1, bits: 2)
            writeTokens(
                &writer, tokens: tokens, count: tokenCount,
                literalCodes: fixedLiteralCodes, literalLengths: DeflateSpec.fixedLiteralLengths,
                distanceCodes: fixedDistanceCodes, distanceLengths: fixedDistanceLengths30
            )
        } else {
            writer.write(2, bits: 2)
            writer.write(literalCount - 257, bits: 5)
            writer.write(distanceCount - 1, bits: 5)
            writer.write(codeLengthCount - 4, bits: 4)
            for i in 0..<codeLengthCount {
                writer.write(Int(codeLengthLengths[DeflateSpec.codeLengthOrder[i]]), bits: 3)
            }
            let codeLengthCodes = canonicalCodes(lengths: codeLengthLengths)
            for token in rle {
                let symbol = Int(token.symbol)
                writer.write(Int(codeLengthCodes[symbol]), bits: Int(codeLengthLengths[symbol]))
                if token.extraBits > 0 {
                    writer.write(Int(token.extraValue), bits: Int(token.extraBits))
                }
            }
            let literalCodes = canonicalCodes(lengths: literalLengths)
            let distanceCodes = canonicalCodes(lengths: distanceLengths)
            writeTokens(
                &writer, tokens: tokens, count: tokenCount,
                literalCodes: literalCodes, literalLengths: literalLengths,
                distanceCodes: distanceCodes, distanceLengths: distanceLengths
            )
        }
    }

    private static func writeStoredBlocks(
        _ writer: inout BitWriter,
        input: UnsafeBufferPointer<UInt8>, range: Range<Int>, isFinal: Bool
    ) {
        var offset = range.lowerBound
        repeat {
            let chunk = min(65535, range.upperBound - offset)
            let isLast = offset + chunk == range.upperBound
            writer.write((isFinal && isLast) ? 1 : 0, bits: 1)
            writer.write(0, bits: 2)
            writer.alignToByte()
            writer.write(chunk, bits: 16)
            writer.write(~chunk & 0xFFFF, bits: 16)
            if chunk > 0 {
                writer.writeBytes(UnsafeBufferPointer(rebasing: input[offset..<offset + chunk]))
            }
            offset += chunk
        } while offset < range.upperBound
    }

    private static func writeTokens(
        _ writer: inout BitWriter,
        tokens: UnsafeBufferPointer<UInt32>, count: Int,
        literalCodes: [UInt16], literalLengths: [UInt8],
        distanceCodes: [UInt16], distanceLengths: [UInt8]
    ) {
        for i in 0..<count {
            let token = tokens[i]
            if token < 0x10000 {
                // Literal byte.
                let symbol = Int(token)
                writer.write(Int(literalCodes[symbol]), bits: Int(literalLengths[symbol]))
            } else {
                let lengthMinus3 = Int(token & 0xFF)
                let distance = Int(token >> 16)
                let lengthCode = Int(lengthCodeTable[lengthMinus3])
                let symbol = 257 + lengthCode
                writer.write(Int(literalCodes[symbol]), bits: Int(literalLengths[symbol]))
                let lengthExtraBits = Int(DeflateSpec.lengthExtra[lengthCode])
                if lengthExtraBits > 0 {
                    writer.write(
                        lengthMinus3 + 3 - Int(DeflateSpec.lengthBase[lengthCode]),
                        bits: lengthExtraBits
                    )
                }
                let dCode = distanceCode(distance)
                writer.write(Int(distanceCodes[dCode]), bits: Int(distanceLengths[dCode]))
                let distanceExtraBits = Int(DeflateSpec.distanceExtra[dCode])
                if distanceExtraBits > 0 {
                    writer.write(distance - Int(DeflateSpec.distanceBase[dCode]), bits: distanceExtraBits)
                }
            }
        }
        writer.write(Int(literalCodes[256]), bits: Int(literalLengths[256])) // end of block
    }

    // MARK: - Huffman code construction

    /// Builds length-limited Huffman code lengths for the given symbol frequencies.
    ///
    /// Builds an optimal Huffman tree first, then redistributes any code longer
    /// than `maxBits` using the same bit-length adjustment zlib uses; the result
    /// always satisfies the Kraft equality, so canonical codes can be assigned.
    static func buildCodeLengths(frequencies: [Int], maxBits: Int) -> [UInt8] {
        let symbolCount = frequencies.count
        var lengths = [UInt8](repeating: 0, count: symbolCount)
        var symbols: [Int] = []
        symbols.reserveCapacity(symbolCount)
        for symbol in 0..<symbolCount where frequencies[symbol] > 0 { symbols.append(symbol) }
        symbols.sort {
            frequencies[$0] != frequencies[$1] ? frequencies[$0] < frequencies[$1] : $0 < $1
        }
        let n = symbols.count
        if n == 0 { return lengths }
        if n == 1 {
            lengths[symbols[0]] = 1
            return lengths
        }

        // Huffman tree via the two-queue method over frequency-sorted leaves.
        let nodeCount = 2 * n - 1
        var weight = [Int](repeating: 0, count: nodeCount)
        var parent = [Int](repeating: -1, count: nodeCount)
        for k in 0..<n { weight[k] = frequencies[symbols[k]] }
        var leafIndex = 0
        var internalIndex = n

        func pickSmallest(_ nextInternal: Int) -> Int {
            if leafIndex < n,
               internalIndex >= nextInternal || weight[leafIndex] <= weight[internalIndex] {
                leafIndex += 1
                return leafIndex - 1
            } else {
                internalIndex += 1
                return internalIndex - 1
            }
        }

        for next in n..<nodeCount {
            let a = pickSmallest(next)
            let b = pickSmallest(next)
            weight[next] = weight[a] + weight[b]
            parent[a] = next
            parent[b] = next
        }

        // Children are always created before their parent, so a reverse pass
        // computes depths top-down.
        var depth = [Int](repeating: 0, count: nodeCount)
        for node in stride(from: nodeCount - 2, through: 0, by: -1) {
            depth[node] = depth[parent[node]] + 1
        }

        // Count leaves per depth, clamping any depth beyond maxBits.
        var lengthCount = [Int](repeating: 0, count: maxBits + 1)
        var overflow = 0
        for leaf in 0..<n {
            var bits = depth[leaf]
            if bits > maxBits {
                bits = maxBits
                overflow += 1
            }
            lengthCount[bits] += 1
        }
        // Redistribute overflow leaves (zlib's algorithm): repeatedly move one
        // leaf one level down to make room at the maximum depth.
        while overflow > 0 {
            var bits = maxBits - 1
            while lengthCount[bits] == 0 { bits -= 1 }
            lengthCount[bits] -= 1
            lengthCount[bits + 1] += 2
            lengthCount[maxBits] -= 1
            overflow -= 2
        }

        // Assign the longest codes to the least frequent symbols.
        var index = 0
        var bits = maxBits
        while bits >= 1 {
            for _ in 0..<lengthCount[bits] {
                lengths[symbols[index]] = UInt8(bits)
                index += 1
            }
            bits -= 1
        }
        return lengths
    }

    /// Canonical DEFLATE code assignment, returned with bit-reversed codes
    /// ready for the LSB-first bit writer.
    static func canonicalCodes(lengths: [UInt8]) -> [UInt16] {
        var lengthCount = [Int](repeating: 0, count: DeflateSpec.maxCodeBits + 1)
        for length in lengths where length > 0 { lengthCount[Int(length)] += 1 }
        var nextCode = [Int](repeating: 0, count: DeflateSpec.maxCodeBits + 1)
        var code = 0
        for bits in 1...DeflateSpec.maxCodeBits {
            code = (code + lengthCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        var codes = [UInt16](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let bits = Int(length)
            codes[symbol] = UInt16(DeflateSpec.reverseBits(nextCode[bits], bits: bits))
            nextCode[bits] += 1
        }
        return codes
    }

    // MARK: - Code length run-length encoding

    struct CodeLengthToken {
        let symbol: UInt8
        let extraBits: UInt8
        let extraValue: UInt8
    }

    /// Encodes a code-length sequence with the 16/17/18 repeat codes of RFC 1951.
    static func runLengthEncode(_ lengths: [UInt8]) -> [CodeLengthToken] {
        var result: [CodeLengthToken] = []
        result.reserveCapacity(lengths.count)
        var i = 0
        while i < lengths.count {
            let length = lengths[i]
            var run = 1
            while i + run < lengths.count, lengths[i + run] == length { run += 1 }
            i += run
            if length == 0 {
                while run >= 11 {
                    let chunk = min(run, 138)
                    result.append(CodeLengthToken(symbol: 18, extraBits: 7, extraValue: UInt8(chunk - 11)))
                    run -= chunk
                }
                if run >= 3 {
                    result.append(CodeLengthToken(symbol: 17, extraBits: 3, extraValue: UInt8(run - 3)))
                    run = 0
                }
                while run > 0 {
                    result.append(CodeLengthToken(symbol: 0, extraBits: 0, extraValue: 0))
                    run -= 1
                }
            } else {
                result.append(CodeLengthToken(symbol: length, extraBits: 0, extraValue: 0))
                run -= 1
                while run >= 3 {
                    let chunk = min(run, 6)
                    result.append(CodeLengthToken(symbol: 16, extraBits: 2, extraValue: UInt8(chunk - 3)))
                    run -= chunk
                }
                while run > 0 {
                    result.append(CodeLengthToken(symbol: length, extraBits: 0, extraValue: 0))
                    run -= 1
                }
            }
        }
        return result
    }
}
