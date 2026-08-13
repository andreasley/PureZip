import Foundation

/// Convenience constants for the classic Mac OS text encodings, for use as
/// `legacyNameEncoding` when reading archives created on pre-OS X systems
/// (e.g. by StuffIt or the classic Finder).
///
/// Foundation already provides `.macOSRoman`; these expose the other common
/// script-specific variants through the same `String.Encoding` type.
public extension String.Encoding {
    /// Classic Mac OS Japanese (a Shift-JIS variant).
    static let macOSJapanese = String.Encoding(classicMac: .macJapanese)
    /// Classic Mac OS Traditional Chinese (Big-5 based).
    static let macOSChineseTraditional = String.Encoding(classicMac: .macChineseTrad)
    /// Classic Mac OS Simplified Chinese (GB 2312 based).
    static let macOSChineseSimplified = String.Encoding(classicMac: .macChineseSimp)
    /// Classic Mac OS Korean (EUC-KR based).
    static let macOSKorean = String.Encoding(classicMac: .macKorean)
    /// Classic Mac OS Cyrillic.
    static let macOSCyrillic = String.Encoding(classicMac: .macCyrillic)
    /// Classic Mac OS Greek.
    static let macOSGreek = String.Encoding(classicMac: .macGreek)
    /// Classic Mac OS Turkish.
    static let macOSTurkish = String.Encoding(classicMac: .macTurkish)
    /// Classic Mac OS Central European (Czech, Polish, Hungarian, ...).
    static let macOSCentralEuropean = String.Encoding(classicMac: .macCentralEurRoman)
    /// Classic Mac OS Hebrew.
    static let macOSHebrew = String.Encoding(classicMac: .macHebrew)
    /// Classic Mac OS Arabic.
    static let macOSArabic = String.Encoding(classicMac: .macArabic)
    /// Classic Mac OS Thai.
    static let macOSThai = String.Encoding(classicMac: .macThai)
    /// Classic Mac OS Croatian.
    static let macOSCroatian = String.Encoding(classicMac: .macCroatian)
    /// Classic Mac OS Icelandic.
    static let macOSIcelandic = String.Encoding(classicMac: .macIcelandic)
    /// Classic Mac OS Romanian.
    static let macOSRomanian = String.Encoding(classicMac: .macRomanian)
}

private extension String.Encoding {
    init(classicMac encoding: CFStringEncodings) {
        self.init(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(encoding.rawValue)
            )
        )
    }
}
