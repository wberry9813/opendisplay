// GPL-3.0: SideLinker Direct fork. Compatibility preparation is not a media session.
import Foundation
import CoreFoundation
import Network
import dnssd
#if DEBUG
import CryptoKit
#endif

/// Diagnostic labels only; never select a cleanup policy or alter the wire result.
enum PreflightCancelReason: String {
    case caller, controllerCaller, legacyStart, managedStop, controlOwnerFinish, controlServerStop
    case usbRouteWithdrawn, bonjourRouteWithdrawn, prepareAuthorityInvalid
    case proofExpiredBeforePublish, proofRouteChangedBeforePublish, ownerCancelRequest
}

enum PreflightWire {
    #if DEBUG
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Whitelisted names/types only: never log arbitrary keys, values or decoder descriptions.
    static func messageShape(_ data: Data) -> [String: String] {
        guard let row = try? object(data) else { return ["json": "invalid", "message_type": "unparsed"] }
        let allowedTypes = ["compatibilityReply", "activationRejected", "activationAck", "hello"]
        let type = row["type"] as? String
        let fields = ["protocol", "v", "type", "probeID", "installID", "receiverEpoch", "nonce",
                      "receiverPV", "receiverMin", "route", "hello", "code", "activationID", "preflight", "id", "pv"]
        return ["json": "valid", "message_type": type.map { allowedTypes.contains($0) ? $0 : "unknown" } ?? "missingOrWrongType",
                "present_fields": fields.filter { row[$0] != nil }.joined(separator: ","),
                "other_field_count": String(row.keys.filter { !fields.contains($0) }.count)]
    }
    static func decodeReason(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch: return "typeMismatch"
        case DecodingError.valueNotFound: return "valueNotFound"
        case DecodingError.keyNotFound: return "keyNotFound"
        case DecodingError.dataCorrupted: return "dataCorrupted"
        default: return "decodeError"
        }
    }
    #endif
    static let port: UInt16 = 9002
    static let maximum = 16_384
    static func failure(_ code: String = "invalidMessage") -> EngineControlError {
        EngineControlError(code: "preflight." + code, message: "Receiver preflight " + code)
    }
    static func uuid(_ value: Any?) -> String? {
        guard let text = value as? String, UUID(uuidString: text)?.uuidString.lowercased() == text else { return nil }
        return text
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: n.objCType)),
              (1...65535).contains(n.intValue), n == NSNumber(value: n.intValue) else { return nil }
        return n.intValue
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximum, String(data: data, encoding: .utf8) != nil else { throw failure() }
        // Check decoded keys independently of Foundation's last-key-wins JSON decoder.
        let bytes = Array(data)
        var stack: [Set<String>?] = []
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 123, 91:
                guard stack.count < 32 else { throw failure() }
                stack.append(bytes[i] == 123 ? Set<String>() : nil)
            case 125, 93:
                guard !stack.isEmpty else { throw failure() }; stack.removeLast()
            case 34:
                let start = i
                i += 1
                while i < bytes.count, bytes[i] != 34 {
                    if bytes[i] == 92 { i += 1 }; i += 1
                }
                guard i < bytes.count else { throw failure() }
                var next = i + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard !stack.isEmpty, var keys = stack[stack.count - 1],
                          let key = try JSONSerialization.jsonObject(with: Data(bytes[start...i]), options: [.fragmentsAllowed]) as? String,
                          keys.insert(key).inserted else { throw failure() }
                    stack[stack.count - 1] = keys
                }
            default: break
            }
            i += 1
        }
        guard stack.isEmpty, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure() }
        return result
    }
    static func packet(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard (1...maximum).contains(body.count) else { throw failure() }
        var result = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        result.append(body); return result
    }
    struct Frame {
        private var bytes = Data()
        private var size: Int?
        var remaining: Int { (size.map { $0 + 4 } ?? 4) - bytes.count }
        #if DEBUG
        var diagnostic: [String: String] {
            ["frame_bytes": String(bytes.count), "frame_sha256": PreflightWire.sha256(bytes),
             "declared_body_bytes": size.map(String.init) ?? "unknown", "remaining": String(remaining)]
        }
        #endif
        mutating func append(_ data: Data) throws -> Data? {
            guard !data.isEmpty, data.count <= remaining else { throw failure() }
            bytes.append(data)
            if size == nil, bytes.count == 4 {
                let value = bytes.reduce(0) { ($0 << 8) | Int($1) }
                guard (1...maximum).contains(value) else { throw failure() }
                size = value
            }
            return size != nil && remaining == 0 ? Data(bytes.dropFirst(4)) : nil
        }
    }
    struct Proof {
        let validatedAt = DispatchTime.now()
        let receiverEpoch: String
        let nonce: String
        let receiverPV: Int
        let receiverMin: Int
        let hello: Data
        let info: PhoneInfo
        init(_ data: Data, install: String, probe: String, activation: String, route: String) throws {
            func invalid(_ reason: String) -> EngineControlError {
                #if DEBUG
                DirectIdentityDiagnostics.event("preflight.proof-rejected", ["probe_fp": DirectIdentityDiagnostics.fingerprint(probe),
                    "stage": reason, "result": "rejected", "reason": reason, "body_bytes": String(data.count)])
                #endif
                return failure()
            }
            let row: [String: Any]
            do { row = try object(data) } catch { throw invalid("replyJSON") }
            guard row["protocol"] as? String == "sldirect-preflight", integer(row["v"]) == 1,
                  uuid(row["probeID"]) == probe else { throw invalid("replyEnvelope") }
            if row["type"] as? String == "activationRejected" {
                guard Set(row.keys) == Set(["protocol", "v", "type", "probeID", "code"]),
                      let code = row["code"] as? String,
                       ["busy", "expired", "wrongTarget", "epochChanged", "incompatible", "invalidMessage", "retiring"].contains(code) else { throw invalid("rejectionEnvelope") }
                #if DEBUG
                DirectIdentityDiagnostics.event("preflight.proof-rejected", ["probe_fp": DirectIdentityDiagnostics.fingerprint(probe),
                    "reason": "receiverRejected", "code": code])
                #endif
                throw failure(code)
            }
            guard Set(row.keys) == Set(["protocol", "v", "type", "probeID", "installID", "receiverEpoch", "nonce", "receiverPV", "receiverMin", "route", "hello"]),
                  row["type"] as? String == "compatibilityReply", uuid(row["installID"]) == install,
                  let epoch = uuid(row["receiverEpoch"]), let nonce = row["nonce"] as? String,
                  nonce.utf8.count == 64, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let pv = integer(row["receiverPV"]), let minimum = integer(row["receiverMin"]), minimum <= pv,
                  pv >= WireProtocol.minSupportedPeer, WireProtocol.version >= minimum,
                  row["route"] as? String == route, let encoded = row["hello"] as? String,
                  encoded.utf8.count <= 10_924, let hello = Data(base64Encoded: encoded),
                  !hello.isEmpty, hello.count <= 8192, hello.base64EncodedString() == encoded else { throw invalid("replyFieldsOrHelloEncoding") }
            let full: [String: Any]
            do { full = try object(hello) } catch { throw invalid("helloJSON") }
            guard full["type"] as? String == "hello", uuid(full["id"]) == install,
                  integer(full["pv"]) == pv, let binding = full["preflight"] as? [String: Any],
                  Set(binding.keys) == Set(["v", "probeID", "activationID", "receiverEpoch", "nonce", "receiverMin"]),
                  integer(binding["v"]) == 1, uuid(binding["probeID"]) == probe,
                  uuid(binding["activationID"]) == activation, uuid(binding["receiverEpoch"]) == epoch,
                  binding["nonce"] as? String == nonce, integer(binding["receiverMin"]) == minimum else { throw invalid("helloBinding") }
            do { self.info = try JSONDecoder().decode(PhoneInfo.self, from: hello) }
            catch {
                #if DEBUG
                DirectIdentityDiagnostics.event("preflight.decode-error", ["probe_fp": DirectIdentityDiagnostics.fingerprint(probe),
                    "stage": "phoneInfo", "reason": decodeReason(error)])
                #endif
                throw invalid("phoneInfoDecode")
            }
            self.receiverEpoch = epoch; self.nonce = nonce; self.receiverPV = pv
            self.receiverMin = minimum; self.hello = hello
        }
    }
}

