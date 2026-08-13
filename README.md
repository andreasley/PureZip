# PureZip

A pure-Swift ZIP library — read, write, compress, and extract ZIP archives with **no zlib and no C dependencies**. The DEFLATE compressor and decompressor are implemented entirely in Swift.

## Features

- **Read and write ZIP archives**, in memory or on disk
- **Compress files and folders** to `.zip`, extract archives to a directory
- **Streaming compression and extraction** with constant memory usage: `ZipFileWriter` compresses entries chunk by chunk straight to disk (including push-style entries of unknown size), and `ZipArchive` extracts entries of any size through a fixed ~96 KiB window — `zipItem`/`unzipItem` use these automatically
- **Pure Swift DEFLATE** (RFC 1951): LZ77 hash-chain matching with lazy evaluation; per-block selection between dynamic Huffman, fixed Huffman, and stored encoding, so output never balloons
- **ZIP64 support**: large sizes/offsets and more than 65,535 entries
- **Automatic store fallback**: entries that don't shrink under DEFLATE are stored uncompressed
- **Robust filename handling**: UTF-8 (flagged and unflagged), the Info-ZIP Unicode Path extra field, and CP437 fallback for legacy archives — plus an opt-in `legacyNameEncoding` for archives whose names use a system code page (Shift-JIS, Windows code pages, classic Mac OS encodings, ...)
- **Metadata**: DOS timestamps and POSIX permissions round-trip through the archive
- **Three compression levels**: `.fastest`, `.normal`, `.maximum`
- **Async high-level API**: `zipItem`, `unzipItem`, `extractAll`, and `extract(_:to:)` are `async`, run off the caller's actor, report byte-level progress through a `@Sendable` callback, and stop on task cancellation
- **Interoperable**: archives verify cleanly with Info-ZIP's `unzip -t`; archives from other tools (Info-ZIP, zlib streams) read correctly

### Security hardening

Malicious or broken archives are treated as hostile input everywhere:

- **ZIP bomb protection** — decompression is hard-capped at each entry's declared size, and configurable `ZipSecurityLimits` cap per-entry size, total extracted size, and entry count. Entries that lie about their sizes are rejected.
- **Path traversal protection** — entry paths are sanitized (`..` components, NUL bytes, and drive designators are rejected; absolute paths and backslash separators are neutralized), and a resolved-path containment check prevents escapes through pre-existing symlinks. Extraction never writes outside the destination directory.
- **No symlink extraction** — symbolic link entries are never created on disk.
- **Integrity checking** — every extracted entry is verified against its CRC-32 checksum and declared size.
- **Safe parsing** — all archive parsing is bounds-checked; truncated, corrupted, or garbage input throws a `ZipError` instead of crashing.
- **No surprise permissions** — set-uid/set-gid/sticky bits are stripped on extraction.
- Encrypted entries and unsupported compression methods are cleanly refused with a descriptive error.

## Usage

### Zip and unzip files or folders

```swift
import PureZip

// Compress a folder (or a single file) into a ZIP archive.
try await PureZip.zipItem(at: folderURL, to: archiveURL)

// Extract an archive into a directory (created if needed).
try await PureZip.unzipItem(at: archiveURL, to: destinationURL)

// Both report progress and honor task cancellation.
try await PureZip.zipItem(at: folderURL, to: archiveURL) { progress in
    print("\(progress.completedBytes) of \(progress.totalBytes ?? 0) bytes")
}
```

### Stream an archive to disk (constant memory)

```swift
let writer = try ZipFileWriter(url: archiveURL, level: .normal)
try writer.addDirectory(path: "backup")

// Stream an existing file; only ~512 KiB is in memory at a time.
try writer.addFile(path: "backup/huge-database.sqlite", contentsOf: databaseURL)

// Push-style entry: generate contents on the fly, size unknown upfront.
try writer.addFile(path: "backup/export.csv") { stream in
    for row in rows {
        try stream.write(Data(row.csvLine.utf8))
    }
}

try writer.finalize()
```

### Create an archive in memory

```swift
let writer = ZipWriter(level: .normal)
try writer.addDirectory(path: "docs")
try writer.addFile(path: "docs/readme.txt", data: Data("Hello!".utf8))
try writer.addFile(path: "script.sh", data: scriptData, permissions: 0o755)
let archiveData = writer.finalize()
```

### Read an archive

```swift
let archive = try ZipArchive(url: archiveURL)   // or ZipArchive(data:)

for entry in archive.entries {
    print(entry.path, entry.uncompressedSize, entry.isDirectory)
}

// Extract a single entry into memory (CRC-verified).
let readme = try archive.extractData(at: "docs/readme.txt")

// Extract everything to disk (streams each entry; constant memory).
// Reports progress and honors task cancellation.
try await archive.extractAll(to: destinationURL, overwrite: false)

// Stream a single entry to a file, or consume it in chunks.
try await archive.extract(entry, to: fileURL)
try archive.extract(entry) { chunk in
    hasher.update(data: chunk)
}
```

