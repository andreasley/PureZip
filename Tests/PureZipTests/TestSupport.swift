import Foundation
@testable import PureZip

// MARK: - Deterministic random data

/// SplitMix64 — a tiny deterministic PRNG so tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomData(count: Int, seed: UInt64) -> Data {
    var generator = SeededGenerator(seed: seed)
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    while bytes.count + 8 <= count {
        withUnsafeBytes(of: generator.next().littleEndian) { bytes.append(contentsOf: $0) }
    }
    while bytes.count < count {
        bytes.append(UInt8(truncatingIfNeeded: generator.next()))
    }
    return Data(bytes)
}

/// A mix of compressible runs, text, and random noise — exercises literals,
/// short/long matches, and stored-block fallbacks all at once.
func mixedData(count: Int, seed: UInt64) -> Data {
    var generator = SeededGenerator(seed: seed)
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    let phrase = [UInt8]("Pack my box with five dozen liquor jugs. ".utf8)
    while bytes.count < count {
        switch generator.next() % 4 {
        case 0: // run of a single byte
            let run = Int(generator.next() % 512) + 1
            bytes.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: generator.next()), count: run))
        case 1: // repeated text
            for _ in 0..<(generator.next() % 8 + 1) { bytes.append(contentsOf: phrase) }
        case 2: // random noise
            for _ in 0..<(generator.next() % 256 + 1) {
                bytes.append(UInt8(truncatingIfNeeded: generator.next()))
            }
        default: // self-referencing copy from earlier output
            if bytes.count > 16 {
                let length = Int(generator.next() % 300) + 4
                let start = Int(generator.next() % UInt64(bytes.count - 8))
                let slice = Array(bytes[start..<min(start + length, bytes.count)])
                bytes.append(contentsOf: slice)
            } else {
                bytes.append(0x42)
            }
        }
    }
    bytes.removeLast(bytes.count - count)
    return Data(bytes)
}

// MARK: - Raw archive builder

/// Hand-assembles ZIP bytes without going through `ZipWriter`, so tests can
/// produce hostile archives (traversal paths, lying sizes, bad CRCs, symlinks,
/// encrypted flags) that the writer would refuse to create.
struct RawZipEntry {
    var nameBytes: [UInt8]
    var flags: UInt16 = 0
    var method: UInt16 = 0
    var crc: UInt32 = 0
    var compressedData: [UInt8] = []
    var uncompressedSize: UInt32 = 0
    var versionMadeBy: UInt16 = (3 << 8) | 20 // Unix
    var externalAttributes: UInt32 = 0o100644 << 16

    init(name: String) {
        self.nameBytes = [UInt8](name.utf8)
    }

    init(nameBytes: [UInt8]) {
        self.nameBytes = nameBytes
    }

    /// A stored (uncompressed) entry with a correct CRC.
    static func stored(name: String, content: [UInt8]) -> RawZipEntry {
        stored(nameBytes: [UInt8](name.utf8), content: content)
    }

    static func stored(nameBytes: [UInt8], content: [UInt8]) -> RawZipEntry {
        var entry = RawZipEntry(nameBytes: nameBytes)
        entry.method = 0
        entry.compressedData = content
        entry.uncompressedSize = UInt32(content.count)
        entry.crc = CRC32.checksum(content)
        return entry
    }
}

func buildRawZip(_ entries: [RawZipEntry]) -> Data {
    var output: [UInt8] = []
    var localOffsets: [UInt32] = []

    for entry in entries {
        localOffsets.append(UInt32(output.count))
        output.appendLE32(0x0403_4B50)
        output.appendLE16(20)
        output.appendLE16(entry.flags)
        output.appendLE16(entry.method)
        output.appendLE16(0) // time
        output.appendLE16(0x21) // date (1980-01-01)
        output.appendLE32(entry.crc)
        output.appendLE32(UInt32(entry.compressedData.count))
        output.appendLE32(entry.uncompressedSize)
        output.appendLE16(UInt16(entry.nameBytes.count))
        output.appendLE16(0)
        output.append(contentsOf: entry.nameBytes)
        output.append(contentsOf: entry.compressedData)
    }

    let centralOffset = UInt32(output.count)
    for (index, entry) in entries.enumerated() {
        output.appendLE32(0x0201_4B50)
        output.appendLE16(entry.versionMadeBy)
        output.appendLE16(20)
        output.appendLE16(entry.flags)
        output.appendLE16(entry.method)
        output.appendLE16(0)
        output.appendLE16(0x21)
        output.appendLE32(entry.crc)
        output.appendLE32(UInt32(entry.compressedData.count))
        output.appendLE32(entry.uncompressedSize)
        output.appendLE16(UInt16(entry.nameBytes.count))
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE32(entry.externalAttributes)
        output.appendLE32(localOffsets[index])
        output.append(contentsOf: entry.nameBytes)
    }
    let centralSize = UInt32(output.count) - centralOffset

    output.appendLE32(0x0605_4B50)
    output.appendLE16(0)
    output.appendLE16(0)
    output.appendLE16(UInt16(entries.count))
    output.appendLE16(UInt16(entries.count))
    output.appendLE32(centralSize)
    output.appendLE32(centralOffset)
    output.appendLE16(0)

    return Data(output)
}

// MARK: - Temporary directories

/// Creates a unique temporary directory, runs `body` with it, and cleans up.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PureZipTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
