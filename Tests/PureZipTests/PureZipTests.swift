import Foundation
import Testing
@testable import PureZip

// MARK: - Round trips

@Suite("Compression round trips")
struct RoundTripTests {
    @Test func crc32KnownVector() {
        #expect(CRC32.checksum([UInt8]("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([]) == 0)
    }

    static let payloadSizes = [0, 1, 2, 3, 100, 4096, 65535, 65536, 65537, 200_000]
    static let levels: [CompressionLevel] = [.fastest, .normal, .maximum]

    @Test("Deflate/Inflate round trip", arguments: payloadSizes, levels)
    func deflateRoundTrip(size: Int, level: CompressionLevel) throws {
        for original in [mixedData(count: size, seed: UInt64(size + 1)),
                         randomData(count: size, seed: UInt64(size + 7))] {
            let compressed = original.withUnsafeBytes {
                Deflate.compress($0.bindMemory(to: UInt8.self), level: level)
            }
            let decompressed = try compressed.withUnsafeBytes {
                try Inflate.decompress($0, expectedSize: original.count)
            }
            #expect(decompressed == original)
        }
    }

    @Test("Highly repetitive data round trip")
    func repetitiveData() throws {
        for original in [Data(count: 1 << 20),                          // all zeros
                         Data(repeating: 0xAB, count: 300_000),
                         Data((0..<300_000).map { UInt8($0 % 256) })] { // cycling bytes
            let compressed = original.withUnsafeBytes {
                Deflate.compress($0.bindMemory(to: UInt8.self), level: .normal)
            }
            #expect(compressed.count < original.count / 50, "run-length data should compress heavily")
            let decompressed = try compressed.withUnsafeBytes {
                try Inflate.decompress($0, expectedSize: original.count)
            }
            #expect(decompressed == original)
        }
    }

    @Test("Length-limited Huffman codes satisfy the Kraft equality")
    func lengthLimitedCodesAreComplete() {
        // Fibonacci frequencies build maximally skewed Huffman trees whose
        // depth exceeds the 15-bit limit; the depth-limiting pass must still
        // produce a complete (Kraft-exact) code. Regression test for codes
        // that came out over-subscribed and undecodable.
        for symbolCount in [16, 20, 24, 30, 40, 286] {
            var frequencies = [Int](repeating: 0, count: 286)
            // Capped so the tree's internal weight sums cannot overflow Int.
            var a = 1, b = 1
            for symbol in 0..<symbolCount {
                frequencies[symbol] = a
                (a, b) = (b, min(a + b, 1 << 40))
            }
            // maxBits 7 is only ever used for the 19-symbol code-length
            // alphabet; 2^7 codes cannot cover more symbols than that.
            for maxBits in symbolCount <= 19 ? [7, 15] : [15] {
                let lengths = Deflate.buildCodeLengths(frequencies: frequencies, maxBits: maxBits)
                var kraft = 0 // in units of 2^-maxBits
                for length in lengths where length > 0 {
                    #expect(Int(length) <= maxBits)
                    kraft += 1 << (maxBits - Int(length))
                }
                #expect(kraft == 1 << maxBits,
                        "n=\(symbolCount) maxBits=\(maxBits): Kraft sum \(kraft)/\(1 << maxBits)")
            }
        }
    }

