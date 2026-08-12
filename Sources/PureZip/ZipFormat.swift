import Foundation

/// A finished entry awaiting its central directory record.
struct ZipEntryRecord {
    var nameBytes: [UInt8]
    var flags: UInt16
    var method: UInt16
    var dosTime: UInt16
    var dosDate: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localHeaderOffset: UInt64
    var externalAttributes: UInt32
}

/// Serialization of the archive-level ZIP structures shared by the in-memory
/// and streaming writers.
enum ZipFormat {
    /// Builds the central directory, the ZIP64 end records when required, and
    /// the end-of-central-directory record, assuming the central directory
    /// starts at absolute archive offset `centralDirectoryOffset`.
    static func centralDirectory(
        records: [ZipEntryRecord], startingAt centralDirectoryOffset: UInt64
    ) -> [UInt8] {
        var output: [UInt8] = []

        for record in records {
            var zip64Fields: [UInt64] = []
            if record.uncompressedSize >= 0xFFFF_FFFF { zip64Fields.append(record.uncompressedSize) }
            if record.compressedSize >= 0xFFFF_FFFF { zip64Fields.append(record.compressedSize) }
            if record.localHeaderOffset >= 0xFFFF_FFFF { zip64Fields.append(record.localHeaderOffset) }
            let extraLength = zip64Fields.isEmpty ? 0 : 4 + 8 * zip64Fields.count

            output.appendLE32(0x0201_4B50)
            output.appendLE16((3 << 8) | 20) // made by: Unix, PKZIP 2.0
            output.appendLE16(zip64Fields.isEmpty ? 20 : 45)
            output.appendLE16(record.flags)
            output.appendLE16(record.method)
            output.appendLE16(record.dosTime)
            output.appendLE16(record.dosDate)
            output.appendLE32(record.crc32)
            output.appendLE32(record.compressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(record.compressedSize))
            output.appendLE32(record.uncompressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(record.uncompressedSize))
            output.appendLE16(UInt16(record.nameBytes.count))
            output.appendLE16(UInt16(extraLength))
            output.appendLE16(0) // comment length
            output.appendLE16(0) // disk number start
            output.appendLE16(0) // internal attributes
            output.appendLE32(record.externalAttributes)
            output.appendLE32(record.localHeaderOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(record.localHeaderOffset))
            output.append(contentsOf: record.nameBytes)
            if !zip64Fields.isEmpty {
                output.appendLE16(0x0001)
                output.appendLE16(UInt16(8 * zip64Fields.count))
                for field in zip64Fields { output.appendLE64(field) }
            }
        }

        let centralDirectorySize = UInt64(output.count)
        let entryCount = UInt64(records.count)
        let needsZip64End = entryCount >= 0xFFFF
            || centralDirectorySize >= 0xFFFF_FFFF
            || centralDirectoryOffset >= 0xFFFF_FFFF

        if needsZip64End {
            let zip64EndOffset = centralDirectoryOffset + centralDirectorySize
            output.appendLE32(0x0606_4B50)
            output.appendLE64(44) // size of the remainder of this record
            output.appendLE16((3 << 8) | 45)
            output.appendLE16(45)
            output.appendLE32(0) // this disk
            output.appendLE32(0) // central directory disk
            output.appendLE64(entryCount)
            output.appendLE64(entryCount)
            output.appendLE64(centralDirectorySize)
            output.appendLE64(centralDirectoryOffset)

            output.appendLE32(0x0706_4B50) // locator
            output.appendLE32(0)
            output.appendLE64(zip64EndOffset)
            output.appendLE32(1)
        }

        output.appendLE32(0x0605_4B50)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(entryCount >= 0xFFFF ? 0xFFFF : UInt16(entryCount))
        output.appendLE16(entryCount >= 0xFFFF ? 0xFFFF : UInt16(entryCount))
        output.appendLE32(centralDirectorySize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirectorySize))
        output.appendLE32(centralDirectoryOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirectoryOffset))
        output.appendLE16(0) // comment length

        return output
    }
}
