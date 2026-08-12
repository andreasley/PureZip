import Foundation

/// Errors thrown by PureZip.
public enum ZipError: Error, Equatable, CustomStringConvertible {
    /// The data does not contain a valid ZIP end-of-central-directory record.
    case notAZipFile
    /// The archive ended unexpectedly while reading.
    case truncatedData
    /// The archive contains structurally invalid or inconsistent data.
    case corruptedData(String)
    /// The entry uses a compression method other than Store or Deflate.
    case unsupportedCompressionMethod(UInt16)
    /// The entry is encrypted; PureZip does not support encryption.
    case encryptedEntryUnsupported(String)
    /// The archive uses a feature PureZip does not support (e.g. multi-disk archives).
    case unsupportedFeature(String)
    /// The decompressed data did not match the CRC-32 checksum recorded in the archive.
    case checksumMismatch(String)
    /// The entry path would escape the extraction directory or is otherwise dangerous.
    case unsafePath(String)
    /// A configured security limit was exceeded (see `ZipSecurityLimits`).
    case limitExceeded(String)
    /// The path passed to the writer is not a valid relative archive path.
    case invalidPath(String)
    /// An entry with the same path was already added to the archive.
    case duplicateEntry(String)
    /// The extraction target already exists and `overwrite` was false.
    case destinationExists(String)
    /// No entry with the requested path exists in the archive.
    case entryNotFound(String)
    /// The writer is in a state that does not allow this operation
    /// (e.g. it already failed, was finalized, or an entry is still open).
    case invalidState(String)

    public var description: String {
        switch self {
        case .notAZipFile:
            return "The data is not a ZIP archive."
        case .truncatedData:
            return "The archive ended unexpectedly."
        case .corruptedData(let detail):
            return "The archive is corrupted: \(detail)."
        case .unsupportedCompressionMethod(let method):
            return "Unsupported compression method (\(method))."
        case .encryptedEntryUnsupported(let path):
            return "Entry '\(path)' is encrypted; encryption is not supported."
        case .unsupportedFeature(let detail):
            return "Unsupported ZIP feature: \(detail)."
        case .checksumMismatch(let path):
            return "Checksum mismatch for entry '\(path)'."
        case .unsafePath(let path):
            return "Entry path '\(path)' is unsafe and was rejected."
        case .limitExceeded(let detail):
            return "Security limit exceeded: \(detail)."
        case .invalidPath(let path):
            return "Invalid archive path '\(path)'."
        case .duplicateEntry(let path):
            return "An entry named '\(path)' already exists in the archive."
        case .destinationExists(let path):
            return "Destination '\(path)' already exists."
        case .entryNotFound(let path):
            return "No entry named '\(path)' exists in the archive."
        case .invalidState(let detail):
            return "Invalid operation: \(detail)."
        }
    }
}
