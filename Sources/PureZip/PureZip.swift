import Foundation

/// PureZip — a pure-Swift ZIP library.
///
/// Reads and writes ZIP archives (including ZIP64) with a DEFLATE
/// implementation written entirely in Swift; no zlib or other C dependencies.
///
/// High-level usage:
/// ```swift
/// // Compress a file or folder into a ZIP archive.
/// try PureZip.zipItem(at: folderURL, to: archiveURL)
///
/// // Extract an archive.
/// try PureZip.unzipItem(at: archiveURL, to: destinationURL)
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
/// directory, and never creates symbolic links.
public enum PureZip {
    /// Compresses a file or directory into a new ZIP archive.
    ///
    /// For a directory, the directory itself becomes the archive's top-level
    /// entry (matching Finder's behavior). Symbolic links inside the tree are
    /// skipped.
    ///
    /// - Parameters:
    ///   - sourceURL: File or directory to compress.
    ///   - destinationURL: Where to write the `.zip` file.
    ///   - level: Compression speed/ratio trade-off.
    ///   - overwrite: Replace an existing file at `destinationURL`.
    public static func zipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        level: CompressionLevel = .normal,
        overwrite: Bool = false
    ) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ZipError.entryNotFound(sourceURL.path)
        }

        // Stream straight to disk: neither the archive nor any single entry
        // is held in memory.
        let writer = try ZipFileWriter(url: destinationURL, level: level, overwrite: overwrite)
        do {
            if isDirectory.boolValue {
                try addDirectoryTree(at: sourceURL, to: writer)
            } else {
                try writer.addFile(path: sourceURL.lastPathComponent, contentsOf: sourceURL)
            }
            try writer.finalize()
        } catch {
            // Don't leave a partial archive behind.
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    /// Extracts a ZIP archive into a directory, creating it if necessary.
    ///
    /// See `ZipArchive.extractAll(to:overwrite:)` for the security guarantees.
    public static func unzipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        limits: ZipSecurityLimits = .default,
        overwrite: Bool = false
    ) throws {
        let archive = try ZipArchive(url: sourceURL, limits: limits)
        try archive.extractAll(to: destinationURL, overwrite: overwrite)
    }

    // MARK: - Directory traversal

    private static func addDirectoryTree(at rootURL: URL, to writer: ZipFileWriter) throws {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootName = root.lastPathComponent
        try writer.addDirectory(
            path: rootName,
            modificationDate: modificationDate(at: root) ?? Date(),
            permissions: posixPermissions(at: root) ?? 0o755
        )

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else {
            throw ZipError.entryNotFound(root.path)
        }

        // Sort for deterministic archive layout.
        var children: [(relativePath: String, url: URL)] = []
        let rootPathLength = root.path.count + 1
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let relativePath = String(standardized.path.dropFirst(rootPathLength))
            guard !relativePath.isEmpty else { continue }
            children.append((relativePath, standardized))
        }
        children.sort { $0.relativePath < $1.relativePath }

        for (relativePath, url) in children {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let archivePath = rootName + "/" + relativePath
            if values.isDirectory == true {
                try writer.addDirectory(
                    path: archivePath,
                    modificationDate: values.contentModificationDate ?? Date(),
                    permissions: posixPermissions(at: url) ?? 0o755
                )
            } else {
                // Streams the file's contents; only a small chunk is in memory at a time.
                try writer.addFile(path: archivePath, contentsOf: url)
            }
        }
    }

    private static func posixPermissions(at url: URL) -> UInt16? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return UInt16(truncatingIfNeeded: permissions.uint16Value)
    }

    private static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
