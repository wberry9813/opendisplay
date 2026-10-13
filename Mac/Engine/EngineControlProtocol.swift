import Foundation

struct EngineControlError: Error {
    let code: String
    let message: String
    var retryable = false
    var object: [String: Any] { ["code": code, "message": message, "retryable": retryable] }
}

/// Incremental bounded framing; callers feed at most 16 KiB per socket read.
struct EngineControlFramer {
    static let maximum = 262_144
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximum else {
                throw EngineControlError(code: "protocol.invalidFrame", message: "Invalid frame length")
            }
            guard buffer.count >= length + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(length + 4)
        }
        return frames
    }
    static func encode(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard !body.isEmpty, body.count <= maximum else {
            throw EngineControlError(code: "protocol.invalidFrame", message: "Response too large")
        }
        var result = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        result.append(body)
        return result
    }
}

struct EngineControlRequest {
    let id: String
    let method: String
    let params: [String: Any]
    init(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let method = object["method"] as? String, !method.isEmpty,
              object["kind"] as? String == "request" else {
            throw EngineControlError(code: "protocol.invalidMessage", message: "Expected request object")
        }
        guard let version = object["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else {
            throw EngineControlError(code: "protocol.incompatible", message: "Control major must be 1")
        }
        if let params = object["params"], !(params is [String: Any]) {
            throw EngineControlError(code: "protocol.invalidMessage", message: "params must be an object")
        }
        self.id = id
        self.method = method
        self.params = object["params"] as? [String: Any] ?? [:]
    }
}

enum EngineTransportPreference: String { case auto, usb, wifi }

/// Authority is independent of discovery. Generation tokens reject delayed recovery.
struct ManagedSessionGrant {
    struct Active: Equatable {
        let sessionID: String
        let receiverID: String
        let preference: EngineTransportPreference
    }
    private(set) var active: Active?
    private(set) var generation: UInt64 = 0
    var preference: EngineTransportPreference { active?.preference ?? .auto }
    mutating func start(receiverID: String, preference: EngineTransportPreference) throws -> Active {
        if let active {
            guard active.receiverID == receiverID, active.preference == preference else {
                throw EngineControlError(code: "session.busy", message: "Stop the current session first")
            }
            return active
        }
        generation &+= 1
        let active = Active(sessionID: UUID().uuidString, receiverID: receiverID, preference: preference)
        self.active = active
        return active
    }
    mutating func stop() { generation &+= 1; active = nil }
    func permitsRecovery(generation: UInt64) -> Bool { active != nil && self.generation == generation }
}
