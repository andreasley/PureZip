import Foundation

// MARK: - Buffered sequential byte source

/// A buffered, strictly sequential byte source over a pull closure — no
/// seeking, no mapping. Supports a small push-back so the bit reader can
/// return read-ahead bytes it did not consume.
final class StreamByteSource {
    private let readChunk: () throws -> Data?
    private var buffer: [UInt8] = []
    private var offset = 0
    private var sawEOF = false
    /// Total bytes handed out so far (net of push-backs).
    private(set) var totalConsumed: UInt64 = 0

    init(readChunk: @escaping () throws -> Data?) {
        self.readChunk = readChunk
    }

    /// Tries to have `n` bytes buffered ahead; returns the count actually
    /// available (less than `n` only at the end of the stream).
    @discardableResult
    private func buffered(_ n: Int) throws -> Int {
        if buffer.count - offset >= n { return n }
        compactIfNeeded()
        while buffer.count - offset < n, !sawEOF {
            guard let chunk = try readChunk(), !chunk.isEmpty else {
                sawEOF = true
                break
            }
            buffer.append(contentsOf: chunk)
        }
        return buffer.count - offset
    }

    private func compactIfNeeded() {
        // Keep 8 bytes of history — the largest possible bit-reader push-back.
        if offset > 1 << 16 {
            buffer.removeFirst(offset - 8)
            offset = 8
        }
    }

    /// The next byte, or nil at the end of the stream.
    @inline(__always)
    func nextByte() throws -> UInt8? {
        if buffer.count - offset < 1, try buffered(1) < 1 { return nil }
        defer {
            offset += 1
            totalConsumed += 1
        }
        return buffer[offset]
    }

    /// Returns the last `count` consumed bytes to the stream. Only valid for
    /// bytes that are still buffered (≤ 8, guaranteed by `compactIfNeeded`).
    func pushBack(_ count: Int) {
        precondition(count <= offset, "push-back beyond buffered history")
        offset -= count
        totalConsumed -= UInt64(count)
    }