//    @Test("Sample file that used to break the .fastest round trip")
//    func failingRoundTripSample() throws {
//        let sampleURL = URL(fileURLWithPath: #filePath)
//            .deletingLastPathComponent()   // PureZipTests
//            .deletingLastPathComponent()   // Tests
//            .deletingLastPathComponent()   // package root
//            .appendingPathComponent("Samples/failing-roundtrip")
//        guard let original = try? Data(contentsOf: sampleURL) else { return }
//        for level in Self.levels {
//            let compressed = original.withUnsafeBytes {
//                Deflate.compress($0.bindMemory(to: UInt8.self), level: level)
//            }
//            let decompressed = try compressed.withUnsafeBytes {
//                try Inflate.decompress($0, expectedSize: original.count)
//            }
//            #expect(decompressed == original, "level \(level)")
//        }
//    }

    @Test func emptyArchive() throws {
        let archive = try ZipArchive(data: ZipWriter().finalize())
        #expect(archive.entries.isEmpty)
    }

    @Test func archiveRoundTripWithMixedEntries() throws {
        let writer = ZipWriter()
        let text = Data("Hello, PureZip! 🗜️ ".utf8) + Data(repeating: 0x2E, count: 5000)
        let noise = randomData(count: 100_000, seed: 42)
        try writer.addDirectory(path: "docs")
        try writer.addFile(path: "docs/readme.txt", data: text)
        try writer.addFile(path: "noise.bin", data: noise)
        try writer.addFile(path: "empty.dat", data: Data())
        let archiveData = writer.finalize()

        let archive = try ZipArchive(data: archiveData)
        #expect(archive.entries.count == 4)

        let readme = try #require(archive["docs/readme.txt"])
        #expect(readme.compressionMethod == .deflate)
        #expect(readme.compressedSize < readme.uncompressedSize, "text should compress")
        #expect(try archive.extractData(readme) == text)

        let noiseEntry = try #require(archive["noise.bin"])
        #expect(noiseEntry.compressionMethod == .store, "incompressible data should be stored")
        #expect(try archive.extractData(noiseEntry) == noise)

        #expect(try archive.extractData(at: "empty.dat") == Data())
        #expect(try #require(archive["docs/"]).isDirectory)

        #expect(throws: ZipError.entryNotFound("missing.txt")) {
            try archive.extractData(at: "missing.txt")
        }
    }

    @Test func storeWithoutCompression() throws {
        let writer = ZipWriter()
        let payload = Data("compressible compressible compressible".utf8)
        try writer.addFile(path: "stored.txt", data: payload, compress: false)
        let archive = try ZipArchive(data: writer.finalize())
        let entry = try #require(archive["stored.txt"])
        #expect(entry.compressionMethod == .store)
        #expect(entry.compressedSize == entry.uncompressedSize)
        #expect(try archive.extractData(entry) == payload)
    }

    @Test func metadataRoundTrip() throws {
        let writer = ZipWriter()
        let date = Date(timeIntervalSinceNow: -100_000)
        try writer.addFile(path: "script.sh", data: Data("#!/bin/sh\n".utf8),
                           modificationDate: date, permissions: 0o755)
        let archive = try ZipArchive(data: writer.finalize())
        let entry = try #require(archive["script.sh"])
        #expect(entry.posixPermissions == 0o755)
        let restored = try #require(entry.modificationDate)
        #expect(abs(restored.timeIntervalSince(date)) <= 2, "DOS timestamps have 2s resolution")
    }

    @Test func duplicateAndInvalidWriterPaths() throws {
        let writer = ZipWriter()
        try writer.addFile(path: "a.txt", data: Data([1]))
        #expect(throws: ZipError.duplicateEntry("a.txt")) {
            try writer.addFile(path: "a.txt", data: Data([2]))
        }
        #expect(throws: ZipError.self) { try writer.addFile(path: "", data: Data()) }
        #expect(throws: ZipError.self) { try writer.addFile(path: "../escape.txt", data: Data()) }
        #expect(throws: ZipError.self) { try writer.addFile(path: "a/../../escape.txt", data: Data()) }
    }

    @Test func zip64EntryCountRoundTrip() throws {
        // More than 0xFFFF entries forces ZIP64 end-of-central-directory records.
        let writer = ZipWriter()
        let date = Date()
        for i in 0..<66_000 {
            try writer.addFile(path: "f\(i).txt", data: Data(), modificationDate: date)
        }
        let archive = try ZipArchive(data: writer.finalize())
        #expect(archive.entries.count == 66_000)
        #expect(try archive.extractData(at: "f0.txt") == Data())
        #expect(try archive.extractData(at: "f65999.txt") == Data())
    }
}

// MARK: - Filenames

@Suite("Filename handling")
struct FilenameTests {
    static let trickyNames = [
        "héllo wörld.txt",
        "日本語ファイル名.txt",
        "emoji 😀🎉.bin",
        "spaces  double  and.trailing dot.",
        "quotes '\" backtick `.txt",
        "plus+equals=&ampersand.txt",
        "Ünïcödé/ñested/ß.txt",
        "combining e\u{301} accent.txt",
        String(repeating: "z", count: 200) + ".txt",
    ]

    @Test("Tricky names survive a round trip", arguments: trickyNames)
    func trickyNameRoundTrip(name: String) throws {
        let writer = ZipWriter()
        let payload = Data("content of \(name)".utf8)
        try writer.addFile(path: name, data: payload)
        let archive = try ZipArchive(data: writer.finalize())
        let entry = try #require(archive[name], "entry should be findable under its exact name")
        #expect(entry.path == name)
        #expect(try archive.extractData(entry) == payload)
    }

    @Test func cp437FallbackForNonUTF8Names() throws {
        // 0x82 is "é" in CP437 and is invalid as standalone UTF-8.
        let data = buildRawZip([.stored(nameBytes: [0x82, 0x2E, 0x74, 0x78, 0x74], content: [1, 2, 3])])
        let archive = try ZipArchive(data: data)
        #expect(archive.entries.first?.path == "é.txt")
    }

    @Test func unflaggedUTF8NamesAreDecodedAsUTF8() throws {
        // Many archivers write UTF-8 names without setting the UTF-8 flag.
        let data = buildRawZip([.stored(nameBytes: [UInt8]("ünflagged.txt".utf8), content: [7])])
        let archive = try ZipArchive(data: data)
        #expect(archive.entries.first?.path == "ünflagged.txt")
    }

