import Foundation

// MARK: - RPC wire types

nonisolated struct PiAgentRPCEvent: Decodable, Sendable {
    let type: String?
    let id: String?
    let command: String?
    let success: Bool?
    let data: JSONValue?
    let message: JSONValue?
    let messages: JSONValue?
    let toolResults: JSONValue?
    let assistantMessageEvent: JSONValue?
    let toolCallId: String?
    let toolName: String?
    let args: JSONValue?
    let partialResult: JSONValue?
    let result: JSONValue?
    let isError: Bool?
    let error: JSONValue?
    let method: String?
    let title: String?
    let options: JSONValue?
    let placeholder: String?
    let prefill: String?
    let steering: JSONValue?
    let followUp: JSONValue?
    let reason: String?
    let aborted: Bool?
    let willRetry: Bool?
    let errorMessage: String?
}

nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    var compactDescription: String {
        switch self {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        case let .array(value): return value.map(\.compactDescription).joined(separator: ", ")
        case let .object(value):
            return value.keys.sorted().map { key in
                "\(key): \(value[key]?.compactDescription ?? "")"
            }.joined(separator: "\n")
        case .null: return "null"
        }
    }

    /// Bridges a `JSONSerialization` result (a tree of `String`/`NSNumber`/
    /// `Bool`/`NSNull`/`[Any]`/`[String: Any]`) into a strongly-typed
    /// `JSONValue` tree. Returns nil for unsupported types (e.g. `Date`).
    static func fromFoundation(_ value: Any) -> JSONValue? {
        if value is NSNull { return .null }
        if let bool = value as? Bool, type(of: value) is Bool.Type || (value as? NSNumber)?.objCType.pointee == 99 /* 'c' for char/Bool */ {
            return .bool(bool)
        }
        if let number = value as? NSNumber {
            // NSNumber treats Bool as a special case; distinguish via objCType.
            if number.objCType.pointee == 99 { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] {
            return .array(array.compactMap { JSONValue.fromFoundation($0) })
        }
        if let dict = value as? [String: Any] {
            return .object(dict.compactMapValues { JSONValue.fromFoundation($0) })
        }
        return nil
    }
}
