import Foundation

/// A snapshot of a long-running archive operation's progress, measured in
/// uncompressed bytes.
///
/// Delivered to a `ZipProgressHandler` passed to the async operations
/// (`PureZip.zipItem`, `PureZip.unzipItem`, `ZipArchive.extractAll`,
/// `ZipArchive.extract(_:to:)`). Handlers are called synchronously on the
/// operation's task after each processed chunk (roughly every 512 KiB) and
/// once more when the operation completes.
public struct ZipProgress: Sendable {
    /// Uncompressed bytes processed so far.
    public let completedBytes: UInt64
    /// Total uncompressed bytes the operation will process, if known.
    public let totalBytes: UInt64?
    /// Archive path of the entry currently being processed, if any.
    public let currentPath: String?

    /// The completed fraction in `0...1`, or `nil` while the total is unknown.
    public var fraction: Double? {
        guard let totalBytes else { return nil }
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

/// Receives `ZipProgress` snapshots during a long-running archive operation.
public typealias ZipProgressHandler = @Sendable (ZipProgress) -> Void