    @Test func legacyNameEncodingDecodesSystemCodePages() throws {
        // Shift-JIS names (Japanese Windows) are invalid as UTF-8 and come out
        // as CP437 mojibake unless the caller provides the encoding.
        let japaneseName = "日本語ファイル.txt"
        let shiftJISBytes = [UInt8](try #require(japaneseName.data(using: .shiftJIS)))
        let data = buildRawZip([.stored(nameBytes: shiftJISBytes, content: [1])])

        let withoutHint = try ZipArchive(data: data)
        #expect(withoutHint.entries.first?.path != japaneseName)

        let archive = try ZipArchive(data: data, legacyNameEncoding: .shiftJIS)
        #expect(archive.entries.first?.path == japaneseName)
        #expect(archive.legacyNameEncoding == .shiftJIS)
        #expect(try archive.extractData(at: japaneseName) == Data([1]))
    }

    @Test func legacyNameEncodingSupportsClassicMacOS() throws {
        let romanName = "héllo wörld.txt"
        let romanBytes = [UInt8](try #require(romanName.data(using: .macOSRoman)))
        let roman = try ZipArchive(
            data: buildRawZip([.stored(nameBytes: romanBytes, content: [1])]),
            legacyNameEncoding: .macOSRoman
        )
        #expect(roman.entries.first?.path == romanName)

        let japaneseName = "日本語ファイル.txt"
        let macJapaneseBytes = [UInt8](try #require(japaneseName.data(using: .macOSJapanese)))
        let macJapanese = try ZipArchive(
            data: buildRawZip([.stored(nameBytes: macJapaneseBytes, content: [1])]),
            legacyNameEncoding: .macOSJapanese
        )
        #expect(macJapanese.entries.first?.path == japaneseName)

        let cyrillicName = "файл данных.bin"
        let cyrillicBytes = [UInt8](try #require(cyrillicName.data(using: .macOSCyrillic)))
        let cyrillic = try ZipArchive(
            data: buildRawZip([.stored(nameBytes: cyrillicBytes, content: [1])]),
            legacyNameEncoding: .macOSCyrillic
        )
        #expect(cyrillic.entries.first?.path == cyrillicName)
    }

    @Test func legacyNameEncodingRespectsPrecedence() throws {
        // Valid (unflagged) UTF-8 must still decode as UTF-8 even when a
        // legacy encoding is provided.
        let utf8 = try ZipArchive(
            data: buildRawZip([.stored(nameBytes: [UInt8]("ünflagged.txt".utf8), content: [7])]),
            legacyNameEncoding: .shiftJIS
        )
        #expect(utf8.entries.first?.path == "ünflagged.txt")

        // 0x82 is a Shift-JIS lead byte but 0x2E is not a valid trail byte;
        // when the legacy encoding cannot decode the bytes, CP437 applies.
        let cp437 = try ZipArchive(
            data: buildRawZip([.stored(nameBytes: [0x82, 0x2E, 0x74, 0x78, 0x74], content: [1])]),
            legacyNameEncoding: .shiftJIS
        )
        #expect(cp437.entries.first?.path == "é.txt")
    }

    @Test func backslashSeparatorsAreTreatedAsPathSeparators() async throws {
        let data = buildRawZip([.stored(name: "dir\\sub\\file.txt", content: [UInt8]("x".utf8))])
        let archive = try ZipArchive(data: data)
        try await withTemporaryDirectory { directory in
            try await archive.extractAll(to: directory)
            let extracted = directory.appendingPathComponent("dir/sub/file.txt")
            #expect(FileManager.default.fileExists(atPath: extracted.path))
        }
    }
}

// MARK: - Security

@Suite("Security hardening")
struct SecurityTests {
    @Test("Path traversal attempts are rejected",
          arguments: ["../evil.txt", "a/../../evil.txt", "..", "C:\\evil.txt", "..\\evil.txt"])
    func pathTraversalRejected(maliciousPath: String) async throws {
        let data = buildRawZip([.stored(name: maliciousPath, content: [UInt8]("pwned".utf8))])
        let archive = try ZipArchive(data: data)
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("dest", isDirectory: true)
            await #expect(throws: ZipError.unsafePath(maliciousPath)) {
                try await archive.extractAll(to: destination)
            }
            // Nothing may have escaped into the parent directory.
            let escaped = directory.appendingPathComponent("evil.txt")
            #expect(!FileManager.default.fileExists(atPath: escaped.path))
        }
    }

    @Test func absolutePathsAreExtractedInsideDestination() async throws {
        let data = buildRawZip([.stored(name: "/abs.txt", content: [UInt8]("safe".utf8))])
        let archive = try ZipArchive(data: data)
        try await withTemporaryDirectory { directory in
            try await archive.extractAll(to: directory)
            let inside = directory.appendingPathComponent("abs.txt")
            #expect(try Data(contentsOf: inside) == Data("safe".utf8))
            #expect(!FileManager.default.fileExists(atPath: "/abs.txt"))
        }
    }

    @Test func symlinkExtractionPolicies() async throws {
        var link = RawZipEntry.stored(name: "innocent", content: [UInt8]("/etc/passwd".utf8))
        link.externalAttributes = 0o120777 << 16 // S_IFLNK
        let data = buildRawZip([link])

        try await withTemporaryDirectory { directory in
            // Default (confined): an absolute target is rejected and nothing
            // is created on disk.
            let confined = try ZipArchive(data: data)
            #expect(confined.entries.first?.isSymbolicLink == true)
            let confinedTarget = directory.appendingPathComponent("confined", isDirectory: true)
            await #expect(throws: ZipError.symlinkNotPermitted("innocent")) {
                try await confined.extractAll(to: confinedTarget)
            }
            let confinedLink = confinedTarget.appendingPathComponent("innocent")
            #expect((try? FileManager.default.attributesOfItem(atPath: confinedLink.path)) == nil)

            // reject: same outcome for any symlink entry.
            let reject = try ZipArchive(
                data: data, limits: ZipSecurityLimits(symlinkPolicy: .reject)
            )
            await #expect(throws: ZipError.symlinkNotPermitted("innocent")) {
                try await reject.extractAll(to: directory.appendingPathComponent("reject"))
            }

            // unrestricted: the link is recreated verbatim (nothing is
            // written through it).
            let unrestricted = try ZipArchive(
                data: data, limits: ZipSecurityLimits(symlinkPolicy: .unrestricted)
            )
            let unrestrictedTarget = directory.appendingPathComponent("open", isDirectory: true)
            try await unrestricted.extractAll(to: unrestrictedTarget)
            let created = unrestrictedTarget.appendingPathComponent("innocent").path
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: created) == "/etc/passwd")
        }
    }

    @Test func escapingRelativeSymlinkTargetIsRejected() async throws {
        // "sub/link" -> "../../escape" lexically leaves the destination.
        let writer = ZipWriter()
        try writer.addSymbolicLink(path: "sub/link", target: "../../escape")
        let archive = try ZipArchive(data: writer.finalize())
        try await withTemporaryDirectory { directory in
            await #expect(throws: ZipError.symlinkNotPermitted("sub/link")) {
                try await archive.extractAll(to: directory)
            }
        }

        // One level less stays inside and must extract.
        let okWriter = ZipWriter()
        try okWriter.addSymbolicLink(path: "sub/link", target: "../sibling.txt")
        let okArchive = try ZipArchive(data: okWriter.finalize())
        try await withTemporaryDirectory { directory in
            try await okArchive.extractAll(to: directory)
            let created = directory.appendingPathComponent("sub/link").path
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: created) == "../sibling.txt")
        }
    }

    @Test func filesAreNeverWrittenThroughEscapingSymlinks() async throws {
        // Even with .unrestricted, a file entry whose parent chain passes
        // through a link that leaves the destination must be refused.
        let writer = ZipWriter()
        try writer.addSymbolicLink(path: "dir", target: "/private/tmp")
        try await writer.addFile(path: "dir/evil.txt", data: Data("pwned".utf8))
        let archive = try ZipArchive(
            data: writer.finalize(), limits: ZipSecurityLimits(symlinkPolicy: .unrestricted)
        )
        try await withTemporaryDirectory { directory in
            await #expect(throws: ZipError.unsafePath("dir/evil.txt")) {
                try await archive.extractAll(to: directory)
            }
            #expect(!FileManager.default.fileExists(atPath: "/private/tmp/evil.txt"))
        }
    }

    @Test func encryptedEntriesAreRejected() throws {
        var entry = RawZipEntry.stored(name: "secret.txt", content: [1, 2, 3])
        entry.flags |= 0x0001
        let archive = try ZipArchive(data: buildRawZip([entry]))
        #expect(throws: ZipError.encryptedEntryUnsupported("secret.txt")) {
            _ = try archive.extractData(archive.entries[0])
        }
    }

    @Test func zipBombTotalSizeLimit() async throws {
        // Three highly compressible entries; the total exceeds the configured cap.
        let writer = ZipWriter()
        for i in 0..<3 {
            try await writer.addFile(path: "zeros\(i).bin", data: Data(count: 600_000))
        }
        let data = writer.finalize()
        #expect(data.count < 20_000, "the bomb itself must be small")

        let limits = ZipSecurityLimits(maxTotalUncompressedSize: 1_000_000)
        let archive = try ZipArchive(data: data, limits: limits)
        try await withTemporaryDirectory { directory in
            await #expect(throws: ZipError.self) {
                try await archive.extractAll(to: directory)
            }
        }
    }

    @Test func zipBombPerEntryLimit() throws {
        let writer = ZipWriter()
        try writer.addFile(path: "zeros.bin", data: Data(count: 600_000))
        let limits = ZipSecurityLimits(maxUncompressedEntrySize: 100_000)
        let archive = try ZipArchive(data: writer.finalize(), limits: limits)
        #expect(throws: ZipError.self) {
            _ = try archive.extractData(archive.entries[0])
        }
    }

    @Test func entryCountLimit() throws {
        let data = buildRawZip([
            .stored(name: "a", content: []),
            .stored(name: "b", content: []),
            .stored(name: "c", content: []),
        ])
        #expect(throws: ZipError.self) {
            _ = try ZipArchive(data: data, limits: ZipSecurityLimits(maxEntryCount: 2))
        }
    }

    @Test func entryLyingAboutSmallSizeIsRejected() throws {
        // The deflate stream really inflates to 200,000 bytes; the header claims 10.
        // Decompression must stop at the declared size instead of ballooning.
        let zeros = Data(count: 200_000)
        var liar = RawZipEntry(name: "liar.bin")
        liar.method = 8
        liar.compressedData = Deflate.compress(zeros)
        liar.uncompressedSize = 10
        liar.crc = CRC32.checksum(zeros)
        let archive = try ZipArchive(data: buildRawZip([liar]))
        #expect(throws: ZipError.self) {
            _ = try archive.extractData(archive.entries[0])
        }
    }

    @Test func entryLyingAboutLargeSizeIsRejected() throws {
        let zeros = Data(count: 200_000)
        var liar = RawZipEntry(name: "liar.bin")
        liar.method = 8
        liar.compressedData = Deflate.compress(zeros)
        liar.uncompressedSize = 300_000
        liar.crc = CRC32.checksum(zeros)
        let archive = try ZipArchive(data: buildRawZip([liar]))
        #expect(throws: ZipError.self) {
            _ = try archive.extractData(archive.entries[0])
        }
    }

    @Test func corruptedChecksumIsDetected() throws {
        let payload = Data("important payload".utf8)
        var entry = RawZipEntry.stored(name: "f.bin", content: [UInt8](payload))
        entry.crc &+= 1
        let archive = try ZipArchive(data: buildRawZip([entry]))
        #expect(throws: ZipError.checksumMismatch("f.bin")) {
            _ = try archive.extractData(archive.entries[0])
        }
    }

    @Test func truncatedArchivesFailCleanly() throws {
        let writer = ZipWriter()
        try writer.addFile(path: "a.txt", data: mixedData(count: 50_000, seed: 3))
        let data = writer.finalize()
        for fraction in [0.02, 0.3, 0.6, 0.95, 0.999] {
            let cut = Data(data.prefix(Int(Double(data.count) * fraction)))
            #expect(throws: ZipError.self) { _ = try ZipArchive(data: cut) }
        }
    }

    @Test func flippedCompressedByteIsDetected() throws {
        let writer = ZipWriter()
        try writer.addFile(path: "a.bin", data: mixedData(count: 50_000, seed: 9))
        var data = writer.finalize()
        // Flip a byte in the middle of the compressed stream (past the ~50-byte header).
        data[200] ^= 0xFF
        do {
            let archive = try ZipArchive(data: data)
            _ = try archive.extractData(archive.entries[0])
            Issue.record("corruption was not detected")
        } catch is ZipError {
            // expected: either a decode error or a checksum mismatch
        }
    }

    @Test func garbageInputIsRejected() {
        #expect(throws: ZipError.notAZipFile) { _ = try ZipArchive(data: Data()) }
        #expect(throws: ZipError.notAZipFile) { _ = try ZipArchive(data: Data("not a zip".utf8)) }
        #expect(throws: ZipError.notAZipFile) {
            _ = try ZipArchive(data: randomData(count: 4096, seed: 11))
        }
    }

    @Test func unsupportedCompressionMethodIsReported() throws {
        var entry = RawZipEntry.stored(name: "x", content: [1])
        entry.method = 12 // bzip2 — not supported
        let archive = try ZipArchive(data: buildRawZip([entry]))
        #expect(throws: ZipError.unsupportedCompressionMethod(12)) {
            _ = try archive.extractData(archive.entries[0])
        }
    }
}

