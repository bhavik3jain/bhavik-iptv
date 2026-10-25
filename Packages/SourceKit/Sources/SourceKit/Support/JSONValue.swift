import Foundation

/// A loosely typed JSON value. Providers drift: Stalker sends ids as numbers on
/// one portal and strings on the next, Xtream sends `"1"` for true and `[]` for
/// an empty object. Reading through these accessors keeps every parser
/// tolerant of that without a Codable type per spelling.
///
/// Built with `JSONSerialization` (fast, and a Stalker channel list can run to
/// several megabytes) and converted once into this Sendable value.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses `data`, allowing a bare top-level value. Nil when it isn't JSON.
    init?(data: Data) {
        guard !data.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        self.init(any: any)
    }

    init(any: Any) {
        switch any {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                // 12.0 from a provider that meant 12 reads as an integer.
                if double.rounded() == double, abs(double) < 9.0e15 {
                    self = .int(Int64(double))
                } else {
                    self = .double(double)
                }
            } else {
                self = .int(number.int64Value)
            }
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    // MARK: Navigation

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    /// The first of `keys` holding something other than null or blank text —
    /// for fields every portal spells differently.
    func first(_ keys: String...) -> JSONValue? {
        first(keys)
    }

    func first(_ keys: [String]) -> JSONValue? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case .null: continue
            case .string(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: continue
            default: return value
            }
        }
        return nil
    }

    // MARK: Reading

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var array: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// Text, with numbers written the way a provider would have quoted them.
    /// Nil for null, arrays, objects and blank text.
    var string: String? {
        switch self {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "1" : "0"
        case .null, .array, .object: return nil
        }
    }

    /// An integer from a number or numeric text (`"7"`, `"7.0"`).
    var int: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .double(let value): return Self.integer(value)
        case .bool(let value): return value ? 1 : 0
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) { return value }
            if let value = Double(trimmed) { return Self.integer(value) }
            return nil
        case .null, .array, .object: return nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .bool: return nil
        case .string(let text):
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        case .null, .array, .object: return nil
        }
    }

    /// `true`, a non-zero number, or `"1"`/`"true"`/`"yes"`.
    var truthy: Bool {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            default: return false
            }
        case .null, .array, .object: return false
        }
    }

    /// Elements of an array, or the values of an object in key order — Xtream
    /// sends some lists either way.
    var elements: [JSONValue] {
        switch self {
        case .array(let array): return array
        case .object(let object):
            return object.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { object[$0] }
        default: return []
        }
    }

    /// A double that fits an `Int`, truncated; nil for NaN, infinity and
    /// anything out of range (a corrupt field must not trap).
    private static func integer(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 9.0e18 else { return nil }
        return Int(value)
    }

    // MARK: Reading a field by any of its spellings

    /// Text of the first of `keys` that holds any.
    func string(_ keys: String...) -> String? {
        for key in keys { if let value = self[key]?.string { return value } }
        return nil
    }

    /// An integer from the first of `keys` that holds one.
    func int(_ keys: String...) -> Int? {
        for key in keys { if let value = self[key]?.int { return value } }
        return nil
    }

    /// A number from the first of `keys` that holds one.
    func double(_ keys: String...) -> Double? {
        for key in keys { if let value = self[key]?.double { return value } }
        return nil
    }

    /// True when any of `keys` is truthy.
    func truthy(_ keys: String...) -> Bool {
        keys.contains { self[$0]?.truthy == true }
    }
}
