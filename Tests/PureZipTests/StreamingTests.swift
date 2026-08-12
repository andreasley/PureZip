import Foundation
import Testing
@testable import PureZip

@Suite("Streaming compression and extraction")
struct StreamingTests {
    @Test func fileWriterRoundTripWithStreamedEntries() throws {
        try withTemporaryDirectory { directory in
            let bigFile = directory.appendingPathComponent("big.bin")
            let bigData = mixedData(count: 6_000_000, seed: 101)
            try bigData.write(to: bigFile)

            let archiveURL = directory.appendingPathComponent("streamed.zip")
            let writer = try ZipFileWriter(url: archiveURL)
            try writer.addDirectory(path: "földer")
            // Streamed from disk (known size).
            try writer.addFile(path: "földer/big.bin", contentsOf: bigFile)
            // In-memory convenience entry.
            try writer.addFile(path: "small.txt", data: Data("hello streaming".utf8))
            // Push-style entry with unknown size (exercises the ZIP64 placeholder path).
            var generator = SeededGenerator(seed: 202)
            var pushed = Data()
            try writer.addFile(path: "pushed.bin") { stream in
                for _ in 0..<300 {
                    let chunk = randomData(count: Int(generator.next() % 4096) + 1, seed: generator.next())
                    pushed.append(chunk)
                    try stream.write(chunk)
                }
            }
            // Stored (uncompressed) streamed entry.
            try writer.addFile(path: "stored.bin", compress: false) { stream in
                try stream.write(Data(repeating: 7, count: 100_000))
            }
            // Empty streamed entry.
            try writer.addFile(path: "empty.bin") { _ in }
            try writer.finalize()

            let archive = try ZipArchive(url: archiveURL)
            #expect(try archive.extractData(at: "földer/big.bin") == bigData)
            #expect(try archive.extractData(at: "pushed.bin") == pushed)
            #expect(try archive.extractData(at: "stored.bin") == Data(repeating: 7, count: 100_000))
            #expect(try archive.extractData(at: "empty.bin") == Data())
            let storedEntry = try #require(archive["stored.bin"])
            #expect(storedEntry.compressionMethod == .store)
            #expect(storedEntry.compressedSize == storedEntry.uncompressedSize)
            let bigEntry = try #require(archive["földer/big.bin"])
            #expect(bigEntry.compressedSize < bigEntry.uncompressedSize / 2,
                    "mixed data should compress well when streamed")

            #if os(macOS)
            // Info-ZIP must accept the patched headers and ZIP64 placeholders.
            if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-t", archiveURL.path]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "unzip -t should verify the streamed archive")
            }
            #endif
        }
    }

    @Test func streamingExtractionDeliversChunks() throws {
        let payload = mixedData(count: 5_000_000, seed: 55)
        let writer = ZipWriter()
        try writer.addFile(path: "big.bin", data: payload)
        let archive = try ZipArchive(data: writer.finalize())
        let entry = try #require(archive["big.bin"])

        var collected = Data()
        var chunkCount = 0
        try archive.extract(entry) { chunk in
            collected.append(chunk)
            chunkCount += 1
        }
        #expect(collected == payload)
        #expect(chunkCount > 1, "5 MB should arrive in multiple chunks")
    }

    @Test func streamingExtractionOfStoredEntries() throws {
        let payload = randomData(count: 2_000_000, seed: 77)
        let writer = ZipWriter()
        try writer.addFile(path: "noise.bin", data: payload) // random data → stored
        let archive = try ZipArchive(data: writer.finalize())
        let entry = try #require(archive["noise.bin"])
        #expect(entry.compressionMethod == .store)

        var collected = Data()
        try archive.extract(entry) { collected.append($0) }
        #expect(collected == payload)
    }

    @Test func extractToFileStreamsAndVerifies() async throws {
        try await withTemporaryDirectory { directory in
            let payload = mixedData(count: 2_000_000, seed: 66)
            let writer = ZipWriter()
            try writer.addFile(path: "data.bin", data: payload, permissions: 0o600)
            let archive = try ZipArchive(data: writer.finalize())
            let entry = try #require(archive["data.bin"])

            let target = directory.appendingPathComponent("data.bin")
            let log = ProgressLog()
            try await archive.extract(entry, to: target) { log.append($0) }
            #expect(try Data(contentsOf: target) == payload)
            #expect(log.snapshots.last?.completedBytes == UInt64(payload.count))
            #expect(log.snapshots.last?.fraction == 1)

            await #expect(throws: ZipError.destinationExists(target.path)) {
                try await archive.extract(entry, to: target)
            }
            try await archive.extract(entry, to: target, overwrite: true)
        }
    }

    @Test func corruptEntryLeavesNoPartialFile() async throws {
        try await withTemporaryDirectory { directory in
            let payload = mixedData(count: 500_000, seed: 33)
            var entry = RawZipEntry(name: "bad.bin")
            entry.method = 8
            entry.compressedData = Deflate.compress(payload)
            entry.uncompressedSize = UInt32(payload.count)
            entry.crc = CRC32.checksum(payload) &+ 1 // wrong on purpose
            let archive = try ZipArchive(data: buildRawZip([entry]))

            let target = directory.appendingPathComponent("bad.bin")
            await #expect(throws: ZipError.checksumMismatch("bad.bin")) {
                try await archive.extract(archive.entries[0], to: target)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path),
                    "a failed extraction must not leave a partial file")
        }
    }

    @Test func matchesSpanStreamedChunkBoundaries() throws {
        // The same 10 KB block pushed in separate writes: the encoder's sliding
        // window must find cross-chunk matches for this to compress well.
        let block = randomData(count: 10_000, seed: 88)
        var expected = Data()
        for _ in 0..<60 { expected.append(block) }

        try withTemporaryDirectory { directory in
            let archiveURL = directory.appendingPathComponent("repeats.zip")
            let writer = try ZipFileWriter(url: archiveURL)
            try writer.addFile(path: "repeats.bin", expectedSize: UInt64(expected.count)) { stream in
                for _ in 0..<60 { try stream.write(block) }
            }
            try writer.finalize()

            let archive = try ZipArchive(url: archiveURL)
            let entry = try #require(archive["repeats.bin"])
            #expect(entry.compressedSize < UInt64(block.count * 3),
                    "repeated blocks must compress via matches that cross chunk boundaries")

            var collected = Data()
            try archive.extract(entry) { collected.append($0) }
            #expect(collected == expected)
        }
    }

    @Test("Chunked encoder round trip", arguments: [1_000, 100_000, 1_500_000])
    func encoderChunkedRoundTrip(size: Int) throws {
        // Feed the encoder deterministic random-sized chunks; sizes above the
        // slide threshold exercise window sliding and hash-chain rebasing.
        let original = mixedData(count: size, seed: UInt64(size))
        var generator = SeededGenerator(seed: 999)
        let encoder = DeflateEncoder(level: .normal)
        original.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let chunkSize = min(Int(generator.next() % 50_000) + 1, raw.count - offset)
                encoder.write(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + chunkSize]))
                offset += chunkSize
            }
        }
        encoder.finish()
        let compressed = encoder.takeOutput()
        let decompressed = try compressed.withUnsafeBytes {
            try Inflate.decompress($0, expectedSize: original.count)
        }
        #expect(decompressed == original)
    }

    @Test func streamingInflateMatchesOneShot() throws {
        let original = mixedData(count: 3_000_000, seed: 44)
        let compressed = Deflate.compress(original)
        var streamed = Data()
        try compressed.withUnsafeBytes { raw in
            try Inflate.decompress(raw, expectedSize: UInt64(original.count)) { chunk in
                streamed.append(contentsOf: chunk)
            }
        }
        #expect(streamed == original)
    }

    @Test func writerBecomesUnusableAfterEntryError() throws {
        struct Boom: Error {}
        try withTemporaryDirectory { directory in
            let writer = try ZipFileWriter(url: directory.appendingPathComponent("x.zip"))
            #expect(throws: Boom.self) {
                try writer.addFile(path: "a.bin") { _ in throw Boom() }
            }
            #expect(throws: ZipError.self) {
                try writer.addFile(path: "b.txt", data: Data([1]))
            }
            #expect(throws: ZipError.self) { try writer.finalize() }
        }
    }
}
