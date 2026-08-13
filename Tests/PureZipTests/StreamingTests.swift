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
            try await writer.addFile(path: "data.bin", data: payload, permissions: 0o600)
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

    @Test func asyncFileWriterReportsProgressAndRoundTrips() async throws {
        try await withTemporaryDirectory { directory in
            let bigFile = directory.appendingPathComponent("big.bin")
            let bigData = mixedData(count: 2_000_000, seed: 301)
            try bigData.write(to: bigFile)

            let archiveURL = directory.appendingPathComponent("async.zip")
            let writer = try ZipFileWriter(url: archiveURL)

            // Streamed from disk: per-chunk progress with the file size as total.
            let fileLog = ProgressLog()
            try await writer.addFile(path: "big.bin", contentsOf: bigFile) { fileLog.append($0) }
            let fileSnapshots = fileLog.snapshots
            #expect(fileSnapshots.count > 1, "multi-chunk input should report more than once")
            #expect(fileSnapshots.allSatisfy { $0.totalBytes == UInt64(bigData.count) })
            let fileCompleted = fileSnapshots.map(\.completedBytes)
            #expect(fileCompleted == fileCompleted.sorted(), "progress must be monotonic")
            #expect(fileSnapshots.last?.fraction == 1)

            // In-memory entry: the store fallback must survive the async path.
            let noise = randomData(count: 800_000, seed: 302)
            let dataLog = ProgressLog()
            try await writer.addFile(path: "noise.bin", data: noise) { dataLog.append($0) }
            #expect(dataLog.snapshots.last?.completedBytes == UInt64(noise.count))

            // Push-style entry with an async content closure.
            let chunks = (0..<5).map { mixedData(count: 100_000, seed: UInt64(400 + $0)) }
            let pushed = chunks.reduce(Data(), +)
            let pushLog = ProgressLog()
            try await writer.addFile(
                path: "pushed.bin",
                expectedSize: UInt64(pushed.count),
                progress: { pushLog.append($0) }
            ) { stream in
                for chunk in chunks {
                    try stream.write(chunk)
                }
            }
            #expect(pushLog.snapshots.last?.completedBytes == UInt64(pushed.count))
            #expect(pushLog.snapshots.last?.fraction == 1)

            try writer.finalize()

            let archive = try ZipArchive(url: archiveURL)
            #expect(try archive.extractData(at: "big.bin") == bigData)
            #expect(try archive.extractData(at: "noise.bin") == noise)
            #expect(try #require(archive["noise.bin"]).compressionMethod == .store,
                    "incompressible data must still fall back to Store")
            #expect(try archive.extractData(at: "pushed.bin") == pushed)
        }
    }

    @Test func asyncZipWriterReportsProgressAndRoundTrips() async throws {
        let writer = ZipWriter()
        let payload = mixedData(count: 1_500_000, seed: 303)
        let log = ProgressLog()
        try await writer.addFile(path: "data.bin", data: payload) { log.append($0) }
        #expect(log.snapshots.count > 1)
        #expect(log.snapshots.last?.fraction == 1)

        let archive = try ZipArchive(data: writer.finalize())
        #expect(try archive.extractData(at: "data.bin") == payload)
    }

    @Test func cancelledStreamedEntryFailsWriter() async throws {
        try await withTemporaryDirectory { directory in
            let bigFile = directory.appendingPathComponent("big.bin")
            try mixedData(count: 3_000_000, seed: 304).write(to: bigFile)
            let archiveURL = directory.appendingPathComponent("cancelled.zip")

            // Runs in a child task so cancelling doesn't poison the test's own task.
            let outcome = await Task { () -> String in
                guard let writer = try? ZipFileWriter(url: archiveURL) else { return "setup failed" }
                do {
                    // Cancel ourselves after the first progress report; the
                    // next chunk's cancellation check must throw.
                    try await writer.addFile(path: "big.bin", contentsOf: bigFile) { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return "not cancelled"
                } catch is CancellationError {
                    // A cancelled entry leaves a half-written stream, so the
                    // writer must refuse further use.
                    do {
                        try writer.finalize()
                        return "writer still usable"
                    } catch is ZipError {
                        return "cancelled and unusable"
                    } catch {
                        return "unexpected error"
                    }
                } catch {
                    return "unexpected error"
                }
            }.value
            #expect(outcome == "cancelled and unusable")
        }
    }

    @Test func cancelledInMemoryEntryLeavesWriterUnchanged() async throws {
        let outcome = await Task { () -> String in
            let writer = ZipWriter()
            let payload = mixedData(count: 3_000_000, seed: 305)
            do {
                try await writer.addFile(path: "big.bin", data: payload) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return "not cancelled"
            } catch is CancellationError {
                // Cancellation happens before anything is written.
                return "cancelled, \(writer.count) bytes written"
            } catch {
                return "unexpected error"
            }
        }.value
        #expect(outcome == "cancelled, 0 bytes written")
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

// MARK: - Streaming input

@Suite("Streaming input")
struct StreamInputTests {
    /// A pull closure that serves `bytes` in fixed-size chunks.
    private func chunkedSource(_ bytes: [UInt8], chunkSize: Int) -> () throws -> Data? {
        var offset = 0
        return {
            guard offset < bytes.count else { return nil }
            let end = min(offset + chunkSize, bytes.count)
            defer { offset = end }
            return Data(bytes[offset..<end])
        }
    }

    /// A local-header entry with a data descriptor, as streamed producers
    /// write them (sizes unknown at header time).
    private func descriptorEntryBytes(
        name: String, payload: Data, withSignature: Bool
    ) -> [UInt8] {
        let compressed = Deflate.compress(payload)
        var out: [UInt8] = []
        out.appendLE32(0x0403_4B50)
        out.appendLE16(20)
        out.appendLE16(0x0008) // sizes follow in a data descriptor
        out.appendLE16(8) // deflate
        out.appendLE16(0)
        out.appendLE16(0x21)
        out.appendLE32(0) // crc unknown
        out.appendLE32(0) // compressed size unknown
        out.appendLE32(0) // uncompressed size unknown
        out.appendLE16(name.utf8.count)
        out.appendLE16(0)
        out.append(contentsOf: [UInt8](name.utf8))
        out.append(contentsOf: compressed)
        if withSignature { out.appendLE32(0x0807_4B50) }
        out.appendLE32(CRC32.checksum(payload))
        out.appendLE32(UInt32(compressed.count))
        out.appendLE32(UInt32(payload.count))
        return out
    }

    /// A plain local-header entry with known sizes (no data descriptor).
    private func plainEntryBytes(name: String, payload: Data) -> [UInt8] {
        let compressed = Deflate.compress(payload)
        var out: [UInt8] = []
        out.appendLE32(0x0403_4B50)
        out.appendLE16(20)
        out.appendLE16(0)
        out.appendLE16(8) // deflate
        out.appendLE16(0)
        out.appendLE16(0x21)
        out.appendLE32(CRC32.checksum(payload))
        out.appendLE32(UInt32(compressed.count))
        out.appendLE32(UInt32(payload.count))
        out.appendLE16(name.utf8.count)
        out.appendLE16(0)
        out.append(contentsOf: [UInt8](name.utf8))
        out.append(contentsOf: compressed)
        return out
    }

    /// Marks the end of the entry data (start of the central directory).
    private let centralDirectoryMarker: [UInt8] = [0x50, 0x4B, 0x01, 0x02]

    @Test func roundTripFromChunkedStream() throws {
        let writer = ZipWriter()
        let text = Data(String(repeating: "streaming input ", count: 20_000).utf8)
        let noise = randomData(count: 300_000, seed: 401)
        try writer.addDirectory(path: "docs")
        try writer.addFile(path: "docs/tëxt.txt", data: text)
        try writer.addFile(path: "noise.bin", data: noise) // stored
        try writer.addFile(path: "empty.dat", data: Data())
        let bytes = [UInt8](writer.finalize())

        // Tiny chunks stress the buffering across every header boundary.
        let reader = ZipStreamReader(readChunk: chunkedSource(bytes, chunkSize: 7))

        let directory = try #require(try reader.nextEntry())
        #expect(directory.path == "docs/")
        #expect(directory.isDirectory)

        let textEntry = try #require(try reader.nextEntry())
        #expect(textEntry.path == "docs/tëxt.txt")
        #expect(textEntry.declaredUncompressedSize == UInt64(text.count))
        #expect(textEntry.compressionMethod == .deflate)
        var collected = Data()
        var chunkCount = 0
        let summary = try reader.readEntry { chunk in
            collected.append(chunk)
            chunkCount += 1
        }
        #expect(collected == text)
        #expect(chunkCount > 1, "large entries should arrive in multiple chunks")
        #expect(summary.uncompressedSize == UInt64(text.count))
        #expect(summary.crc32 == CRC32.checksum(text))

        let noiseEntry = try #require(try reader.nextEntry())
        #expect(noiseEntry.compressionMethod == .store)
        #expect(try reader.readEntryData() == noise)

        let empty = try #require(try reader.nextEntry())
        #expect(empty.path == "empty.dat")
        #expect(try reader.readEntryData() == Data())

        #expect(try reader.nextEntry() == nil)
        #expect(try reader.nextEntry() == nil, "the reader stays finished")
    }

    @Test func dataDescriptorEntriesAreStreamed() throws {
        let first = mixedData(count: 200_000, seed: 402)
        let second = Data("small descriptor entry".utf8)
        var bytes = descriptorEntryBytes(name: "first.bin", payload: first, withSignature: true)
        bytes += descriptorEntryBytes(name: "second.txt", payload: second, withSignature: false)
        bytes += centralDirectoryMarker

        let reader = ZipStreamReader(readChunk: chunkedSource(bytes, chunkSize: 1013))

        let firstEntry = try #require(try reader.nextEntry())
        #expect(firstEntry.path == "first.bin")
        #expect(firstEntry.declaredUncompressedSize == nil, "size is unknown until read")
        #expect(try reader.readEntryData() == first)

        let secondEntry = try #require(try reader.nextEntry())
        #expect(secondEntry.path == "second.txt")
        #expect(try reader.readEntryData() == second)

        #expect(try reader.nextEntry() == nil)
    }

    @Test func skippingUnreadEntriesWorks() throws {
        let skippedPlain = mixedData(count: 100_000, seed: 403)
        let skippedDescriptor = mixedData(count: 100_000, seed: 404)
        let wanted = Data("the one we want".utf8)

        var bytes = plainEntryBytes(name: "skip-plain.bin", payload: skippedPlain)
        bytes += descriptorEntryBytes(name: "skip-desc.bin", payload: skippedDescriptor, withSignature: true)
        bytes += descriptorEntryBytes(name: "wanted.txt", payload: wanted, withSignature: true)
        bytes += centralDirectoryMarker

        let reader = ZipStreamReader(readChunk: chunkedSource(bytes, chunkSize: 4096))
        #expect(try reader.nextEntry()?.path == "skip-plain.bin")
        #expect(try reader.nextEntry()?.path == "skip-desc.bin")
        #expect(try reader.nextEntry()?.path == "wanted.txt")
        #expect(try reader.readEntryData() == wanted)
        #expect(try reader.nextEntry() == nil)
    }

    @Test func truncatedStreamFailsAndPoisonsReader() throws {
        let writer = ZipWriter()
        try writer.addFile(path: "a.bin", data: mixedData(count: 100_000, seed: 405))
        // Cut off in the middle of the entry's compressed data.
        let bytes = [UInt8](writer.finalize().prefix(10_000))

        let reader = ZipStreamReader(readChunk: chunkedSource(bytes, chunkSize: 4096))
        _ = try #require(try reader.nextEntry())
        #expect(throws: ZipError.self) {
            try reader.readEntry { _ in }
        }
        #expect(throws: ZipError.invalidState("the reader is unusable after a previous error")) {
            _ = try reader.nextEntry()
        }
    }

    @Test func streamReaderEnforcesEntrySizeLimit() throws {
        let writer = ZipWriter()
        try writer.addFile(path: "zeros.bin", data: Data(count: 600_000))
        let bytes = [UInt8](writer.finalize())

        let limits = ZipSecurityLimits(maxUncompressedEntrySize: 100_000)
        let reader = ZipStreamReader(limits: limits, readChunk: chunkedSource(bytes, chunkSize: 4096))
        _ = try #require(try reader.nextEntry())
        #expect(throws: ZipError.self) {
            try reader.readEntry { _ in }
        }
    }

    @Test func readsZipFileWriterArchiveFromFileHandle() throws {
        // ZipFileWriter's push-style entries use ZIP64 size placeholders in
        // the local header; the streaming reader must pick the patched sizes
        // out of the extra field.
        try withTemporaryDirectory { directory in
            let archiveURL = directory.appendingPathComponent("streamed.zip")
            let writer = try ZipFileWriter(url: archiveURL)
            let pushed = mixedData(count: 500_000, seed: 406)
            try writer.addFile(path: "pushed.bin") { stream in
                try stream.write(pushed)
            }
            try writer.addFile(path: "plain.txt", data: Data("plain".utf8))
            try writer.finalize()

            let handle = try FileHandle(forReadingFrom: archiveURL)
            defer { try? handle.close() }
            let reader = ZipStreamReader(fileHandle: handle)
            let first = try #require(try reader.nextEntry())
            #expect(first.path == "pushed.bin")
            #expect(try reader.readEntryData() == pushed)
            let second = try #require(try reader.nextEntry())
            #expect(second.path == "plain.txt")
            #expect(try reader.readEntryData() == Data("plain".utf8))
            #expect(try reader.nextEntry() == nil)
        }
    }

    #if os(macOS)
    @Test func readsInfoZipStreamedOutputThroughPipe() throws {
        // `zip -` writes a streaming archive (data descriptors) to stdout —
        // read it live from the pipe, never touching a seekable file.
        let zipPath = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: zipPath) else { return }

        try withTemporaryDirectory { directory in
            let payload = mixedData(count: 400_000, seed: 407)
            let fileURL = directory.appendingPathComponent("payload.bin")
            try payload.write(to: fileURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: zipPath)
            process.currentDirectoryURL = directory
            process.arguments = ["-q", "-", "payload.bin"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()

            let reader = ZipStreamReader(fileHandle: stdout.fileHandleForReading)
            let entry = try #require(try reader.nextEntry())
            #expect(entry.path == "payload.bin")
            #expect(try reader.readEntryData() == payload)
            #expect(try reader.nextEntry() == nil)

            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
    #endif
}
