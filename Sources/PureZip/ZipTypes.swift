import Foundation

/// Compression method of a ZIP entry.
public enum ZipCompressionMethod: Sendable, Equatable {
    /// No compression.
    case store
    /// DEFLATE compression.
    case deflate

    var rawValue: UInt16 {
        switch self {
        case .store: return 0
        case .deflate: return 8
        }
    }

    init?(rawValue: UInt16) {
        switch rawValue {
        case 0: self = .store
        case 8: self = .deflate
        default: return nil
        }
    }
}

/// How symbolic links are handled when compressing directory trees
/// (`PureZip.zipItem`) and when extracting archives.
public enum ZipSymlinkPolicy: Sendable, Equatable {
    /// Throw `ZipError.symlinkNotPermitted` when a symbolic link is encountered.
    case reject
    /// Round-trip symbolic links whose targets are relative and stay
    /// (lexically) inside the tree being compressed or the extraction
    /// destination; throw `ZipError.symlinkNotPermitted` for absolute
    /// targets or targets that escape. The default — it round-trips
    /// self-contained trees like macOS framework bundles while refusing
    /// links that reach outside them.
    case confined
    /// Round-trip all symbolic links verbatim, including absolute targets
    /// and targets pointing outside the destination. Regular file entries
    /// are still never written through a symlink that leads outside the
    /// extraction destination.
    case unrestricted
}

/// Limits that protect against malicious archives (ZIP bombs, resource
/// exhaustion). They apply when opening an archive and when extracting.
///
/// Decompression additionally never produces more data than an entry declares,
/// regardless of these limits, and every extracted entry is verified against
/// its CRC-32 checksum.
public struct ZipSecurityLimits: Sendable {
    /// Maximum number of entries an archive may contain.
    public var maxEntryCount: Int
    /// Maximum uncompressed size of a single entry, in bytes.
    public var maxUncompressedEntrySize: UInt64
    /// Maximum total uncompressed size of all extracted entries, in bytes.
    public var maxTotalUncompressedSize: UInt64
    /// How symbolic link entries are handled during extraction.
    public var symlinkPolicy: ZipSymlinkPolicy

    public init(
        maxEntryCount: Int = 100_000,
        maxUncompressedEntrySize: UInt64 = 4 << 30,   // 4 GiB
        maxTotalUncompressedSize: UInt64 = 16 << 30,  // 16 GiB
        symlinkPolicy: ZipSymlinkPolicy = .confined
    ) {
        self.maxEntryCount = maxEntryCount
        self.maxUncompressedEntrySize = maxUncompressedEntrySize
        self.maxTotalUncompressedSize = maxTotalUncompressedSize
        self.symlinkPolicy = symlinkPolicy
    }

    public static let `default` = ZipSecurityLimits()
}

/// Metadata for a single entry in a ZIP archive.
public struct ZipEntry: Sendable, Hashable {
    /// The path stored in the archive, using `/` separators.
    public let path: String
    /// True if the entry represents a directory.
    public let isDirectory: Bool
    /// True if the entry represents a symbolic link; whether it is extracted
    /// is governed by `ZipSymlinkPolicy`. The entry's contents are the link's
    /// target path.
    public let isSymbolicLink: Bool
    /// Uncompressed size in bytes.
    public let uncompressedSize: UInt64
    /// Compressed size in bytes as stored in the archive.
    public let compressedSize: UInt64
    /// CRC-32 checksum of the uncompressed data.
    public let crc32: UInt32
    /// Modification date from the entry's DOS timestamp.
    public let modificationDate: Date?
    /// POSIX permission bits, if the archive recorded them (Unix origin).
    public let posixPermissions: UInt16?

    /// Raw compression method value.
    let methodRawValue: UInt16
    /// General purpose bit flags.
    let flags: UInt16
    /// Offset of the local file header in the archive.
    let localHeaderOffset: UInt64

    /// The entry's compression method, if supported.
    public var compressionMethod: ZipCompressionMethod? {
        ZipCompressionMethod(rawValue: methodRawValue)
    }

    var isEncrypted: Bool { flags & 0x0001 != 0 || flags & 0x0040 != 0 }
}

// MARK: - DOS timestamps

enum DOSDate {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// Converts DOS date/time fields (local time, 2-second resolution) to a `Date`.
    static func date(dosTime: UInt16, dosDate: UInt16) -> Date? {
        var components = DateComponents()
        components.year = 1980 + Int((dosDate >> 9) & 0x7F)
        components.month = Int((dosDate >> 5) & 0x0F)
        components.day = Int(dosDate & 0x1F)
        components.hour = Int((dosTime >> 11) & 0x1F)
        components.minute = Int((dosTime >> 5) & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day) else { return nil }
        return calendar.date(from: components)
    }

    /// Converts a `Date` to DOS date/time fields, clamped to the representable range.
    static func fields(from date: Date) -> (dosTime: UInt16, dosDate: UInt16) {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = min(max((components.year ?? 1980) - 1980, 0), 127)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2
        let dosDate = UInt16(year << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | second)
        return (dosTime, dosDate)
    }
}

// MARK: - Path handling

enum ZipPath {
    /// Sanitizes an archive entry path for extraction.
    ///
    /// Returns a safe relative path, or nil if the path cannot be made safe:
    /// - Backslashes are treated as separators (some Windows tools use them).
    /// - Leading slashes (absolute paths) are stripped.
    /// - `.` components are dropped.
    /// - Paths containing `..` components, NUL bytes, or Windows drive
    ///   designators (`C:`) are rejected outright.
    static func sanitizedRelativePath(_ raw: String) -> String? {
        guard !raw.contains("\0") else { return nil }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            if component.count == 2, component.hasSuffix(":") { return nil }
            components.append(String(component))
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// Whether a symbolic link target, resolved lexically against the link's
    /// directory (given relative to the tree root), stays inside the tree.
    ///
    /// Absolute targets never qualify. The check is purely lexical: every
    /// `..` must stay at or below the root. Links to other in-tree links
    /// remain confined transitively because each link is checked against
    /// the same rule.
    static func symlinkTargetIsConfined(_ target: String, linkDirectory: String) -> Bool {
        guard !target.isEmpty, !target.contains("\0"), !target.hasPrefix("/") else { return false }
        var depth = linkDirectory.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .count
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                depth -= 1
                if depth < 0 { return false }
            } else {
                depth += 1
            }
        }
        return true
    }

    /// Validates a path being added to an archive by the writer and returns
    /// the normalized form (forward slashes, no leading slash).
    static func normalizedArchivePath(_ path: String, isDirectory: Bool) throws -> String {
        guard !path.contains("\0") else { throw ZipError.invalidPath(path) }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { throw ZipError.invalidPath(path) }
            components.append(String(component))
        }
        guard !components.isEmpty else { throw ZipError.invalidPath(path) }
        return components.joined(separator: "/") + (isDirectory ? "/" : "")
    }
}