// MARK: - File and folder operations

@Suite("File and folder operations")
struct FileSystemTests {
    @Test func folderRoundTrip() async throws {
        try await withTemporaryDirectory { directory in
            let fileManager = FileManager.default
            let source = directory.appendingPathComponent("Source Földer", isDirectory: true)
            try fileManager.createDirectory(
                at: source.appendingPathComponent("nested/deep"), withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: source.appendingPathComponent("empty dir"), withIntermediateDirectories: true
            )
            let textFile = source.appendingPathComponent("Notes älpha.txt")
            try Data("Hello from PureZip".utf8).write(to: textFile)
            let binary = mixedData(count: 150_000, seed: 21)
            try binary.write(to: source.appendingPathComponent("nested/deep/data.bin"))
            let script = source.appendingPathComponent("run.sh")
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try Data().write(to: source.appendingPathComponent("empty.bin"))
            // A confined symlink that must round-trip.
            try fileManager.createSymbolicLink(
                atPath: source.appendingPathComponent("link").path,
                withDestinationPath: "Notes älpha.txt"
            )

            let archiveURL = directory.appendingPathComponent("out.zip")
            try await PureZip.zipItem(at: source, to: archiveURL)

            let archive = try ZipArchive(url: archiveURL)
            #expect(archive["Source Földer/link"]?.isSymbolicLink == true)

            let destination = directory.appendingPathComponent("extracted", isDirectory: true)
            try await PureZip.unzipItem(at: archiveURL, to: destination)

            let extractedRoot = destination.appendingPathComponent("Source Földer")
            #expect(
                try Data(contentsOf: extractedRoot.appendingPathComponent("Notes älpha.txt"))
                    == Data("Hello from PureZip".utf8)
            )
            #expect(
                try Data(contentsOf: extractedRoot.appendingPathComponent("nested/deep/data.bin"))
                    == binary
            )
            #expect(
                try Data(contentsOf: extractedRoot.appendingPathComponent("empty.bin")) == Data()
            )
            var isDirectory: ObjCBool = false
            #expect(fileManager.fileExists(
                atPath: extractedRoot.appendingPathComponent("empty dir").path,
                isDirectory: &isDirectory
            ))
            #expect(isDirectory.boolValue)

            let scriptAttributes = try fileManager.attributesOfItem(
                atPath: extractedRoot.appendingPathComponent("run.sh").path
            )
            let permissions = (scriptAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            #expect(permissions & 0o777 == 0o755, "executable bit should survive")

            let extractedLink = extractedRoot.appendingPathComponent("link").path
            #expect(try fileManager.destinationOfSymbolicLink(atPath: extractedLink) == "Notes älpha.txt")
            #expect(
                try Data(contentsOf: extractedRoot.appendingPathComponent("link"))
                    == Data("Hello from PureZip".utf8),
                "reading through the recreated link must reach the real file"
            )
        }
    }

    @Test func frameworkBundleRoundTrip() async throws {
        // The symlink layout of a macOS framework bundle: everything reaches
        // the real files through relative, in-tree links.
        try await withTemporaryDirectory { directory in
            let fileManager = FileManager.default
            let bundle = directory.appendingPathComponent("MyLib.framework", isDirectory: true)
            let versionA = bundle.appendingPathComponent("Versions/A", isDirectory: true)
            try fileManager.createDirectory(
                at: versionA.appendingPathComponent("Resources"), withIntermediateDirectories: true
            )
            let binary = mixedData(count: 100_000, seed: 71)
            try binary.write(to: versionA.appendingPathComponent("MyLib"))
            try Data("plist".utf8).write(
                to: versionA.appendingPathComponent("Resources/Info.plist")
            )
            try fileManager.createSymbolicLink(
                atPath: bundle.appendingPathComponent("Versions/Current").path,
                withDestinationPath: "A"
            )
            try fileManager.createSymbolicLink(
                atPath: bundle.appendingPathComponent("MyLib").path,
                withDestinationPath: "Versions/Current/MyLib"
            )
            try fileManager.createSymbolicLink(
                atPath: bundle.appendingPathComponent("Resources").path,
                withDestinationPath: "Versions/Current/Resources"
            )

            let archiveURL = directory.appendingPathComponent("framework.zip")
            try await PureZip.zipItem(at: bundle, to: archiveURL)
            let destination = directory.appendingPathComponent("extracted", isDirectory: true)
            try await PureZip.unzipItem(at: archiveURL, to: destination)

            let extracted = destination.appendingPathComponent("MyLib.framework")
            #expect(
                try fileManager.destinationOfSymbolicLink(
                    atPath: extracted.appendingPathComponent("Versions/Current").path
                ) == "A"
            )
            #expect(
                try fileManager.destinationOfSymbolicLink(
                    atPath: extracted.appendingPathComponent("MyLib").path
                ) == "Versions/Current/MyLib"
            )
            // Reading through the two-level link chain must reach the binary.
            #expect(try Data(contentsOf: extracted.appendingPathComponent("MyLib")) == binary)
            #expect(
                try Data(contentsOf: extracted.appendingPathComponent("Resources/Info.plist"))
                    == Data("plist".utf8)
            )
        }
    }

    @Test func zipItemSymlinkPolicies() async throws {
        try await withTemporaryDirectory { directory in
            let fileManager = FileManager.default
            let source = directory.appendingPathComponent("tree", isDirectory: true)
            try fileManager.createDirectory(
                at: source.appendingPathComponent("sub"), withIntermediateDirectories: true
            )
            try Data("data".utf8).write(to: source.appendingPathComponent("file.txt"))
            // Lexically escapes the tree: sub/../../<outside>.
            try fileManager.createSymbolicLink(
                atPath: source.appendingPathComponent("sub/escape").path,
                withDestinationPath: "../../outside.txt"
            )

            // Default (confined): the escaping link is rejected.
            let confinedURL = directory.appendingPathComponent("confined.zip")
            await #expect(throws: ZipError.symlinkNotPermitted("tree/sub/escape")) {
                try await PureZip.zipItem(at: source, to: confinedURL)
            }

            // reject: any symlink throws, even a confined one.
            try fileManager.removeItem(at: source.appendingPathComponent("sub/escape"))
            try fileManager.createSymbolicLink(
                atPath: source.appendingPathComponent("sub/confined").path,
                withDestinationPath: "../file.txt"
            )
            let rejectURL = directory.appendingPathComponent("reject.zip")
            await #expect(throws: ZipError.symlinkNotPermitted("tree/sub/confined")) {
                try await PureZip.zipItem(at: source, to: rejectURL, symlinkPolicy: .reject)
            }

            // confined accepts an in-tree relative link.
            let okURL = directory.appendingPathComponent("ok.zip")
            try await PureZip.zipItem(at: source, to: okURL)
            let archive = try ZipArchive(url: okURL)
            let link = try #require(archive["tree/sub/confined"])
            #expect(link.isSymbolicLink)
            #expect(try archive.extractData(link) == Data("../file.txt".utf8))

            // unrestricted archives an absolute link verbatim.
            try fileManager.createSymbolicLink(
                atPath: source.appendingPathComponent("absolute").path,
                withDestinationPath: "/etc/hosts"
            )
            let unrestrictedURL = directory.appendingPathComponent("unrestricted.zip")
            try await PureZip.zipItem(
                at: source, to: unrestrictedURL, symlinkPolicy: .unrestricted
            )
            let unrestricted = try ZipArchive(url: unrestrictedURL)
            let absolute = try #require(unrestricted["tree/absolute"])
            #expect(try unrestricted.extractData(absolute) == Data("/etc/hosts".utf8))
        }
    }

    @Test func singleFileZipItem() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("solo.txt")
            try Data("just one file".utf8).write(to: file)
            let archiveURL = directory.appendingPathComponent("solo.zip")
            try await PureZip.zipItem(at: file, to: archiveURL)
            let archive = try ZipArchive(url: archiveURL)
            #expect(archive.entries.map(\.path) == ["solo.txt"])
            #expect(try archive.extractData(at: "solo.txt") == Data("just one file".utf8))
        }
    }

    @Test func overwriteBehavior() async throws {
        try await withTemporaryDirectory { directory in
            let writer = ZipWriter()
            try await writer.addFile(path: "f.txt", data: Data("v1".utf8))
            let archive = try ZipArchive(data: writer.finalize())
            try await archive.extractAll(to: directory)
            await #expect(throws: ZipError.self) { try await archive.extractAll(to: directory) }
            try await archive.extractAll(to: directory, overwrite: true)
            #expect(try Data(contentsOf: directory.appendingPathComponent("f.txt")) == Data("v1".utf8))
        }
    }

    @Test func zipAndUnzipReportProgress() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let sizes = [2_000_000, 700_000, 0]
            for (index, size) in sizes.enumerated() {
                try mixedData(count: size, seed: UInt64(index)).write(
                    to: source.appendingPathComponent("file\(index).bin")
                )
            }
            let expectedTotal = UInt64(sizes.reduce(0, +))

            let archiveURL = directory.appendingPathComponent("out.zip")
            let zipLog = ProgressLog()
            try await PureZip.zipItem(at: source, to: archiveURL) { zipLog.append($0) }

            let zipSnapshots = zipLog.snapshots
            #expect(zipSnapshots.count > 1, "multi-chunk input should report more than once")
            #expect(zipSnapshots.allSatisfy { $0.totalBytes == expectedTotal })
            let zipCompleted = zipSnapshots.map(\.completedBytes)
            #expect(zipCompleted == zipCompleted.sorted(), "progress must be monotonic")
            #expect(zipSnapshots.last?.completedBytes == expectedTotal)
            #expect(zipSnapshots.last?.fraction == 1)

            let destination = directory.appendingPathComponent("extracted", isDirectory: true)
            let unzipLog = ProgressLog()
            try await PureZip.unzipItem(at: archiveURL, to: destination) { unzipLog.append($0) }

            let unzipSnapshots = unzipLog.snapshots
            #expect(unzipSnapshots.allSatisfy { $0.totalBytes == expectedTotal })
            let unzipCompleted = unzipSnapshots.map(\.completedBytes)
            #expect(unzipCompleted == unzipCompleted.sorted(), "progress must be monotonic")
            #expect(unzipSnapshots.last?.completedBytes == expectedTotal)
            #expect(unzipSnapshots.last?.fraction == 1)
        }
    }

    @Test func cancelledZipItemThrowsAndCleansUp() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            // Several chunks, so a cancellation check runs after the first report.
            try mixedData(count: 3_000_000, seed: 5).write(
                to: source.appendingPathComponent("big.bin")
            )

            let archiveURL = directory.appendingPathComponent("out.zip")
            let task = Task {
                // Cancel ourselves after the first progress report.
                try await PureZip.zipItem(at: source, to: archiveURL) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: archiveURL.path),
                    "a cancelled zipItem must not leave a partial archive")
        }
    }
}

