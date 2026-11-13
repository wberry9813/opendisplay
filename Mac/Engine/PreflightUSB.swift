// GPL-3.0. Preflight-only usbmux transaction; legacy Usbmux APIs remain untouched.
import Foundation
import CoreFoundation
import Network

/// Small I/O boundary for deterministic stalled/late-callback tests. All methods and
/// completions are on the operation's serial queue, including the production adapter.
protocol PreflightUSBIO: AnyObject {
    var networkConnection: NWConnection? { get }
    func open(_ completion: @escaping (Bool) -> Void)
    func send(_ bytes: Data, completion: @escaping (Bool) -> Void)
    func read(_ maximum: Int, completion: @escaping (Data?) -> Void)
    func close()
    func detach() -> NWConnection?
}

final class PreflightUSBSocket: PreflightUSBIO {
    private var connection: NWConnection?
    private let queue: DispatchQueue
    var networkConnection: NWConnection? { connection }
    init(queue: DispatchQueue) {
        self.queue = queue
        connection = NWConnection(to: .unix(path: Usbmux.socketPath), using: .tcp)
    }
    func open(_ completion: @escaping (Bool) -> Void) {
        guard let connection else { completion(false); return }
        var completed = false
        connection.stateUpdateHandler = { state in
            guard !completed else { return }
            switch state {
            case .ready: completed = true; completion(true)
            case .failed, .waiting, .cancelled: completed = true; completion(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ bytes: Data, completion: @escaping (Bool) -> Void) {
        guard let connection else { completion(false); return }
        connection.send(content: bytes, completion: .contentProcessed { completion($0 == nil) })
    }
    func read(_ maximum: Int, completion: @escaping (Data?) -> Void) {
        guard let connection else { completion(nil); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, eof, error in
            completion(error == nil && !eof ? data : nil)
        }
    }
    func close() { connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil }
    func detach() -> NWConnection? {
        let result = connection; result?.stateUpdateHandler = nil; connection = nil; return result
    }
}

/// One socket at a time: ListDevices socket, then Connect socket. No Swift task or
/// continuation can outlive cancellation. Completion is settled synchronously once,
/// before late I/O callbacks can run. The enclosing holder owns the fixed deadline.
final class PreflightUSBOperation {
    private let udid: String
    private let expectedDeviceID: Int
    private let factory: () -> PreflightUSBIO
    private var socket: PreflightUSBIO?
    private var completion: ((Result<NWConnection?, EngineControlError>) -> Void)?
    private var generation = 0
    private var terminal = false
    private var bytes = Data()
    private var bodySize: Int?
    private var listing = true
    private(set) var stage = "idle"

    init(udid: String, expectedDeviceID: Int, factory: @escaping () -> PreflightUSBIO) {
        self.udid = udid; self.expectedDeviceID = expectedDeviceID; self.factory = factory
    }
    func start(_ completion: @escaping (Result<NWConnection?, EngineControlError>) -> Void) {
        guard self.completion == nil, !terminal, !udid.isEmpty else { completion(.failure(PreflightWire.failure("invalidMessage"))); return }
        self.completion = completion
        begin()
    }
    private func begin() {
        generation += 1
        let token = generation
        let io = factory(); socket = io; stage = listing ? "list.open" : "connect.open"
        io.open { [weak self] ok in
            guard let self, self.current(token) else { return }
            guard ok else { self.cancel("unavailable"); return }
            do {
                let request: [String: Any] = self.listing ? ["MessageType": "ListDevices"] :
                    ["MessageType": "Connect", "DeviceID": self.expectedDeviceID,
                     "PortNumber": Int(PreflightWire.port.bigEndian)]
                self.stage = self.listing ? "list.send" : "connect.send"
                io.send(try Self.packet(request)) { [weak self] ok in
                    guard let self, self.current(token) else { return }
                    guard ok else { self.cancel("unavailable"); return }
                    self.stage = self.listing ? "list.read" : "connect.read"
                    self.read(token)
                }
            } catch { self.cancel("invalidMessage") }
        }
    }
    static func packet(_ object: [String: Any]) throws -> Data {
        var object = object
        object["ProgName"] = "OpenDisplay"; object["ClientVersionString"] = "OpenDisplay"
        let body = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        guard body.count <= 16368 else { throw PreflightWire.failure() }
        var bytes = Data()
        for field in [UInt32(body.count + 16), 1, 8, 1] {
            withUnsafeBytes(of: field.littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(body); return bytes
    }
    private func current(_ token: Int) -> Bool { !terminal && token == generation }
    private func read(_ token: Int) {
        let target = bodySize.map { $0 + 16 } ?? 16
        socket?.read(target - bytes.count) { [weak self] data in
            guard let self, self.current(token) else { return }
            guard let data, !data.isEmpty, data.count <= target - self.bytes.count else { self.cancel("unavailable"); return }
            self.bytes.append(data)
            if self.bytes.count == 16, self.bodySize == nil {
                let header = [UInt8](self.bytes)
                func word(_ offset: Int) -> UInt32 {
                    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(header[offset + $1]) << ($1 * 8)) }
                }
                let total = Int(word(0))
                guard (17...16384).contains(total), word(4) == 1, word(8) == 8, word(12) == 1 else { self.cancel("invalidMessage"); return }
                self.bodySize = total - 16
            }
            guard let size = self.bodySize, self.bytes.count == size + 16 else { self.read(token); return }
            do {
                guard let reply = try PropertyListSerialization.propertyList(from: Data(self.bytes.dropFirst(16)), format: nil) as? [String: Any] else {
                    self.cancel("invalidMessage"); return
                }
                self.received(reply)
            } catch { self.cancel("invalidMessage") }
        }
    }
    private func received(_ reply: [String: Any]) {
        if listing {
            let devices = (reply["DeviceList"] as? [[String: Any]] ?? []).compactMap {
                Usbmux.device(fromProperties: $0["Properties"] as? [String: Any] ?? [:])
            }.filter { $0.udid == udid }
            guard devices.count == 1, devices[0].deviceID == expectedDeviceID else { cancel("routeChanged"); return }
            socket?.close(); socket = nil; bytes.removeAll(); bodySize = nil; listing = false
            begin()
        } else {
            guard reply["MessageType"] as? String == "Result", let number = reply["Number"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number == 0 else { cancel("unavailable"); return }
            terminal = true; generation += 1; stage = "ready"
            let connection = socket?.detach(); socket = nil
            let completion = self.completion; self.completion = nil
            completion?(.success(connection))
        }
    }
    func cancel(_ code: String = "cancelled") {
        guard !terminal else { return }
        terminal = true; generation += 1; stage = "closed"
        socket?.close(); socket = nil; bytes.removeAll(); bodySize = nil
        let completion = self.completion; self.completion = nil
        completion?(.failure(PreflightWire.failure(code)))
    }
}
