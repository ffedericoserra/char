import Foundation

/// Decode losslessly: an unsupported file must never silently lose characters.
enum PlainText {
    static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(4))
        let encoding: String.Encoding
        let prefixLength: Int
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
            prefixLength = 3
        } else if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            encoding = .utf32LittleEndian
            prefixLength = 4
        } else if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            encoding = .utf32BigEndian
            prefixLength = 4
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            prefixLength = 2
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            prefixLength = 2
        } else {
            encoding = .utf8
            prefixLength = 0
        }
        guard let text = String(data: data.dropFirst(prefixLength), encoding: encoding), !text.contains("\0") else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "This file couldn’t be opened as plain text.",
                                     NSLocalizedRecoverySuggestionErrorKey: "Use a UTF-8 or Unicode text file."])
        }
        return text
    }

    static func encode(_ text: String) -> Data { Data(text.utf8) }
}

