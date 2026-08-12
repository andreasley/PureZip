import Foundation
import Testing
@testable import PureZip

@Suite("Performance")
struct PerformanceTests {
    /// Round-trips 16 MiB payloads and reports throughput. Functional
    /// correctness is asserted; timings are informational only (run with
    /// `swift test -c release` for meaningful numbers).
    @Test func throughputSmokeTest() throws {
        let size = 16 << 20
        let payloads: [(String, Data)] = [
            ("mixed ", mixedData(count: size, seed: 5)),
            ("random", randomData(count: size, seed: 6)),
            ("zeros ", Data(count: size)),
        ]
        for (label, data) in payloads {
            let start = Date()
            let compressed = data.withUnsafeBytes {
                Deflate.compress($0.bindMemory(to: UInt8.self), level: .normal)
            }
            let afterCompress = Date()
            let decompressed = try compressed.withUnsafeBytes {
                try Inflate.decompress($0, expectedSize: size)
            }
            let afterDecompress = Date()
            #expect(decompressed == data)

            let compressSeconds = max(afterCompress.timeIntervalSince(start), 1e-9)
            let decompressSeconds = max(afterDecompress.timeIntervalSince(afterCompress), 1e-9)
            print(String(
                format: "PureZip %@  compress %6.1f MB/s (ratio %5.1f%%)   decompress %7.1f MB/s",
                label,
                Double(size) / compressSeconds / 1e6,
                Double(compressed.count) * 100 / Double(size),
                Double(size) / decompressSeconds / 1e6
            ))
        }
    }
}
