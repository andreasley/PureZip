import Foundation

/// PureZip — a pure-Swift ZIP library.
///
/// Reads and writes ZIP archives (including ZIP64) with a DEFLATE
/// implementation written entirely in Swift; no zlib or other C dependencies.
///
/// High-level usage:
/// ```swift
/// // Compress a file or folder into a ZIP archive.
/// try await PureZip.zipItem(at: folderURL, to: archiveURL)
///
/// // Extract an archive.
/// try await PureZip.unzipItem(at: archiveURL, to: destinationURL)
///
/// // Work with archives in memory.
/// let writer = ZipWriter()
/// try writer.addFile(path: "readme.txt", data: text)
/// let archiveData = writer.finalize()
///
/// let archive = try ZipArchive(data: archiveData)
/// let restored = try archive.extractData(at: "readme.txt")
/// ```
///
/// Safety: extraction verifies CRC-32 checksums and declared sizes, enforces
/// configurable decompression limits (`ZipSecurityLimits`) to stop ZIP bombs,
/// sanitizes entry paths so no file can be written outside the destination
/// directory, and restricts symbolic links according to `ZipSymlinkPolicy`
/// (by default only links confined to the destination are created).
public enum PureZip {
    /// Compresses a file or directory into a new ZIP archive.
    ///
    /// For a directory, the directory itself becomes the archive's top-level
    /// entry (matching Finder's behavior). Symbolic links inside the tree are
    /// handled according to `symlinkPolicy`; the default (`.confined`)
    /// round-trips links that stay inside the tree — enough for
    /// self-contained structures like macOS framework bundles — and throws
    /// `ZipError.symlinkNotPermitted` for links that point outside it.
    ///
    /// Runs off the caller's actor. Cancelling the surrounding task stops the
    /// operation with `CancellationError` and removes the partial archive.
    ///
    /// - Parameters:
    ///   - sourceURL: File or directory to compress.
    ///   - destinationURL: Where to write the `.zip` file.
    ///   - level: Compression speed/ratio trade-off.
    ///   - symlinkPolicy: How symbolic links inside the tree are handled.
    ///   - overwrite: Replace an existing file at `destinationURL`.
    ///   - progress: Called periodically with a snapshot of the operation's
    ///     progress, measured in uncompressed bytes read.
    @concurrent
    public static func zipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        level: CompressionLevel = .normal,
        symlinkPolicy: ZipSymlinkPolicy = .confined,
        overwrite: Bool = false,
        progress: ZipProgressHandler? = nil
    ) async throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ZipError.entryNotFound(sourceURL.path)
        }

        // Stream straight to disk: neither the archive nor any single entry
        // is held in memory.
        let writer = try ZipFileWriter(url: destinationURL, level: level, overwrite: overwrite)
        do {
            let totalBytes: UInt64
            if isDirectory.boolValue {
                totalBytes = try addDirectoryTree(
                    at: sourceURL, to: writer, symlinkPolicy: symlinkPolicy, progress: progress
                )
            } else {
                totalBytes = fileSize(at: sourceURL) ?? 0
                var completedBytes: UInt64 = 0
                try addFile(
                    at: sourceURL, archivePath: sourceURL.lastPathComponent, to: writer,
                    completedBytes: &completedBytes, totalBytes: totalBytes, progress: progress
                )
            }
            try writer.finalize()
            progress?(ZipProgress(completedBytes: totalBytes, totalBytes: totalBytes, currentPath: nil))
        } catch {
            // Don't leave a partial archive behind.
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    /// Extracts a ZIP archive into a directory, creating it if necessary.
    ///
    /// Runs off the caller's actor and supports task cancellation. See
    /// `ZipArchive.extractAll(to:overwrite:progress:)` for the security
    /// guarantees and progress semantics, and
    /// `ZipArchive.init(url:limits:legacyNameEncoding:)` for the meaning of
    /// `legacyNameEncoding`.
    @concurrent
    public static func unzipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        limits: ZipSecurityLimits = .default,
        legacyNameEncoding: String.Encoding? = nil,
        overwrite: Bool = false,
        progress: ZipProgressHandler? = nil
    ) async throws {
        let archive = try ZipArchive(
            url: sourceURL, limits: limits, legacyNameEncoding: legacyNameEncoding
        )
        try await archive.extractAll(to: destinationURL, overwrite: overwrite, progress: progress)
    }

    // MARK: - Directory traversal

    /// Adds the directory tree rooted at `rootURL` and returns the total
    /// number of file bytes that were read (the progress total).
    private static func addDirectoryTree(
        at rootURL: URL,
        to writer: ZipFileWriter,
        symlinkPolicy: ZipSymlinkPolicy,
        progress: ZipProgressHandler?
    ) throws -> UInt64 {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootName = root.lastPathComponent
        try writer.addDirectory(
            path: rootName,
            modificationDate: modificationDate(at: root) ?? Date(),
            permissions: posixPermissions(at: root) ?? 0o755
        )

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
        ]
        // The path-based enumerator yields relative paths directly. (The
        // URL-based one returns canonicalized /private-prefixed URLs whose
        // prefixes don't reliably match any form of the root URL, which
        // breaks deriving relative paths lexically.)
        guard let enumerator = fileManager.enumerator(atPath: root.path) else {
            throw ZipError.entryNotFound(root.path)
        }

        // Sort for deterministic archive layout.
        var children: [(relativePath: String, url: URL, values: URLResourceValues)] = []
        for case let relativePath as String in enumerator {
            let url = root.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: keys)
            children.append((relativePath, url, values))
        }
        children.sort { $0.relativePath < $1.relativePath }

        // Progress total: every file byte that will be read and compressed.
        var totalBytes: UInt64 = 0
        for child in children
        where child.values.isSymbolicLink != true && child.values.isDirectory != true {
            totalBytes += UInt64(child.values.fileSize ?? 0)
        }

        var completedBytes: UInt64 = 0
        for (relativePath, url, values) in children {
            try Task.checkCancellation()
            let archivePath = rootName + "/" + relativePath
            if values.isSymbolicLink == true {
                try addSymbolicLink(
                    at: url, archivePath: archivePath,
                    linkDirectory: (relativePath as NSString).deletingLastPathComponent,
                    policy: symlinkPolicy, to: writer
                )
                continue
            }
            if values.isDirectory == true {
                try writer.addDirectory(
                    path: archivePath,
                    modificationDate: values.contentModificationDate ?? Date(),
                    permissions: posixPermissions(at: url) ?? 0o755
                )
            } else {
                try addFile(
                    at: url, archivePath: archivePath, to: writer,
                    completedBytes: &completedBytes, totalBytes: totalBytes, progress: progress
                )
            }
        }
        return totalBytes
    }

    /// Archives one symbolic link, enforcing the symlink policy. The
    /// confinement check is lexical, relative to the tree root (of which
    /// `linkDirectory` is the link's directory part).
    private static func addSymbolicLink(
        at url: URL,
        archivePath: String,
        linkDirectory: String,
        policy: ZipSymlinkPolicy,
        to writer: ZipFileWriter
    ) throws {
        guard policy != .reject else {
            throw ZipError.symlinkNotPermitted(archivePath)
        }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        if policy == .confined {
            guard ZipPath.symlinkTargetIsConfined(target, linkDirectory: linkDirectory) else {
                throw ZipError.symlinkNotPermitted(archivePath)
            }
        }
        try writer.addSymbolicLink(
            path: archivePath,
            target: target,
            modificationDate: modificationDate(at: url) ?? Date(),
            permissions: posixPermissions(at: url) ?? 0o755
        )
    }

    /// Streams one file into the writer chunk by chunk, reporting per-chunk
    /// progress and honoring task cancellation between chunks.
    private static func addFile(
        at fileURL: URL,
        archivePath: String,
        to writer: ZipFileWriter,
        completedBytes: inout UInt64,
        totalBytes: UInt64,
        progress: ZipProgressHandler?
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let date = (attributes?[.modificationDate] as? Date) ?? Date()
        let permissions = (attributes?[.posixPermissions] as? NSNumber)
            .map { UInt16(truncatingIfNeeded: $0.uint16Value) } ?? 0o644
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        var completed = completedBytes
        try writer.addFile(
            path: archivePath,
            expectedSize: size,
            modificationDate: date,
            permissions: permissions
        ) { stream in
            while let chunk = try input.read(upToCount: 1 << 19), !chunk.isEmpty {
                try Task.checkCancellation()
                try stream.write(chunk)
                completed += UInt64(chunk.count)
                progress?(ZipProgress(
                    completedBytes: completed, totalBytes: totalBytes, currentPath: archivePath
                ))
            }
        }
        completedBytes = completed
    }

    private static func posixPermissions(at url: URL) -> UInt16? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return UInt16(truncatingIfNeeded: permissions.uint16Value)
    }

    private static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func fileSize(at url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init)
    }
}
