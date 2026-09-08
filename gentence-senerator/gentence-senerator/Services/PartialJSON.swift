import Foundation

/// Reads what has finished out of a JSON document that is still arriving.
///
/// It only understands one shape — an object whose last key holds an array of
/// flat objects — which is why it can be this small. Anything half-written is
/// simply not returned yet, so a caller never sees a torn value.
enum PartialJSON {

    /// The complete elements of the array under `key`, as raw JSON.
    /// A trailing element that is still being written is left out.
    static func elements(ofArrayAt key: String, in text: String) -> [Data] {
        let bytes = Array(text.utf8)
        guard let start = valueStart(afterKey: key, in: bytes),
              start < bytes.count, bytes[start] == UInt8(ascii: "[") else { return [] }

        var out: [Data] = []
        var depth = 0
        var objectStart = 0
        var inString = false
        var escaped = false

        for index in (start + 1)..<bytes.count {
            let byte = bytes[index]
            if escaped { escaped = false; continue }
            if inString {
                if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"):
                if depth == 0 { objectStart = index }
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { out.append(Data(bytes[objectStart...index])) }
            case UInt8(ascii: "]") where depth == 0:
                return out
            default: break
            }
        }
        return out
    }

    /// The value of a top-level string key, but only once it has closed.
    static func string(at key: String, in text: String) -> String? {
        let bytes = Array(text.utf8)
        guard let start = valueStart(afterKey: key, in: bytes),
              start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }

        var escaped = false
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if escaped { escaped = false }
            else if byte == UInt8(ascii: "\\") { escaped = true }
            else if byte == UInt8(ascii: "\"") {
                // Decode through JSONSerialization so escapes are handled once,
                // here, rather than by hand.
                let raw = Data(bytes[start...index])
                let wrapped = Data("{\"v\":".utf8) + raw + Data("}".utf8)
                let object = try? JSONSerialization.jsonObject(with: wrapped) as? [String: Any]
                return object?["v"] as? String
            }
            index += 1
        }
        return nil
    }

    /// The value of a top-level integer key, once a delimiter proves it whole.
    static func integer(at key: String, in text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard let start = valueStart(afterKey: key, in: bytes) else { return nil }
        var index = start
        var digits = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "-") || (byte >= 48 && byte <= 57) {
                digits.append(Character(UnicodeScalar(byte)))
            } else if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}")
                        || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") {
                return Int(digits)
            } else {
                return nil
            }
            index += 1
        }
        return nil   // still arriving; a number is only whole once something follows
    }

    /// The index just past `"key":`, skipping whitespace, or nil.
    private static func valueStart(afterKey key: String, in bytes: [UInt8]) -> Int? {
        let needle = Array("\"\(key)\"".utf8)
        guard let keyEnd = firstIndex(of: needle, in: bytes) else { return nil }
        var index = keyEnd + needle.count
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
        index += 1
        while index < bytes.count,
              bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "\n") {
            index += 1
        }
        return index < bytes.count ? index : nil
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where
            Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }
}