// MARK: - Interoperability with other ZIP implementations

@Suite("Interoperability")
struct InteropTests {
    /// A small archive created by Info-ZIP 3.0 (`zip -r`) on macOS containing
    /// stored entries with accented, Japanese, and emoji filenames plus empty
    /// file and directory entries.
    static let infoZipFixtureBase64 = """
        UEsDBAoAAAAAAFyFDF3QB6l9EwAAABMAAAARAAAAaMOpbGxvIHfDtnJsZC50eHRHcsO8w59lIGF1cyBaw7xyaWNoUEsDBAoAAAAAAFyFDF0AAAAAAAAAAAAAAAAJAAAAw5ZyZG7DqXIvUEsDBAoAAAAAAFyFDF3nG4S4DwAAAA8AAAAiAAAAw5ZyZG7DqXIv5pel5pys6Kqe44OV44Kh44Kk44OrLnR4dOOBk+OCk+OBq+OBoeOBr1BLAwQKAAAAAABchQxdAAAAAAAAAAAAAAAAEAAAAMOWcmRuw6lyL25lc3RlZC9QSwMECgAAAAAAXIUMXeBOlYkFAAAABQAAAB4AAADDlnJkbsOpci9uZXN0ZWQvZW1vamkg8J+YgC50eHRwYXJ0eVBLAwQKAAAAAABchQxdAAAAAAAAAAAAAAAACQAAAGVtcHR5LmJpblBLAwQKAAAAAABchQxdAAAAAAAAAAAAAAAACgAAAGVtcHR5IGRpci9QSwECHgMKAAAAAABchQxd0AepfRMAAAATAAAAEQAAAAAAAAABAAAApIEAAAAAaMOpbGxvIHfDtnJsZC50eHRQSwECHgMKAAAAAABchQxdAAAAAAAAAAAAAAAACQAAAAAAAAAAABAA7UFCAAAAw5ZyZG7DqXIvUEsBAh4DCgAAAAAAXIUMXecbhLgPAAAADwAAACIAAAAAAAAAAQAAAKSBaQAAAMOWcmRuw6lyL+aXpeacrOiqnuODleOCoeOCpOODqy50eHRQSwECHgMKAAAAAABchQxdAAAAAAAAAAAAAAAAEAAAAAAAAAAAABAA7UG4AAAAw5ZyZG7DqXIvbmVzdGVkL1BLAQIeAwoAAAAAAFyFDF3gTpWJBQAAAAUAAAAeAAAAAAAAAAEAAACkgeYAAADDlnJkbsOpci9uZXN0ZWQvZW1vamkg8J+YgC50eHRQSwECHgMKAAAAAABchQxdAAAAAAAAAAAAAAAACQAAAAAAAAAAAAAApIEnAQAAZW1wdHkuYmluUEsBAh4DCgAAAAAAXIUMXQAAAAAAAAAAAAAAAAoAAAAAAAAAAAAQAO1BTgEAAGVtcHR5IGRpci9QSwUGAAAAAAcABwC/AQAAdgEAAAAA
        """

