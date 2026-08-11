import Foundation

/// Decodes an HTTP response body into text.
enum TextEncodingSupport {
    /// Decodes a body, honouring the declared charset and otherwise guessing by trial.
    ///
    /// The fallback order is UTF-8, ISO-8859-1, Windows-1252, Shift_JIS, EUC-JP, ASCII. ISO-8859-1
    /// accepts any byte sequence, so nothing after it is ever reached and this practically never
    /// returns `nil`: an unlabelled Shift_JIS page decodes to mojibake rather than failing.
    static func decode(_ data: Data, contentType: String?) -> String? {
        // Read the charset out of Content-Type
        if let contentType = contentType,
           let charset = parseCharset(from: contentType),
           let encoding = stringEncoding(from: charset) {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        // Fallback chain
        let fallbackEncodings: [String.Encoding] = [
            .utf8,
            .isoLatin1,           // ISO-8859-1
            .windowsCP1252,       // Windows-1252
            .shiftJIS,            // Shift_JIS
            .japaneseEUC,         // EUC-JP
            .ascii,
        ]

        for encoding in fallbackEncodings {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        return nil
    }

    /// Pulls the charset value out of a Content-Type header, unquoted and lowercased.
    static func parseCharset(from contentType: String) -> String? {
        // "text/html; charset=UTF-8" → "UTF-8"
        let components = contentType.lowercased().components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                let charset = trimmed.dropFirst("charset=".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return charset
            }
        }
        return nil
    }

    /// Maps a charset name to an encoding.
    ///
    /// Names not listed here go through the IANA charset table, so uncommon encodings still work;
    /// unknown names return `nil` and the caller falls back to guessing.
    static func stringEncoding(from charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "iso_8859-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis", "x-sjis":
            return .shiftJIS
        case "euc-jp", "eucjp", "x-euc-jp":
            return .japaneseEUC
        case "ascii", "us-ascii":
            return .ascii
        case "iso-8859-2", "latin2":
            return .isoLatin2
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        default:
            // Fall back to the IANA charset table for names not listed above
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }
}
