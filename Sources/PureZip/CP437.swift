import Foundation

/// Code page 437 (the original IBM PC character set), the encoding the ZIP
/// specification mandates for file names that are not flagged as UTF-8.
enum CP437 {
    /// Characters for bytes 0x80...0xFF.
    private static let highTable: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»" +
        "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀" +
        "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    )

    static func decode(_ bytes: some Sequence<UInt8>) -> String {
        var result = ""
        for byte in bytes {
            if byte < 0x80 {
                result.append(Character(Unicode.Scalar(byte)))
            } else {
                result.append(highTable[Int(byte) - 0x80])
            }
        }
        return result
    }
}