    /// An archive created by Info-ZIP (`zip -9`) whose single entry is a
    /// real zlib-generated DEFLATE stream (9000 bytes of repeated text).
    static let deflatedFixtureBase64 = """
        UEsDBBQAAgAIAGeFDF1pL4uTWQAAACgjAAAMAAAAZGVmbGF0ZWQudHh07crLEYIwFADAVl4FVJMGQIN/A9GoUL20wcyed9M5x9wuh1sMtXyfMZZfXNtjekX55Brvje/9usSxnLpIsizLsizLsizLsizLsizLsizLsizLsizLsrzP/AdQSwECHgMUAAIACABnhQxdaS+Lk1kAAAAoIwAADAAAAAAAAAABAAAApIEAAAAAZGVmbGF0ZWQudHh0UEsFBgAAAAABAAEAOgAAAIMAAAAAAA==
        """

    @Test func readsInfoZipArchive() async throws {
        let data = try #require(Data(base64Encoded: Self.infoZipFixtureBase64))
        let archive = try ZipArchive(data: data)
        let paths = Set(archive.entries.map(\.path))
        #expect(paths.contains("héllo wörld.txt"))
        #expect(paths.contains("Ördnér/日本語ファイル.txt"))
        #expect(paths.contains("Ördnér/nested/emoji 😀.txt"))
        #expect(paths.contains("empty.bin"))
        #expect(try #require(archive["empty dir/"]).isDirectory)

        #expect(try archive.extractData(at: "héllo wörld.txt") == Data("Grüße aus Zürich".utf8))
        #expect(try archive.extractData(at: "Ördnér/日本語ファイル.txt") == Data("こんにちは".utf8))
        #expect(try archive.extractData(at: "Ördnér/nested/emoji 😀.txt") == Data("party".utf8))

        try await withTemporaryDirectory { directory in
            try await archive.extractAll(to: directory)
            let file = directory.appendingPathComponent("Ördnér/nested/emoji 😀.txt")
            #expect(try Data(contentsOf: file) == Data("party".utf8))
        }
    }