### Tighten (or relax) the security limits

```swift
let limits = ZipSecurityLimits(
    maxEntryCount: 10_000,
    maxUncompressedEntrySize: 512 << 20,   // 512 MiB per entry
    maxTotalUncompressedSize: 2 << 30      // 2 GiB total
)
let archive = try ZipArchive(url: archiveURL, limits: limits)
```

Defaults: 100,000 entries, 4 GiB per entry, 16 GiB total.

### Read archives with legacy filename encodings

Entry names declared as UTF-8 (or valid UTF-8) are always decoded as UTF-8.
For older archives whose names were written in a system code page, pass the
expected encoding; it is used only when a name is not valid UTF-8, with CP437
(the ZIP specification's default) as the final fallback:

```swift
// From Japanese Windows:
let archive = try ZipArchive(url: archiveURL, legacyNameEncoding: .shiftJIS)

// From classic Mac OS — Foundation's .macOSRoman, or one of the
// script-specific variants PureZip adds (.macOSJapanese, .macOSCyrillic,
// .macOSChineseTraditional, .macOSGreek, ...):
try await PureZip.unzipItem(
    at: archiveURL, to: destinationURL, legacyNameEncoding: .macOSJapanese
)
```

### Error handling

All failures throw `ZipError`, an `Equatable` enum with descriptive cases such as `.notAZipFile`, `.corruptedData`, `.checksumMismatch`, `.unsafePath`, `.limitExceeded`, and `.encryptedEntryUnsupported`.

## Performance

Measured on Apple Silicon (release build, 16 MiB payloads, `.normal` level):

| Payload | Compress | Ratio | Decompress |
|---------|----------|-------|------------|
| Mixed text/binary | ~120 MB/s | 24% | ~460 MB/s |
| Random (incompressible) | ~32 MB/s | stored | >8 GB/s |
| Zero runs | ~900 MB/s | 0.1% | ~12 GB/s |

Run the suite yourself with `swift test -c release` (the `Performance` suite prints throughput).

## Drawbacks and limitations

- **Reading maps the whole archive** — `ZipArchive` works on a (memory-mapped) `Data` of the archive; extraction output streams with constant memory, but the compressed input must be a seekable file or fit in memory. Streamed *writing* has no such constraint.
- **Streamed entries always use DEFLATE** — the store-vs-deflate size comparison only happens for in-memory `addFile(path:data:)`; streamed entries can't be retroactively stored (though incompressible data degrades gracefully to stored blocks inside the DEFLATE stream, costing only ~0.01%). Pass `compress: false` to store explicitly.
- **No encryption** — neither legacy ZipCrypto nor AES; encrypted entries are rejected, never silently skipped.
- **DEFLATE and Store only** — archives using bzip2, LZMA, Zstandard, etc. are refused with `.unsupportedCompressionMethod`.
- **Symbolic links are skipped** on both compression and extraction (a deliberate security trade-off, but it means link-heavy trees don't round-trip).
- **No multi-disk (spanned) archives**, and self-extracting archives with data prepended before the ZIP structure are not recognized.
- **No archive editing** — an existing archive can't be appended to or repacked in place; build a new one instead.
- **Compression ratio** is close to, but not quite, zlib's best; the encoder favors simplicity and speed over squeezing out the last percent.

## Possible future features

- Streaming *input* for reading: open archives from a file handle without mapping, for pipes and network streams
- AES-256 encryption and decryption (and read-only ZipCrypto support)
- Appending to and updating existing archives
- Optional symlink round-tripping behind an explicit opt-in flag
- Zstandard / LZMA entry support
- Async variants of the streaming writer APIs (`ZipWriter`/`ZipFileWriter`)
- Multithreaded compression of independent entries
- Extended timestamp (0x5455) and Unix extra fields for full-fidelity metadata
- Linux support validation and CI

## Requirements

- Swift 6.3+ (uses the `Testing` framework for tests)
- macOS 12+, iOS 15+, tvOS 15+, watchOS 8+, or visionOS 1+
- Foundation (used for `Data`, `URL`, and file-system operations)

## Testing

92 test cases cover round trips across sizes, levels, and content types; streaming compression and extraction (chunked writes, cross-chunk matches, window sliding, partial-file cleanup); tricky filenames (emoji, CJK, combining accents, CP437, very long names); real-world fixtures created by Info-ZIP and zlib; verification of generated archives with the system `unzip`; and the full attack surface: traversal payloads, symlinks, ZIP bombs, lying size headers, flipped bytes, truncation, and garbage input.

```sh
swift test              # fast, debug
swift test -c release   # with meaningful performance numbers
```
