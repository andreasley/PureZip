# PureZip

A pure-Swift ZIP library — read, write, compress, and extract ZIP archives with **no zlib and no C dependencies**. The DEFLATE compressor and decompressor are implemented entirely in Swift.

## Features

- **Read and write ZIP archives**, in memory or on disk
- **Compress files and folders** to `.zip`, extract archives to a directory
- **Pure Swift DEFLATE** (RFC 1951): LZ77 hash-chain matching with lazy evaluation; per-block selection between dynamic Huffman, fixed Huffman, and stored encoding, so output never balloons
- **ZIP64 support**: large sizes/offsets and more than 65,535 entries
- **Automatic store fallback**: entries that don't shrink under DEFLATE are stored uncompressed
- **Robust filename handling**: UTF-8 (flagged and unflagged), the Info-ZIP Unicode Path extra field, and CP437 fallback for legacy archives
- **Metadata**: DOS timestamps and POSIX permissions round-trip through the archive
- **Three compression levels**: `.fastest`, `.normal`, `.maximum`
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
try PureZip.zipItem(at: folderURL, to: archiveURL)

// Extract an archive into a directory (created if needed).
try PureZip.unzipItem(at: archiveURL, to: destinationURL)
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

// Extract everything to disk.
try archive.extractAll(to: destinationURL, overwrite: false)
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

### Error handling

All failures throw `ZipError`, an `Equatable` enum with descriptive cases such as `.notAZipFile`, `.corruptedData`, `.checksumMismatch`, `.unsafePath`, `.limitExceeded`, and `.encryptedEntryUnsupported`.

## Performance

Measured on Apple Silicon (release build, 16 MiB payloads, `.normal` level):

| Payload | Compress | Ratio | Decompress |
|---------|----------|-------|------------|
| Mixed text/binary | ~134 MB/s | 24% | ~435 MB/s |
| Random (incompressible) | ~34 MB/s | stored | >10 GB/s |
| Zero runs | ~1.0 GB/s | 0.1% | ~12 GB/s |

Run the suite yourself with `swift test -c release` (the `Performance` suite prints throughput).

## Drawbacks and limitations

- **In-memory archive building** — `ZipWriter` assembles the whole archive in RAM, and each entry's contents are loaded fully to compress them. Fine for typical documents and app bundles; not suited to multi-gigabyte trees on memory-constrained devices.
- **No encryption** — neither legacy ZipCrypto nor AES; encrypted entries are rejected, never silently skipped.
- **DEFLATE and Store only** — archives using bzip2, LZMA, Zstandard, etc. are refused with `.unsupportedCompressionMethod`.
- **No streaming API** — entries are compressed/decompressed as whole buffers; there is no incremental read/write interface yet.
- **Symbolic links are skipped** on both compression and extraction (a deliberate security trade-off, but it means link-heavy trees don't round-trip).
- **No multi-disk (spanned) archives**, and self-extracting archives with data prepended before the ZIP structure are not recognized.
- **No archive editing** — an existing archive can't be appended to or repacked in place; build a new one instead.
- **Compression ratio** is close to, but not quite, zlib's best; the encoder favors simplicity and speed over squeezing out the last percent.

## Possible future features

- Streaming compression/extraction (constant-memory `ZipWriter` that writes straight to disk, chunked entry readers)
- AES-256 encryption and decryption (and read-only ZipCrypto support)
- Appending to and updating existing archives
- Optional symlink round-tripping behind an explicit opt-in flag
- Zstandard / LZMA entry support
- async/await variants with progress reporting and cancellation
- Multithreaded compression of independent entries
- Extended timestamp (0x5455) and Unix extra fields for full-fidelity metadata
- Linux support validation and CI

## Requirements

- Swift 6.3+ (uses the `Testing` framework for tests)
- Foundation (used for `Data`, `URL`, and file-system operations)

## Testing

74 test cases cover round trips across sizes, levels, and content types; tricky filenames (emoji, CJK, combining accents, CP437, very long names); real-world fixtures created by Info-ZIP and zlib; verification of generated archives with the system `unzip`; and the full attack surface: traversal payloads, symlinks, ZIP bombs, lying size headers, flipped bytes, truncation, and garbage input.

```sh
swift test              # fast, debug
swift test -c release   # with meaningful performance numbers
```