    /// Delivers exactly `count` bytes to `body` in one or more chunks,
    /// throwing `ZipError.truncatedData` if the stream ends first.
    func readExact(_ count: Int, into body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var remaining = count
        while remaining > 0 {
            let available = try buffered(min(remaining, 1 << 16))
            guard available > 0 else { throw ZipError.truncatedData }
            let take = min(remaining, available)
            try buffer.withUnsafeBytes { raw in
                try body(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + take]))
            }
            offset += take
            totalConsumed += UInt64(take)
            remaining -= take
        }
    }

    func readExactBytes(_ count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        try readExact(count) { result.append(contentsOf: $0) }
        return result
    }

    func skip(_ count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let want = Int(min(remaining, UInt64(1 << 16)))
            let available = try buffered(want)
            guard available > 0 else { throw ZipError.truncatedData }
            let take = min(want, available)
            offset += take
            totalConsumed += UInt64(take)
            remaining -= UInt64(take)
        }
    }

    func readLE16() throws -> UInt16 {
        let bytes = try readExactBytes(2)
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    func readLE32() throws -> UInt32 {
        let bytes = try readExactBytes(4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    func readLE64() throws -> UInt64 {
        var value: UInt64 = 0
        for (index, byte) in try readExactBytes(8).enumerated() {
            value |= UInt64(byte) << (8 * index)
        }
        return value
    }

    /// Peeks the next 4 bytes without consuming them; nil if fewer remain.
    func peekLE32() throws -> UInt32? {
        guard try buffered(4) >= 4 else { return nil }
        return UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }
}

// MARK: - Streaming bit reader

/// A DEFLATE bit reader that pulls its input incrementally from a
/// `StreamByteSource` instead of a complete buffer. Past the end of input it
/// serves zero bits and flags the over-read, mirroring `BitReader`.
struct StreamingBitReader: InflateBitSource {
    private let source: StreamByteSource
    private var bitBuffer: UInt64 = 0
    /// Valid (possibly zero-padded) bits in `bitBuffer`.
    private var bitCount = 0
    /// Real (non-padding) unconsumed bits in the accumulator; negative once
    /// the decoder consumed past the end of the stream.
    private var realBits = 0

    init(source: StreamByteSource) {
        self.source = source
    }

    var overran: Bool { realBits < 0 }

    mutating func refill() throws {
        while bitCount <= 56 {
            if let byte = try source.nextByte() {
                bitBuffer |= UInt64(byte) &<< UInt64(bitCount)
                realBits += 8
            }
            bitCount += 8
        }
    }

    @inline(__always)
    func peek(_ n: Int) -> Int {
        Int(bitBuffer & ((1 &<< UInt64(n)) &- 1))
    }

    @inline(__always)
    mutating func consume(_ n: Int) {
        bitBuffer &>>= UInt64(n)
        bitCount &-= n
        realBits &-= n
    }

    mutating func take(_ n: Int) throws -> Int {
        try refill()
        let value = peek(n)
        consume(n)
        if realBits < 0 { throw ZipError.truncatedData }
        return value
    }

    mutating func alignToByte() throws {
        guard realBits >= 0 else { throw ZipError.truncatedData }
        consume(realBits & 7)
    }

    mutating func readBytes(to destination: UnsafeMutablePointer<UInt8>, count n: Int) throws {
        var out = destination
        var need = n
        // Drain whole real bytes still sitting in the accumulator.
        while bitCount >= 8, realBits >= 8, need > 0 {
            out.pointee = UInt8(truncatingIfNeeded: bitBuffer)
            consume(8)
            out += 1
            need -= 1
        }
        guard realBits >= 0 else { throw ZipError.truncatedData }
        if need == 0 { return }
        // Only zero padding may remain (real bits are whole bytes here, and
        // whole bytes were drained above); discard it and read directly.
        bitBuffer = 0
        bitCount = 0
        realBits = 0
        try source.readExact(need) { chunk in
            memcpy(out, chunk.baseAddress!, chunk.count)
            out += chunk.count
        }
    }

    /// Ends the DEFLATE stream: aligns to the byte boundary and returns the
    /// buffered read-ahead (at most 7 whole bytes) to the source.
    mutating func finish() throws {
        try alignToByte()
        let wholeBytes = realBits >> 3
        if wholeBytes > 0 { source.pushBack(wholeBytes) }
        bitBuffer = 0
        bitCount = 0
        realBits = 0
    }
}

// MARK: - Streaming ZIP reader

/// Reads a ZIP archive strictly sequentially from a stream of bytes — a
/// pipe, socket, or network download — without seeking and without mapping
/// the archive into memory.
///
/// Entries are yielded in archive order by parsing the local file headers as
/// bytes arrive. Entries whose sizes were unknown to the producer
/// (data-descriptor entries, the norm for streamed ZIP output) are supported
/// for DEFLATE by detecting the end of the compressed stream. Every entry is
/// verified against its CRC-32 checksum and sizes, and `ZipSecurityLimits`
/// apply.
///
/// ```swift
/// let reader = ZipStreamReader(fileHandle: pipe.fileHandleForReading)
/// while let entry = try reader.nextEntry() {
///     guard !entry.isDirectory else { continue }
///     try reader.readEntry { chunk in output.write(chunk) }
/// }
/// ```
///
/// Limitations compared to `ZipArchive` (which reads the authoritative
/// central directory at the end of the file): metadata that exists only
/// there — POSIX permissions and symbolic-link flags — is unavailable, so
/// symlink entries appear as regular files whose contents are the target
/// path. Entry paths are reported as stored; callers extracting to disk
/// must sanitize them. Stored (uncompressed) entries with data descriptors
/// cannot be streamed, because nothing marks where their data ends.
///
/// The reader becomes unusable after any error.
public final class ZipStreamReader {
    /// Metadata of one streamed entry, from its local file header.
    public struct Entry: Sendable {
        /// The path stored in the archive — not sanitized; never extract to
        /// disk without validating it.
        public let path: String
        /// True if the entry represents a directory (trailing `/`).
        public let isDirectory: Bool
        /// The entry's compression method.
        public let compressionMethod: ZipCompressionMethod
        /// Modification date from the entry's DOS timestamp.
        public let modificationDate: Date?
        /// The declared uncompressed size, or nil for data-descriptor
        /// entries, whose size is only known once the entry has been read.
        public let declaredUncompressedSize: UInt64?
    }

    private struct PendingEntry {
        let path: String
        let isDirectory: Bool
        let method: ZipCompressionMethod
        let hasDescriptor: Bool
        let isZip64: Bool
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
    }

    private enum State {
        case atHeader
        case inEntry(PendingEntry)
        case finished
        case failed
    }

    private let source: StreamByteSource
    private let limits: ZipSecurityLimits
    private let legacyNameEncoding: String.Encoding?
    private var state: State = .atHeader
    private var entryCount = 0
    private var totalUncompressed: UInt64 = 0

    /// Creates a reader over a pull closure that returns the next chunk of
    /// the raw archive bytes, or nil (or empty) at the end of the stream.
    ///
    /// See `ZipArchive.init(url:limits:legacyNameEncoding:)` for the meaning
    /// of `legacyNameEncoding`.
    public init(
        limits: ZipSecurityLimits = .default,
        legacyNameEncoding: String.Encoding? = nil,
        readChunk: @escaping () throws -> Data?
    ) {
        self.source = StreamByteSource(readChunk: readChunk)
        self.limits = limits
        self.legacyNameEncoding = legacyNameEncoding
    }

    /// Creates a reader over a file handle — a pipe, socket, or open file —
    /// that is read strictly sequentially.
    public convenience init(
        fileHandle: FileHandle,
        limits: ZipSecurityLimits = .default,
        legacyNameEncoding: String.Encoding? = nil
    ) {
        self.init(limits: limits, legacyNameEncoding: legacyNameEncoding) {
            try fileHandle.read(upToCount: 1 << 16)
        }
    }

    // MARK: - Iteration

    /// Advances to the next entry, skipping the previous entry's data if it
    /// was not read. Returns nil once the central directory is reached (the
    /// end of the entry data).
    public func nextEntry() throws -> Entry? {
        switch state {
        case .failed:
            throw ZipError.invalidState("the reader is unusable after a previous error")
        case .finished:
            return nil
        case .inEntry(let pending):
            try skip(pending)
        case .atHeader:
            break
        }
        do {
            return try parseNextHeader()
        } catch {
            state = .failed
            throw error
        }
    }

    /// Streams the current entry's decompressed contents, verifying the
    /// CRC-32 checksum and sizes (from the header, or from the trailing data
    /// descriptor for entries that carry one). Callable once per entry.
    @discardableResult
    public func readEntry(
        chunkHandler: (Data) throws -> Void
    ) throws -> (uncompressedSize: UInt64, crc32: UInt32) {
        guard case .inEntry(let pending) = state else {
            throw ZipError.invalidState("no entry is available to read")
        }
        do {
            let result = try readPending(pending, chunkHandler: chunkHandler)
            state = .atHeader
            return result
        } catch {
            state = .failed
            throw error
        }
    }

    /// Reads the current entry's decompressed contents into memory.
    public func readEntryData() throws -> Data {
        var data = Data()
        try readEntry { data.append($0) }
        return data
    }

    // MARK: - Header parsing

    private func parseNextHeader() throws -> Entry? {
        guard let signature = try source.peekLE32() else {
            // The stream must end with a central directory; a bare EOF means
            // the archive was cut off.
            throw ZipError.truncatedData
        }
        switch signature {
        case 0x0403_4B50:
            try source.skip(4)
        case 0x0201_4B50, 0x0605_4B50, 0x0606_4B50:
            // Central directory (or end record): no more entry data. The
            // remainder of the stream is deliberately left unread.
            state = .finished
            return nil
        default:
            throw ZipError.corruptedData("invalid local file header")
        }

        entryCount += 1
        guard entryCount <= limits.maxEntryCount else {
            throw ZipError.limitExceeded(
                "archive contains more than \(limits.maxEntryCount) entries"
            )
        }

        _ = try source.readLE16() // version needed to extract
        let flags = try source.readLE16()
        let methodRaw = try source.readLE16()
        let dosTime = try source.readLE16()
        let dosDate = try source.readLE16()
        let crc = try source.readLE32()
        var compressedSize = UInt64(try source.readLE32())
        var uncompressedSize = UInt64(try source.readLE32())
        let nameLength = Int(try source.readLE16())
        let extraLength = Int(try source.readLE16())
        let nameBytes = try source.readExactBytes(nameLength)
        let extra = try source.readExactBytes(extraLength)

        guard flags & 0x0001 == 0, flags & 0x0040 == 0 else {
            throw ZipError.encryptedEntryUnsupported(String(decoding: nameBytes, as: UTF8.self))
        }
        guard let method = ZipCompressionMethod(rawValue: methodRaw) else {
            throw ZipError.unsupportedCompressionMethod(methodRaw)
        }
        let hasDescriptor = flags & 0x0008 != 0

        // Parse the extra fields we understand: ZIP64 sizes and Unicode Path.
        var isZip64 = false
        var unicodePathName: String?
        var cursor = 0
        while cursor + 4 <= extra.count {
            let fieldID = UInt16(extra[cursor]) | UInt16(extra[cursor + 1]) << 8
            let fieldSize = Int(UInt16(extra[cursor + 2]) | UInt16(extra[cursor + 3]) << 8)
            let fieldStart = cursor + 4
            guard fieldStart + fieldSize <= extra.count else {
                throw ZipError.corruptedData("invalid extra field")
            }
            switch fieldID {
            case 0x0001:
                isZip64 = true
                var position = fieldStart
                func nextU64() -> UInt64? {
                    guard position + 8 <= fieldStart + fieldSize else { return nil }
                    var value: UInt64 = 0
                    for i in 0..<8 { value |= UInt64(extra[position + i]) << (8 * i) }
                    position += 8
                    return value
                }
                if uncompressedSize == 0xFFFF_FFFF, let value = nextU64() {
                    uncompressedSize = value
                }
                if compressedSize == 0xFFFF_FFFF, let value = nextU64() {
                    compressedSize = value
                }
            case 0x7075:
                if fieldSize >= 5, extra[fieldStart] == 1 {
                    let recordedCRC = UInt32(extra[fieldStart + 1])
                        | UInt32(extra[fieldStart + 2]) << 8
                        | UInt32(extra[fieldStart + 3]) << 16
                        | UInt32(extra[fieldStart + 4]) << 24
                    if recordedCRC == CRC32.checksum(nameBytes) {
                        unicodePathName = String(
                            bytes: extra[(fieldStart + 5)..<(fieldStart + fieldSize)],
                            encoding: .utf8
                        )
                    }
                }
            default:
                break
            }
            cursor = fieldStart + fieldSize
        }

        // Decode the entry name with the same precedence as `ZipArchive`.
        let path: String
        if let unicodePathName {
            path = unicodePathName
        } else if flags & 0x0800 != 0 {
            path = String(decoding: nameBytes, as: UTF8.self)
        } else if let utf8Path = String(bytes: nameBytes, encoding: .utf8) {
            path = utf8Path
        } else if let legacyNameEncoding,
                  let legacyPath = String(bytes: nameBytes, encoding: legacyNameEncoding) {
            path = legacyPath
        } else {
            path = CP437.decode(nameBytes)
        }
        let isDirectory = path.hasSuffix("/")

        if hasDescriptor, method == .store {
            throw ZipError.unsupportedFeature(
                "stored entry with a data descriptor cannot be streamed"
            )
        }
        if !hasDescriptor, method == .store, compressedSize != uncompressedSize {
            throw ZipError.corruptedData("stored entry with mismatched sizes")
        }

        state = .inEntry(PendingEntry(
            path: path, isDirectory: isDirectory, method: method,
            hasDescriptor: hasDescriptor, isZip64: isZip64, crc32: crc,
            compressedSize: compressedSize, uncompressedSize: uncompressedSize
        ))
        return Entry(
            path: path,
            isDirectory: isDirectory,
            compressionMethod: method,
            modificationDate: DOSDate.date(dosTime: dosTime, dosDate: dosDate),
            declaredUncompressedSize: hasDescriptor ? nil : uncompressedSize
        )
    }

    // MARK: - Entry data

    private func skip(_ pending: PendingEntry) throws {
        do {
            if pending.hasDescriptor {
                // The data's extent is only discoverable by decompressing.
                _ = try readPending(pending) { _ in }
            } else {
                try source.skip(pending.compressedSize)
            }
            state = .atHeader
        } catch {
            state = .failed
            throw error
        }
    }

    private func readPending(
        _ pending: PendingEntry, chunkHandler: (Data) throws -> Void
    ) throws -> (uncompressedSize: UInt64, crc32: UInt32) {
        let entryCap: UInt64
        if pending.hasDescriptor {
            entryCap = limits.maxUncompressedEntrySize
        } else {
            guard pending.uncompressedSize <= limits.maxUncompressedEntrySize else {
                throw ZipError.limitExceeded(
                    "entry '\(pending.path)' declares \(pending.uncompressedSize) bytes "
                        + "(limit \(limits.maxUncompressedEntrySize))"
                )
            }
            entryCap = pending.uncompressedSize
        }

        var crc: UInt32 = 0
        var produced: UInt64 = 0
        let emit: (UnsafeRawBufferPointer) throws -> Void = { [self] chunk in
            guard let base = chunk.baseAddress, !chunk.isEmpty else { return }
            let count = UInt64(chunk.count)
            guard produced + count <= entryCap else {
                if pending.hasDescriptor {
                    throw ZipError.limitExceeded(
                        "entry '\(pending.path)' exceeds \(entryCap) bytes"
                    )
                }
                throw ZipError.corruptedData("decompressed data exceeds declared size")
            }
            guard totalUncompressed + produced + count <= limits.maxTotalUncompressedSize else {
                throw ZipError.limitExceeded(
                    "total uncompressed size exceeds limit of "
                        + "\(limits.maxTotalUncompressedSize) bytes"
                )
            }
            crc = CRC32.checksum(chunk, seed: crc)
            produced += count
            try chunkHandler(Data(bytes: base, count: chunk.count))
        }

        switch pending.method {
        case .store:
            var remaining = pending.compressedSize
            while remaining > 0 {
                let take = Int(min(remaining, UInt64(1 << 19)))
                try source.readExact(take, into: emit)
                remaining -= UInt64(take)
            }
        case .deflate:
            let consumedBefore = source.totalConsumed
            try Inflate.decompress(from: source, chunkHandler: emit)
            let consumed = source.totalConsumed - consumedBefore
            if pending.hasDescriptor {
                try readDataDescriptor(pending, produced: produced, consumed: consumed, crc: crc)
            } else {
                guard consumed == pending.compressedSize else {
                    throw ZipError.corruptedData("compressed size does not match declared size")
                }
            }
        }

        if !pending.hasDescriptor {
            guard produced == pending.uncompressedSize else {
                throw ZipError.corruptedData("decompressed size does not match declared size")
            }
            guard crc == pending.crc32 else {
                throw ZipError.checksumMismatch(pending.path)
            }
        }
        totalUncompressed += produced
        return (produced, crc)
    }

    private func readDataDescriptor(
        _ pending: PendingEntry, produced: UInt64, consumed: UInt64, crc: UInt32
    ) throws {
        // The descriptor's leading signature is optional.
        var first = try source.readLE32()
        if first == 0x0807_4B50 {
            first = try source.readLE32()
        }
        let descriptorCRC = first
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        if pending.isZip64 {
            compressedSize = try source.readLE64()
            uncompressedSize = try source.readLE64()
        } else {
            compressedSize = UInt64(try source.readLE32())
            uncompressedSize = UInt64(try source.readLE32())
        }
        guard descriptorCRC == crc else {
            throw ZipError.checksumMismatch(pending.path)
        }
        guard compressedSize == consumed, uncompressedSize == produced else {
            throw ZipError.corruptedData("data descriptor does not match streamed entry")
        }
    }
}
