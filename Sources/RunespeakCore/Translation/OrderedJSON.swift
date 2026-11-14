import Foundation

/// Minimal JSON value with ORDERED object keys.
///
/// JSONEncoder / JSONSerialization write dictionary keys in an order that can differ between
/// runs. Everything in front of the prompt-cache breakpoint must be byte-identical from request
/// to request, and a stable order also makes request bodies easy to assert on in tests.
enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([Pair])

    struct Pair: Sendable, Equatable {
        var key: String
        var value: JSONValue
    }

    /// Builds an object, dropping nil values.
    static func obj(_ pairs: KeyValuePairs<String, JSONValue?>) -> JSONValue {
        .object(pairs.compactMap { key, value in value.map { Pair(key: key, value: $0) } })
    }

    func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .string(let s):
            JSONValue.writeString(s, to: &out)
        case .int(let i):
            out += String(i)
        case .bool(let b):
            out += b ? "true" : "false"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(pair.key, to: &out)
                out += ":"
                pair.value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Control characters, plus U+2028/2029 which some JSON consumers mishandle raw.
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
