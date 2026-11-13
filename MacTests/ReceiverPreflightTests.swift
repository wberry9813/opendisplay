import Foundation
import Network
import Testing

private let pfInstall = "12345678-1234-4234-8234-123456789abc"

private final class USBFixture: PreflightUSBIO {
    var networkConnection: NWConnection? { nil }
    var opened: ((Bool) -> Void)?
    var sent: ((Bool) -> Void)?
    var reading: ((Data?) -> Void)?
    var closes = 0
    var detached = 0
    var requested = Data()
    var maximum = 0
    func open(_ completion: @escaping (Bool) -> Void) { opened = completion }
    func send(_ bytes: Data, completion: @escaping (Bool) -> Void) { requested = bytes; sent = completion }
    func read(_ maximum: Int, completion: @escaping (Data?) -> Void) { self.maximum = maximum; reading = completion }
    func close() { closes += 1 }
    func detach() -> NWConnection? { detached += 1; return nil }
    func readyForRead() { opened?(true); sent?(true) }
    func reply(_ object: [String: Any]) throws {
        let packet = try PreflightUSBOperation.packet(object)
        let header = reading; header?(Data(packet.prefix(16)))
        reading?(Data(packet.dropFirst(16)))
    }
}

struct ReceiverPreflightTests {
    @Test func exactFramingAtEverySplitAndBounds() throws {
        let body = Data("{\"v\":1}".utf8)
        let packet = try PreflightWire.packet(["v": 1])
        for split in 0...packet.count {
            var frame = PreflightWire.Frame()
            var output: Data?
            // Feeding the exact read allowance models partial header/body reads.
            var offset = 0
            while offset < packet.count {
                let count = min(frame.remaining, max(1, split), packet.count - offset)
                output = try frame.append(Data(packet[offset..<offset + count])) ?? output
                offset += count
            }
            #expect(output == body)
        }
        for size in [0, 16385, Int(UInt32.max)] {
            var frame = PreflightWire.Frame()
            #expect(throws: (any Error).self) {
                try frame.append(withUnsafeBytes(of: UInt32(size).bigEndian) { Data($0) })
            }
        }
        var frame = PreflightWire.Frame()
        let maximum = Data(repeating: 32, count: 16384)
        _ = try frame.append(withUnsafeBytes(of: UInt32(maximum.count).bigEndian) { Data($0) })
        #expect(try frame.append(maximum) == maximum)
    }

    @Test(arguments: [#"{"v":1,"v":1}"#, #"{"v":1,"\u0076":1}"#,
        #"{"a":{"v":1,"v":2}}"#, "{", "[]"])
    func duplicateAndMalformedJSON(_ json: String) {
        #expect(throws: (any Error).self) { try PreflightWire.object(Data(json.utf8)) }
    }
    @Test func strictIntegers() {
        for json in ["true", "1.5", "\"1\"", "0", "65536", "1.0"] {
            let object = try! JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            #expect(PreflightWire.integer(object) == nil)
        }
        #expect(PreflightWire.integer(3) == 3)
    }

    @Test func strictProofAndHelloBinding() throws {
        let probe = UUID().uuidString.lowercased(), activation = UUID().uuidString.lowercased()
        let epoch = UUID().uuidString.lowercased(), nonce = String(repeating: "a", count: 64)
        var hello: [String: Any] = ["type": "hello", "pv": 3, "id": pfInstall,
            "pixelsWide": 1920, "pixelsHigh": 1080, "scale": 2,
            "preflight": ["v": 1, "probeID": probe, "activationID": activation, "receiverEpoch": epoch, "nonce": nonce, "receiverMin": 1]]
        var row: [String: Any] = ["protocol": "sldirect-preflight", "v": 1, "type": "compatibilityReply",
            "probeID": probe, "installID": pfInstall, "receiverEpoch": epoch, "nonce": nonce,
            "receiverPV": 3, "receiverMin": 1, "route": "usb",
            "hello": try JSONSerialization.data(withJSONObject: hello).base64EncodedString()]
        func validate(_ row: [String: Any]) throws -> PreflightWire.Proof {
            try PreflightWire.Proof(JSONSerialization.data(withJSONObject: row), install: pfInstall, probe: probe, activation: activation, route: "usb")
        }
        #expect(try validate(row).receiverPV == 3)
        for field in ["v", "receiverPV", "receiverMin"] {
            for value: Any in [true, "1", 1.5, 0, 65536] {
                var invalid = row; invalid[field] = value
                #expect(throws: (any Error).self) { try validate(invalid) }
            }
        }
        for field in ["probeID", "installID", "receiverEpoch", "nonce", "route", "hello", "type"] {
            var invalid = row; invalid[field] = "wrong"
            #expect(throws: (any Error).self) { try validate(invalid) }
        }
        var unknown = row; unknown["unknown"] = 1
        #expect(throws: (any Error).self) { try validate(unknown) }
        var incompatible = row; incompatible["receiverMin"] = 4
        #expect(throws: (any Error).self) { try validate(incompatible) }
        hello["id"] = UUID().uuidString.lowercased()
        row["hello"] = try JSONSerialization.data(withJSONObject: hello).base64EncodedString()
        #expect(throws: (any Error).self) { try validate(row) }
    }

    @Test(arguments: ["list.open", "list.send", "list.read", "connect.open", "connect.send", "connect.read"])
    func usbCancellationOwnsEveryStage(_ stage: String) throws {
        let first = USBFixture(), second = USBFixture()
        var sockets = [first, second]
        let op = PreflightUSBOperation(udid: "exact", expectedDeviceID: 42, factory: { sockets.removeFirst() })
        var completions = 0
        op.start { _ in completions += 1 }
        if stage != "list.open" { first.opened?(true) }
        if !["list.open", "list.send"].contains(stage) { first.sent?(true) }
        if stage.hasPrefix("connect") {
            try first.reply(["DeviceList": [["Properties": ["ConnectionType": "USB", "DeviceID": 42, "SerialNumber": "exact"]]]])
            if stage != "connect.open" { second.opened?(true) }
            if stage == "connect.read" { second.sent?(true) }
        }
        #expect(op.stage == stage)
        let lateOpen = stage.hasPrefix("list") ? first.opened : second.opened
        let lateSend = stage.hasPrefix("list") ? first.sent : second.sent
        let lateRead = stage.hasPrefix("list") ? first.reading : second.reading
        op.cancel("expired"); op.cancel()
        lateOpen?(true); lateSend?(true); lateRead?(Data(repeating: 0, count: 16))
        #expect(completions == 1)
        #expect(first.closes == 1)
        #expect(second.closes == (stage.hasPrefix("connect") ? 1 : 0))
        #expect(first.detached == 0 && second.detached == 0)
    }
    @Test(arguments: [0, 43])
    func detachOrDeviceIDReplacementRejectsBeforeConnect(_ deviceID: Int) throws {
        let io = USBFixture()
        var made = 0, completed = 0
        let op = PreflightUSBOperation(udid: "exact", expectedDeviceID: 42, factory: { made += 1; return io })
        op.start { _ in completed += 1 }
        io.readyForRead()
        let devices: [[String: Any]] = deviceID == 0 ? [] : [["Properties": ["ConnectionType": "USB", "DeviceID": deviceID, "SerialNumber": "exact"]]]
        try io.reply(["DeviceList": devices])
        #expect(completed == 1 && made == 1 && io.closes == 1)
    }
    @Test func usbExactRouteAndSingleSettlement() throws {
        let first = USBFixture(), second = USBFixture()
        var sockets = [first, second], completions = 0
        let op = PreflightUSBOperation(udid: "exact", expectedDeviceID: 42, factory: { sockets.removeFirst() })
        op.start { result in if case .success = result { completions += 1 } }
        first.readyForRead()
        try first.reply(["DeviceList": [["Properties": ["ConnectionType": "USB", "DeviceID": 99, "SerialNumber": "other"]],
                                       ["Properties": ["ConnectionType": "USB", "DeviceID": 42, "SerialNumber": "exact"]]]])
        second.readyForRead()
        let request = try #require(PropertyListSerialization.propertyList(from: Data(second.requested.dropFirst(16)), format: nil) as? [String: Any])
        #expect(request["DeviceID"] as? Int == 42)
        #expect(request["PortNumber"] as? Int == Int(UInt16(9002).bigEndian))
        try second.reply(["MessageType": "Result", "Number": 0])
        op.cancel(); second.reading?(Data())
        #expect(completions == 1 && second.detached == 1 && second.closes == 0)
    }
}

/// Synthetic usbmux framing boundary, followed by a REAL loopback preflight socket.
final class LoopbackUSB: PreflightUSBIO {
    private let queue: DispatchQueue
    private let port: NWEndpoint.Port
    private var reply = Data()
    var networkConnection: NWConnection? { nil }
    init(queue: DispatchQueue, port: NWEndpoint.Port) { self.queue = queue; self.port = port }
    func open(_ completion: @escaping (Bool) -> Void) { completion(true) }
    func send(_ bytes: Data, completion: @escaping (Bool) -> Void) {
        let row = (try? PropertyListSerialization.propertyList(from: Data(bytes.dropFirst(16)), format: nil)) as? [String: Any]
        let response: [String: Any] = row?["MessageType"] as? String == "ListDevices" ?
            ["DeviceList": [["Properties": ["ConnectionType": "USB", "DeviceID": 42, "SerialNumber": "exact"]]]] :
            ["MessageType": "Result", "Number": 0]
        reply = try! PreflightUSBOperation.packet(response); completion(true)
    }
    func read(_ maximum: Int, completion: @escaping (Data?) -> Void) {
        let data = Data(reply.prefix(maximum)); reply.removeFirst(data.count); completion(data)
    }
    func close() {}
    func detach() -> NWConnection? {
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        conn.start(queue: queue); return conn
    }
}

@MainActor
@Suite(.serialized)
struct PreflightControllerTests {
    @Test func networkBonjourResolvesOnlyPreflightAndOldReceiverIsUnsupported() async throws {
        let queue = DispatchQueue(label: "cp2.bonjour-peer")
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 9002)!)
        let advertisement = try NWListener(using: .tcp, on: .any)
        let mediaDial = DispatchSemaphore(value: 0)
        // Queue-confined test evidence: a ready outbound TCP path alone does not
        // establish that our fixture accepted or decoded the compatibility request.
        var accepts = 0, requests = 0, replies = 0
        listener.stateUpdateHandler = { state in
            print("CP2 Bonjour \(Date()) preflight-listener \(state)")
        }
        advertisement.stateUpdateHandler = { state in
            print("CP2 Bonjour \(Date()) advertisement \(state)")
        }
        advertisement.newConnectionHandler = { conn in mediaDial.signal(); conn.cancel() }
        let name = "CP2-" + UUID().uuidString
        var txt = NWTXTRecord()
        txt["id"] = pfInstall; txt["pv"] = "3"; txt["pf"] = "1"; txt["pfp"] = "9002"
        advertisement.service = NWListener.Service(name: name, type: "_sldirect._tcp", domain: nil, txtRecord: txt)
        listener.newConnectionHandler = { connection in
            accepts += 1
            print("CP2 Bonjour \(Date()) accepted \(connection.endpoint)")
            var frame = PreflightWire.Frame()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: frame.remaining) { data, _, eof, error in
                    print("CP2 Bonjour \(Date()) received bytes=\(data?.count ?? 0) eof=\(eof) error=\(String(describing: error))")
                    guard let data else { return }
                    guard let body = try? frame.append(data) else { receive(); return }
                    guard let request = try? PreflightWire.object(body), let probe = request["probeID"] as? String,
                           let activation = request["activationID"] as? String else { return }
                    requests += 1
                    #expect(body.count == 276, "request plus four-byte prefix must be 280 bytes")
                    #expect(PreflightWire.uuid(probe) != nil && PreflightWire.uuid(activation) != nil)
                    #expect(NSDictionary(dictionary: request).isEqual(to: [
                        "protocol": "sldirect-preflight", "v": 1, "type": "compatibilityRequest",
                        "probeID": probe, "activationID": activation, "expectedInstallID": pfInstall,
                        "enginePV": 3, "engineMin": 1, "route": "network"]))
                    let epoch = UUID().uuidString.lowercased(), nonce = String(repeating: "b", count: 64)
                    var hello: [String: Any] = ["type": "hello", "pv": 3, "id": pfInstall,
                        "pixelsWide": 1920, "pixelsHigh": 1080, "scale": 2,
                        "preflight": ["v": 1, "probeID": probe, "activationID": activation,
                            "receiverEpoch": epoch, "nonce": nonce, "receiverMin": 1]]
                    var reply: [String: Any] = ["protocol": "sldirect-preflight", "v": 1, "type": "compatibilityReply",
                        "probeID": probe, "installID": pfInstall, "receiverEpoch": epoch, "nonce": nonce,
                        "receiverPV": 3, "receiverMin": 1, "route": "network",
                        "hello": try! JSONSerialization.data(withJSONObject: hello).base64EncodedString()]
                    // Match the physical attempt's observed counts through REAL Network
                    // framing/holder/PhoneInfo. Payload was not captured historically:
                    // padding is synthetic, not a reconstruction of that iPad hello.
                    var packet = Data()
                    for padding in 0...600 {
                        hello["fixturePadding"] = String(repeating: "x", count: padding)
                        reply["hello"] = try! JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys]).base64EncodedString()
                        packet = try! PreflightWire.packet(reply)
                        if packet.count == 1181 { break }
                    }
                    #expect(packet.count == 1181 && Array(packet.prefix(4)) == [0, 0, 4, 153])
                    connection.send(content: packet, completion: .contentProcessed { error in
                        print("CP2 Bonjour \(Date()) reply processed error=\(String(describing: error))")
                        #expect(error == nil)
                        if error == nil { replies += 1 }
                    })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
                }
            }
            connection.start(queue: queue); receive()
        }
        listener.start(queue: queue)
        advertisement.start(queue: queue)
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sldirect._tcp", domain: nil), using: .tcp)
        browser.start(queue: queue)
        defer { browser.cancel(); listener.cancel(); advertisement.cancel() }
        var result: NWBrowser.Result?
        for _ in 0..<100 {
            result = browser.browseResults.first { item in
                if case .service(let found, _, _, _) = item.endpoint { return found == name }; return false
            }
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let located = try #require(result, "own synthetic Bonjour receiver must be discovered")
        var permissionCalls = 0
        let engine = DirectEngineController(managed: true, discover: false, screenPermission: { permissionCalls += 1; return true },
            startSender: { _ in Issue.record("network preflight called generic media") })
        engine.receivedBonjourResults([located])
        let owner = UUID(), instance = UUID().uuidString, context = UUID().uuidString.lowercased()
        let reply: Result<[String: Any], EngineControlError> = await withCheckedContinuation { continuation in
            engine.prepareReceiver(receiverID: "install:" + pfInstall, preference: .auto, context: context, owner: owner, instance: instance) { continuation.resume(returning: $0) }
        }
        let evidence = queue.sync { (accepts, requests, replies) }
        print("CP2 Bonjour \(Date()) accepts=\(evidence.0) requests=\(evidence.1) replies=\(evidence.2)")
        #expect(evidence.0 == 1 && evidence.1 == 1 && evidence.2 == 1,
                "own listener must accept, parse exact identity/framing and send one proof")
        #expect(try reply.get()["transport"] as? String == "wifi") // Control label includes TCP cable paths, not guaranteed radio.
        #expect(engine.sessions.isEmpty && engine.grant.active == nil && permissionCalls == 0)
        #expect(mediaDial.wait(timeout: .now()) == .timedOut, "resolver must never open advertised media endpoint")
        // Deterministic browser callbacks, not timing adjacency: identical result must
        // keep the valid holder; withdrawal must retire it without a media start.
        engine.receivedBonjourResults([located])
        let competing: Result<[String: Any], EngineControlError> = await withCheckedContinuation { continuation in
            engine.prepareReceiver(receiverID: "install:" + pfInstall, preference: .auto,
                context: UUID().uuidString.lowercased(), owner: owner, instance: instance) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = competing { #expect(error.code == "preflight.busy") }
        else { Issue.record("unchanged browser result retired a valid proof") }
        engine.receivedBonjourResults([])
        await withCheckedContinuation { continuation in
            engine.cancelPreparedReceiver(context: context, owner: owner, instance: instance) { _ in continuation.resume() }
        }
        #expect(engine.sessions.isEmpty && engine.grant.active == nil && permissionCalls == 0)
        txt["pf"] = nil; txt["pfp"] = nil
        advertisement.service = NWListener.Service(name: name, type: "_sldirect._tcp", domain: nil, txtRecord: txt)
        for _ in 0..<100 {
            result = browser.browseResults.first { item in
                if case .service(let found, _, _, _) = item.endpoint, found == name,
                   case .bonjour(let metadata) = item.metadata { return metadata["pf"] == nil }; return false
            }
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        engine.receivedBonjourResults([try #require(result)])
        let old: Result<[String: Any], EngineControlError> = await withCheckedContinuation { continuation in
            engine.prepareReceiver(receiverID: "install:" + pfInstall, preference: .auto, context: UUID().uuidString.lowercased(), owner: owner, instance: instance) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = old { #expect(error.code == "preflight.unsupported") }
        else { Issue.record("old receiver must not default compatible or dial media") }
        #expect(engine.sessions.isEmpty && engine.grant.active == nil && permissionCalls == 0)
        #expect(mediaDial.wait(timeout: .now()) == .timedOut, "unsupported receiver must not fallback to media")
    }
    private func fixture(port: NWEndpoint.Port, senderCalls: @escaping () -> Void) throws -> DirectEngineController {
        let suite = "cp2-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(["exact": pfInstall], forKey: DirectEngineController.verifiedIdentityKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        return DirectEngineController(managed: true, discover: false, screenPermission: { true },
            startSender: { _ in senderCalls() }, identityDefaults: defaults,
            makePreflightUSB: { LoopbackUSB(queue: $0, port: port) })
    }
    @Test func actualPrepareCancelExpiryNeverCreatesMedia() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "cp2.peer")
        let peerEOF = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            var frame = PreflightWire.Frame()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: frame.remaining) { data, _, _, _ in
                    guard let data else { return }
                    guard let body = try? frame.append(data) else { receive(); return }
                    guard let request = try? PreflightWire.object(body), let probe = request["probeID"] as? String,
                          let activation = request["activationID"] as? String else { return }
                    let epoch = UUID().uuidString.lowercased(), nonce = String(repeating: "a", count: 64)
                    let hello: [String: Any] = ["type": "hello", "pv": 3, "id": pfInstall,
                        "pixelsWide": 1920, "pixelsHigh": 1080, "scale": 2,
                        "preflight": ["v": 1, "probeID": probe, "activationID": activation,
                            "receiverEpoch": epoch, "nonce": nonce, "receiverMin": 1]]
                    let reply: [String: Any] = ["protocol": "sldirect-preflight", "v": 1, "type": "compatibilityReply",
                        "probeID": probe, "installID": pfInstall, "receiverEpoch": epoch, "nonce": nonce,
                        "receiverPV": 3, "receiverMin": 1, "route": "usb",
                        "hello": try! JSONSerialization.data(withJSONObject: hello).base64EncodedString()]
                    connection.send(content: try! PreflightWire.packet(reply), completion: .contentProcessed { _ in })
                    // Keep the actual socket alive until peer EOF; never send media.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in peerEOF.signal(); connection.cancel() }
                }
            }
            connection.start(queue: queue); receive()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }
        for _ in 0..<100 where listener.port == nil { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(listener.port)
        var senderCalls = 0
        let engine = try fixture(port: port, senderCalls: { senderCalls += 1 })
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 42, udid: "exact", name: "Ignored")])
        let generation = engine.grant.generation
        let owner = UUID(), instance = UUID().uuidString, receiver = "install:" + pfInstall
        func prepare(_ context: String) async -> Result<[String: Any], EngineControlError> {
            await withCheckedContinuation { continuation in
                engine.prepareReceiver(receiverID: receiver, preference: .usb, context: context, owner: owner, instance: instance) { continuation.resume(returning: $0) }
            }
        }
        func cancel(_ context: String, as suppliedOwner: UUID? = nil) async {
            await withCheckedContinuation { continuation in
                engine.cancelPreparedReceiver(context: context, owner: suppliedOwner ?? owner, instance: instance) { _ in continuation.resume() }
            }
        }
        let context = UUID().uuidString.lowercased()
        let first = try await prepare(context).get()
        #expect(first["compatible"] as? Bool == true)
        #expect(engine.receiverSnapshots().first?["compatible"] == nil, "preflight proof never upgrades discovery compatibility")
        #expect(engine.grant.active == nil && engine.sessions.isEmpty && senderCalls == 0 && engine.grant.generation == generation)
        if case .success = await prepare(UUID().uuidString.lowercased()) { Issue.record("competing prepare must be busy") }
        await cancel(context, as: UUID()) // Wrong owner must not retire the slot.
        #expect(peerEOF.wait(timeout: .now()) == .timedOut)
        if case .success = await prepare(UUID().uuidString.lowercased()) { Issue.record("wrong-owner cancel cleared slot") }
        await cancel(context); await cancel(context)
        var closed = false
        for _ in 0..<100 {
            if peerEOF.wait(timeout: .now()) == .success { closed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(closed, "cancel barrier results in actual peer EOF, not only a retired token")
        let next = UUID().uuidString.lowercased()
        let second = try await prepare(next).get()
        #expect(first["preparedHandle"] as? String != second["preparedHandle"] as? String)
        await cancel(context) // Stale context cannot cancel replacement.
        if case .success = await prepare(UUID().uuidString.lowercased()) { Issue.record("stale cancel cleared replacement") }
        try await Task.sleep(for: .milliseconds(3200))
        let last = UUID().uuidString.lowercased()
        _ = try await prepare(last).get()
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 43, udid: "exact", name: nil)])
        await cancel(last)
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 42, udid: "exact", name: nil)])
        let detached = UUID().uuidString.lowercased()
        _ = try await prepare(detached).get()
        engine.receivedUSBDevices([])
        await cancel(detached)
        #expect(engine.grant.active == nil && engine.sessions.isEmpty && senderCalls == 0 && engine.grant.generation == generation)
        // Unknown mapping must not invoke a generic USB first-device selection.
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 44, udid: "unknown", name: "Ignored")])
        if case .success = await prepare(UUID().uuidString.lowercased()) { Issue.record("unknown USB mapping admitted") }
    }
}