enum PreflightRoute {
    case usb(String, deviceID: Int)
    case network(NWBrowser.Result, wifiOnly: Bool)
    var wireName: String { if case .usb = self { return "usb" }; return "network" }
    var transport: String { if case .usb = self { return "usb" }; return "wifi" }
}

/// The sole transferred connection. Retains its original Network callback queue;
/// the sender must trampoline callbacks, never start or dial this connection again.
final class PreparedMediaConnection {
    let connection: NWConnection
    let ioQueue: DispatchQueue
    let proof: PreflightWire.Proof
    let commitDeadline: DispatchTime
    init(_ connection: NWConnection, queue: DispatchQueue, proof: PreflightWire.Proof, commitDeadline: DispatchTime) {
        self.connection = connection; self.ioQueue = queue; self.proof = proof
        self.commitDeadline = commitDeadline
    }
    deinit { connection.cancel() }
}

/// Only this holder owns the resolver/socket on its private queue. The controller owns
/// the operation's authority on main. No MacSender, grant or media helper is reachable here.
final class ReceiverPreflightHolder {
    let context: String
    let probe = UUID().uuidString.lowercased()
    let activation = UUID().uuidString.lowercased()
    let handle = UUID().uuidString.lowercased()
    let receiverID: String
    let route: PreflightRoute
    private let install: String
    private let makeUSB: (DispatchQueue) -> PreflightUSBIO
    private let queue = DispatchQueue(label: "com.dmer.sidelinker.direct.preflight")
    private var connection: NWConnection?
    private var resolver: DNSServiceRef?
    private var serviceResolved = false
    private var timer: DispatchSourceTimer?
    private var deadline = DispatchTime.distantFuture
    private var frame = PreflightWire.Frame()
    private var receivedBytes = 0
    private var requestBytes = 0
    private var terminal = false
    private enum Phase { case preparing, prepared, ack, hello }
    private var phase = Phase.preparing
    private var activationCompletion: ((Result<PreparedMediaConnection, EngineControlError>) -> Void)?
    private var completion: ((Result<PreflightWire.Proof, EngineControlError>) -> Void)?
    private var onRetire: (() -> Void)?
    private(set) var proof: PreflightWire.Proof?
    private var expiry: DispatchTime?
    private var interface: NWInterface?
    /// Main-controller snapshot only. I/O never synchronously waits on main, so
    /// reading the one-shot resolver pin here cannot invert queue ownership.
    var pinnedNetworkInterface: NWInterface? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { interface }
    }
    private var usb: PreflightUSBOperation?
    private let prepareDeadline = DispatchTime.now() + .seconds(5)
    #if DEBUG
    private var diagnosticGeneration = "none"
    var diagnosticFields: [String: String] {
        ["context_fp": DirectIdentityDiagnostics.fingerprint(context),
         "holder_fp": DirectIdentityDiagnostics.fingerprint(probe),
         "generation_fp": diagnosticGeneration]
    }
    #endif

    init(context: String, receiverID: String, install: String, route: PreflightRoute,
         diagnosticGeneration: UInt64? = nil,
         makeUSB: @escaping (DispatchQueue) -> PreflightUSBIO = { PreflightUSBSocket(queue: $0) }) {
        self.context = context; self.receiverID = receiverID; self.install = install; self.route = route
        self.makeUSB = makeUSB
        #if DEBUG
        self.diagnosticGeneration = DirectIdentityDiagnostics.fingerprint(diagnosticGeneration.map(String.init))
        #endif
    }
    func start(completion: @escaping (Result<PreflightWire.Proof, EngineControlError>) -> Void,
               onRetire: @escaping () -> Void) {
        queue.async {
            self.completion = completion; self.onRetire = onRetire
            self.arm(self.prepareDeadline)
            switch self.route {
            case .usb(let udid, let deviceID):
                let operation = PreflightUSBOperation(udid: udid, expectedDeviceID: deviceID,
                    factory: { self.makeUSB(self.queue) })
                self.usb = operation
                operation.start { [weak self] result in
                    guard let self, !self.terminal else { return }
                    self.usb = nil
                    switch result {
                    case .success(let connection):
                        guard let connection else { self.fail(PreflightWire.failure("unavailable")); return }
                        self.connection = connection; self.sendRequest()
                    case .failure(let error): self.fail(error)
                    }
                }
            case .network(let result, let wifiOnly): self.resolve(result, wifiOnly: wifiOnly)
            }
        }
    }
    private func arm(_ deadline: DispatchTime) {
        self.deadline = deadline
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in self?.fail(PreflightWire.failure("expired")) }
        self.timer = timer; timer.resume()
    }
    private func resolve(_ result: NWBrowser.Result, wifiOnly: Bool) {
        guard case .bonjour(let txt) = result.metadata, txt["pf"] == "1", txt["pfp"] == "9002",
              case .service(let name, let type, let domain, let endpointInterface) = result.endpoint else {
            fail(PreflightWire.failure("unsupported")); return
        }
        let choices = result.interfaces.filter { !wifiOnly || $0.type == .wifi }
        // Preserve a scoped browse endpoint. Otherwise let DNS-SD select the
        // resolving interface, then pin that actual interface; no app ranking/race.
        let selected = endpointInterface ?? (choices.count == 1 ? choices.first : nil)
        guard !choices.isEmpty, selected == nil || !wifiOnly || selected?.type == .wifi else {
            fail(PreflightWire.failure("routeUnavailable")); return
        }
        interface = selected
        let code = DNSServiceResolve(&resolver, 0, UInt32(selected?.index ?? 0), name, type, domain,
            { _, _, index, error, _, hostname, _, _, _, context in
                guard let context else { return }
                let holder = Unmanaged<ReceiverPreflightHolder>.fromOpaque(context).takeUnretainedValue()
                guard !holder.terminal, !holder.serviceResolved else { return }
                guard DispatchTime.now() < holder.prepareDeadline else { holder.fail(PreflightWire.failure("expired")); return }
                guard error == kDNSServiceErr_NoError, let hostname else { holder.fail(PreflightWire.failure("unavailable")); return }
                guard case .network(let result, let wifiOnly) = holder.route else { return }
                let matched = result.interfaces.first { UInt32($0.index) == index && (!wifiOnly || $0.type == .wifi) }
                // Browse and Resolve can observe interfaces in different orders. An
                // uncaptured answer is not authority to widen the route or retire it:
                // keep this resolver alive within the original preparation deadline.
                guard let matched else { return }
                guard holder.interface == nil || holder.interface?.index == matched.index else { return }
                holder.interface = matched
                holder.serviceResolved = true // Claim once before replacing the resolver.
                let host = String(cString: hostname)
                if let resolver = holder.resolver { DNSServiceRefDeallocate(resolver); holder.resolver = nil }
                // Resolve addresses explicitly without dialing media or asking NWConnection to
                // resolve a Bonjour endpoint at its advertised (media) port.
                holder.resolveAddress(host)
            }, Unmanaged.passUnretained(self).toOpaque())
        guard code == kDNSServiceErr_NoError, let resolver,
              DNSServiceSetDispatchQueue(resolver, queue) == kDNSServiceErr_NoError else {
            fail(PreflightWire.failure("unavailable")); return
        }
    }
    private func resolveAddress(_ host: String) {
        guard let interface else { fail(PreflightWire.failure()); return }
        let code = DNSServiceGetAddrInfo(&resolver, 0, UInt32(interface.index), 0, host,
            { _, flags, _, error, _, address, _, context in
                guard let context else { return }
                let holder = Unmanaged<ReceiverPreflightHolder>.fromOpaque(context).takeUnretainedValue()
                guard !holder.terminal, holder.connection == nil else { return }
                guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0, let address else {
                    holder.fail(PreflightWire.failure("unavailable")); return
                }
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else {
                    holder.fail(PreflightWire.failure()); return
                }
                let literal = String(cString: text) // Includes IPv6 scope when required.
                if let resolver = holder.resolver { DNSServiceRefDeallocate(resolver); holder.resolver = nil }
                holder.dial(literal)
            }, Unmanaged.passUnretained(self).toOpaque())
        guard code == kDNSServiceErr_NoError, let resolver,
              DNSServiceSetDispatchQueue(resolver, queue) == kDNSServiceErr_NoError else { fail(PreflightWire.failure("unavailable")); return }
    }
    private func dial(_ literal: String) {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        if case .network(_, let wifiOnly) = route, wifiOnly { parameters.requiredInterfaceType = .wifi }
        let conn = NWConnection(host: NWEndpoint.Host(literal), port: NWEndpoint.Port(rawValue: PreflightWire.port)!, using: parameters)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, !self.terminal else { return }
            switch state {
            case .ready: self.sendRequest()
            case .failed, .cancelled: self.fail(PreflightWire.failure("unavailable"))
            default: break
            }
        }
        conn.start(queue: queue)
    }
    private func sendRequest() {
        guard !terminal, let connection else { return }
        let request: [String: Any] = ["protocol": "sldirect-preflight", "v": 1, "type": "compatibilityRequest",
            "probeID": probe, "activationID": activation, "expectedInstallID": install,
            "enginePV": WireProtocol.version, "engineMin": WireProtocol.minSupportedPeer, "route": route.wireName]
        do {
            let packet = try PreflightWire.packet(request)
            requestBytes += packet.count
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self, !self.terminal else { return }
                if error != nil { self.fail(PreflightWire.failure("unavailable")) } else { self.read() }
            })
        } catch { fail(PreflightWire.failure()) }
    }
    private func read() {
        guard !terminal, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: frame.remaining) { [weak self] data, _, eof, error in
            guard let self, !self.terminal else { return }
            self.receivedBytes += data?.count ?? 0
            #if DEBUG
            DirectIdentityDiagnostics.event("preflight.receive", ["context_fp": DirectIdentityDiagnostics.fingerprint(self.context),
                "phase": String(describing: self.phase), "bytes": String(data?.count ?? 0),
                "remaining": String(self.frame.remaining), "eof": String(eof), "io_error": String(error != nil)])
            #endif
            do {
                guard DispatchTime.now() < self.deadline else { throw PreflightWire.failure("expired") }
                guard error == nil, !eof, let data, !data.isEmpty else { self.fail(PreflightWire.failure("unavailable")); return }
                let complete: Data?
                do { complete = try self.frame.append(data) }
                catch {
                    #if DEBUG
                    DirectIdentityDiagnostics.event("preflight.frame-error", self.diagnosticFields.merging(self.frame.diagnostic) { _, b in b })
                    #endif
                    throw error
                }
                guard let body = complete else { self.read(); return }
                #if DEBUG
                var frameFields = self.diagnosticFields.merging(self.frame.diagnostic) { _, b in b }
                frameFields.merge(PreflightWire.messageShape(body)) { _, b in b }
                frameFields["complete"] = "true"
                frameFields["phase"] = String(describing: self.phase)
                frameFields["body_bytes"] = String(body.count)
                frameFields["body_sha256"] = PreflightWire.sha256(body)
                DirectIdentityDiagnostics.event("preflight.frame-complete", frameFields)
                #endif
                self.frame = PreflightWire.Frame()
                if self.phase == .ack {
                    let row = try PreflightWire.object(body)
                    guard PreflightWire.integer(row["v"]) == 1,
                          NSDictionary(dictionary: row).isEqual(to: self.activationMessage("activationAck")) else {
                        throw PreflightWire.failure("activationRejected")
                    }
                    self.phase = .hello; self.read(); return
                }
                if self.phase == .hello {
                    guard let proof = self.proof, body.count <= 8192, body == proof.hello else {
                        throw PreflightWire.failure("helloMismatch")
                    }
                    // Exact bytes were strictly parsed with explicit id/PV/binding at prepare.
                    // Parse again before transfer; no ordinary hello handler or constructor runs.
                    let full = try PreflightWire.object(body)
                    guard PreflightWire.uuid(full["id"]) == self.install,
                          PreflightWire.integer(full["pv"]) == proof.receiverPV else { throw PreflightWire.failure("helloMismatch") }
                    _ = try JSONDecoder().decode(PhoneInfo.self, from: body)
                    self.terminal = true; self.timer?.cancel(); self.timer = nil
                    connection.stateUpdateHandler = nil
                    self.connection = nil; self.onRetire = nil
                    let transferred = PreparedMediaConnection(connection, queue: self.queue, proof: proof, commitDeadline: self.deadline)
                    let completion = self.activationCompletion; self.activationCompletion = nil
                    DispatchQueue.main.async { completion?(.success(transferred)) }
                    return // No holder read/handler survives transfer.
                }
                guard self.phase == .preparing else { throw PreflightWire.failure("invalidMessage") }
                let proof = try PreflightWire.Proof(body, install: self.install, probe: self.probe, activation: self.activation, route: self.route.wireName)
                guard DispatchTime.now() < self.prepareDeadline else { self.fail(PreflightWire.failure("expired")); return }
                self.proof = proof
                #if DEBUG
                DirectIdentityDiagnostics.event("preflight.proof-validated", ["context_fp": DirectIdentityDiagnostics.fingerprint(self.context),
                    "holder_fp": DirectIdentityDiagnostics.fingerprint(self.probe), "stage": "complete", "result": "validated",
                    "body_bytes": String(body.count), "hello_bytes": String(proof.hello.count)])
                #endif
                self.phase = .prepared
                self.expiry = proof.validatedAt + .seconds(3); self.arm(self.expiry!)
                let completion = self.completion; self.completion = nil
                DispatchQueue.main.async { completion?(.success(proof)) }
                // This ONE outstanding exact reader observes EOF while prepared, and
                // becomes the ACK reader on activation. Never post a concurrent read.
                self.read()
            } catch let error as EngineControlError { self.fail(error) }
            catch {
                #if DEBUG
                DirectIdentityDiagnostics.event("preflight.decode-error", self.diagnosticFields.merging([
                    "stage": String(describing: self.phase), "reason": PreflightWire.decodeReason(error)]) { _, b in b })
                #endif
                self.fail(PreflightWire.failure())
            }
        }
    }
    private func activationMessage(_ type: String) -> [String: Any] {
        guard let proof else { return [:] }
        return ["protocol": "sldirect-preflight", "v": 1, "type": type, "probeID": probe,
                "activationID": activation, "installID": install, "receiverEpoch": proof.receiverEpoch, "nonce": proof.nonce]
    }
    func activate(completion: @escaping (Result<PreparedMediaConnection, EngineControlError>) -> Void) {
        queue.async {
            guard !self.terminal, self.phase == .prepared, let expiry = self.expiry,
                  DispatchTime.now() < expiry, let connection = self.connection else {
                DispatchQueue.main.async { completion(.failure(PreflightWire.failure("consumedOrUnknown"))) }; return
            }
            self.phase = .ack // one-shot before send/suspension
            self.activationCompletion = completion
            self.arm(.now() + .seconds(3))
            do {
                connection.send(content: try PreflightWire.packet(self.activationMessage("activate")), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.fail(PreflightWire.failure("unavailable")) }
                })
            } catch { self.fail(PreflightWire.failure()) }
        }
    }
    private func fail(_ error: EngineControlError, origin: String = #function, line: Int = #line) {
        guard !terminal else { return }
        #if DEBUG
        DirectIdentityDiagnostics.event("preflight.retire", diagnosticFields.merging([
            "reason": error.code, "origin": origin, "line": String(line), "phase": String(describing: phase),
            "received_bytes": String(receivedBytes), "request_bytes": String(requestBytes),
            "proof_validated": String(proof != nil)]) { _, b in b })
        #endif
        terminal = true; timer?.cancel(); timer = nil
        usb?.cancel(); usb = nil
        if let resolver { DNSServiceRefDeallocate(resolver); self.resolver = nil }
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil; proof = nil
        let completion = self.completion; self.completion = nil
        let retire = onRetire; onRetire = nil
        let activation = activationCompletion; activationCompletion = nil
        DispatchQueue.main.async { completion?(.failure(error)); activation?(.failure(error)); retire?() }
    }
    /// Cancellation barrier: completes only after holder I/O invalidation and socket cleanup.
    func cancel(reason: PreflightCancelReason = .caller, completion: @escaping () -> Void) {
        queue.async {
            #if DEBUG
            DirectIdentityDiagnostics.event("preflight.cancel-call", self.diagnosticFields.merging([
                "reason": reason.rawValue, "terminal": String(self.terminal), "proof_validated": String(self.proof != nil)]) { _, b in b })
            #endif
            self.fail(PreflightWire.failure("cancelled"), origin: reason.rawValue)
            DispatchQueue.main.async(execute: completion)
        }
    }
}