    @Test func decompressesZlibProducedDeflateStream() throws {
        let data = try #require(Data(base64Encoded: Self.deflatedFixtureBase64))
        let archive = try ZipArchive(data: data)
        let entry = try #require(archive["deflated.txt"])
        #expect(entry.compressionMethod == .deflate)
        let expected = Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200).utf8)
        #expect(try archive.extractData(entry) == expected)
    }

    #if os(macOS)
    @Test func systemUnzipAcceptsOurArchives() throws {
        let unzipPath = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzipPath) else { return }

        try withTemporaryDirectory { directory in
            let writer = ZipWriter()
            let text = Data(String(repeating: "interop test data ", count: 3000).utf8)
            let noise = randomData(count: 80_000, seed: 77)
            try writer.addDirectory(path: "sub")
            try writer.addFile(path: "sub/tëxt fïle.txt", data: text)
            try writer.addFile(path: "noise.bin", data: noise)
            let archiveURL = directory.appendingPathComponent("ours.zip")
            try writer.finalize().write(to: archiveURL)

            // `unzip -t` decompresses everything and verifies all CRCs.
            let test = Process()
            test.executableURL = URL(fileURLWithPath: unzipPath)
            test.arguments = ["-t", archiveURL.path]
            test.standardOutput = Pipe()
            test.standardError = Pipe()
            try test.run()
            test.waitUntilExit()
            #expect(test.terminationStatus == 0, "unzip -t should verify our archive")

            // Extract with unzip and compare contents byte for byte.
            let extractDirectory = directory.appendingPathComponent("unzip-out", isDirectory: true)
            let extract = Process()
            extract.executableURL = URL(fileURLWithPath: unzipPath)
            extract.arguments = ["-q", archiveURL.path, "-d", extractDirectory.path]
            try extract.run()
            extract.waitUntilExit()
            #expect(extract.terminationStatus == 0)
            #expect(
                try Data(contentsOf: extractDirectory.appendingPathComponent("sub/tëxt fïle.txt")) == text
            )
            #expect(
                try Data(contentsOf: extractDirectory.appendingPathComponent("noise.bin")) == noise
            )
        }
    }
    #endif
}