final class ActivationPeer {
    let queue = DispatchQueue(label: "cp3.activation-peer")
    let listener: NWListener
    let fault: String
    private var peers: [NWConnection] = []
    private var frozen = Data()
    private var helloPending: (() -> Void)?
    private var activations = 0
    private var pongs = 0
    init(_ fault: String) throws { self.fault = fault; listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws {
        listener.newConnectionHandler = { conn in
            self.peers.append(conn); conn.start(queue: self.queue)
            self.read(conn) { request in
                let epoch = UUID().uuidString.lowercased(), nonce = String(repeating: "a", count: 64)
                let binding: [String: Any] = ["v": 1, "probeID": request["probeID"]!, "activationID": request["activationID"]!,
                    "receiverEpoch": epoch, "nonce": nonce, "receiverMin": 1]
                let hello: [String: Any] = ["type": "hello", "pv": 3, "id": pfInstall, "pixelsWide": 1920,
                    "pixelsHigh": 1080, "scale": 2, "preflight": binding]
                self.frozen = try! JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
                let reply: [String: Any] = ["protocol": "sldirect-preflight", "v": 1, "type": "compatibilityReply",
                    "probeID": request["probeID"]!, "installID": pfInstall, "receiverEpoch": epoch, "nonce": nonce,
                    "receiverPV": 3, "receiverMin": 1, "route": "usb", "hello": self.frozen.base64EncodedString()]
                conn.send(content: try! PreflightWire.packet(reply), completion: .contentProcessed { _ in })
                self.read(conn) { activation in
                    self.activations += 1
                    guard self.fault != "eof" else { conn.cancel(); return }
                    var ack = activation; ack["type"] = "activationAck"
                    if self.fault == "nonce" { ack["nonce"] = String(repeating: "b", count: 64) }
                    if self.fault == "epoch" { ack["receiverEpoch"] = UUID().uuidString.lowercased() }
                    conn.send(content: try! PreflightWire.packet(ack), completion: .contentProcessed { _ in })
                    let sendHello = {
                        var bytes = self.frozen
                        if self.fault == "hello" { bytes.append(32) } // Valid JSON, different exact full hello.
                        if self.fault == "version" {
                            var changed = hello; changed["pv"] = 2
                            bytes = try! JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
                        }
                        var frame = withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) }; frame.append(bytes)
                        conn.send(content: frame, completion: .contentProcessed { _ in })
                        conn.send(content: try! PreflightWire.packet(["type": "ping", "t": 123]), completion: .contentProcessed { _ in })
                        func media() {
                            self.read(conn) { row in
                                if row["type"] as? String == "pong" { self.pongs += 1 }
                                else { media() }
                            }
                        }
                        media()
                    }
                    if ["cancel", "route", "owner", "busy"].contains(self.fault) { self.helloPending = sendHello }
                    else { sendHello() }
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { self.listener.stateUpdateHandler = nil; continuation.resume() }
                if case .failed(let error) = state { self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
    }
    private func read(_ conn: NWConnection, completion: @escaping ([String: Any]) -> Void) {
        var frame = PreflightWire.Frame()
        func next() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: frame.remaining) { data, _, eof, error in
                guard error == nil, !eof, let data else { return }
                do {
                    if let body = try frame.append(data) { completion(try PreflightWire.object(body)) }
                    else { next() }
                } catch { Issue.record("invalid activation fixture frame") }
            }
        }
        next()
    }
    var activationCount: Int { queue.sync { activations } }
    var acceptCount: Int { queue.sync { peers.count } }
    var pongCount: Int { queue.sync { pongs } }
    func releaseHello() { queue.async { self.helloPending?(); self.helloPending = nil } }
    func stop() { queue.sync { peers.forEach { $0.cancel() }; peers.removeAll(); listener.cancel() } }
}

extension PreflightControllerTests {
    @Test(arguments: ["success", "nonce", "epoch", "hello", "version", "eof", "cancel", "route", "owner", "busy"])
    func oneShotActivationStrictHelloAndCancellation(_ fault: String) async throws {
        let peer = try ActivationPeer(fault); try await peer.start(); defer { peer.stop() }
        let defaults = UserDefaults(suiteName: "cp3-activation-\(UUID().uuidString)")!
        defaults.set(["exact": pfInstall], forKey: DirectEngineController.verifiedIdentityKey)
        defer { defaults.removeObject(forKey: DirectEngineController.verifiedIdentityKey) }
        var starts = 0, legacyStarts = 0, transferredSocket: NWConnection?
        let engine = DirectEngineController(managed: true, discover: false, screenPermission: { true },
            startSender: { _ in
                legacyStarts += 1
                if fault != "busy" { Issue.record("prepared activation dialed legacy media") }
            }, identityDefaults: defaults,
            makePreflightUSB: { LoopbackUSB(queue: $0, port: peer.listener.port!) },
            startPreparedSender: { sender, ticket in
                starts += 1; transferredSocket = ticket.connection
                try await sender.adoptPreparedConnection(ticket) // Actual transfer; no VD/capture in hostless test.
                let owned = Mirror(reflecting: sender).children.first { $0.label == "connection" }?.value as? NWConnection
                #expect(owned === ticket.connection)
            })
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 42, udid: "exact", name: nil)])
        let owner = UUID(), instance = UUID().uuidString, context = UUID().uuidString.lowercased()
        let prepared = try await withCheckedContinuation { continuation in
            engine.prepareReceiver(receiverID: "install:" + pfInstall, preference: .usb, context: context,
                owner: owner, instance: instance) { continuation.resume(returning: $0) }
        }.get()
        let handle = prepared["preparedHandle"] as! String
        #expect(engine.grant.active == nil && engine.sessions.isEmpty && starts == 0)
        // Wrong owner/instance/context/handle cannot consume the real preparation.
        for wrong in ["owner", "instance", "context", "handle"] {
            let invalid: Result<[String: Any], EngineControlError> = await withCheckedContinuation { continuation in
                engine.activatePreparedReceiver(context: wrong == "context" ? UUID().uuidString.lowercased() : context,
                    handle: wrong == "handle" ? UUID().uuidString.lowercased() : handle,
                    owner: wrong == "owner" ? UUID() : owner, instance: wrong == "instance" ? UUID().uuidString : instance) { continuation.resume(returning: $0) }
            }
            if case .success = invalid { Issue.record("wrong binding consumed handle") }
        }
        var outcome: Result<[String: Any], EngineControlError>?
        engine.activatePreparedReceiver(context: context, handle: handle, owner: owner, instance: instance) { outcome = $0 }
        let replay: Result<[String: Any], EngineControlError> = await withCheckedContinuation { continuation in
            engine.activatePreparedReceiver(context: context, handle: handle, owner: owner, instance: instance) { continuation.resume(returning: $0) }
        }
        if case .success = replay { Issue.record("replayed activation accepted") }
        if ["cancel", "route", "owner", "busy"].contains(fault) {
            for _ in 0..<100 where peer.activationCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(engine.grant.active == nil && engine.sessions.isEmpty && starts == 0, "no constructors before full hello")
            if fault == "route" { engine.receivedUSBDevices([]) }
            if fault == "owner" { engine.stopManagedSession() } // Actual owner-EOF revocation entry.
            if fault == "busy" { _ = try engine.startManagedSession(receiverID: "install:" + pfInstall, preference: .usb) }
            let barrier: [String: Any] = await withCheckedContinuation { continuation in
                engine.cancelPreparedReceiver(context: context, owner: owner, instance: instance) { continuation.resume(returning: $0) }
            }
            #expect(barrier["state"] as? String == "cancelled")
            peer.releaseHello()
        }
        for _ in 0..<400 where outcome == nil { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(outcome)
        if fault == "success" {
            let snapshot = try result.get()
            #expect(snapshot["activationID"] as? String == prepared["activationID"] as? String)
            for _ in 0..<100 where peer.pongCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(starts == 1 && transferredSocket != nil && peer.acceptCount == 1 && peer.activationCount == 1 && peer.pongCount == 1)
            #expect(engine.grant.active != nil && engine.sessions.count == 1)
            let committed: [String: Any] = await withCheckedContinuation { continuation in
                engine.cancelPreparedReceiver(context: context, owner: owner, instance: instance) { continuation.resume(returning: $0) }
            }
            #expect(committed["state"] as? String == "committed")
            #expect((committed["session"] as? [String: Any])?["activationID"] as? String == prepared["activationID"] as? String)
        } else {
            if case .success = result { Issue.record("fault committed a phantom session") }
            if fault == "busy" {
                #expect(engine.grant.active != nil && engine.sessions.count == 1 && starts == 0)
                for _ in 0..<100 where legacyStarts == 0 { try await Task.sleep(for: .milliseconds(10)) }
                #expect(legacyStarts == 1, "only the competing legacy intent owns a session")
            } else { #expect(engine.grant.active == nil && engine.sessions.isEmpty && starts == 0 && legacyStarts == 0) }
        }
        engine.stopManagedSession()
        #expect(engine.managedSessionSnapshot()["activationID"] == nil)
    }
}
