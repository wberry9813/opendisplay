import Foundation
import Network
import Darwin
import Testing

private final class StalledPreflightUSB: PreflightUSBIO {
    var networkConnection: NWConnection? { nil }
    var closed = 0
    var opening: ((Bool) -> Void)?
    func open(_ completion: @escaping (Bool) -> Void) { opening = completion }
    func send(_ bytes: Data, completion: @escaping (Bool) -> Void) { Issue.record("stalled open must not send") }
    func read(_ maximum: Int, completion: @escaping (Data?) -> Void) { Issue.record("stalled open must not read") }
    func close() { closed += 1 }
    func detach() -> NWConnection? { Issue.record("stalled open must not transfer"); return nil }
}

@MainActor
private final class PreflightUnixClient {
    let fd: Int32
    private var sequence = 0
    private var framer = EngineControlFramer()
    private var replies: [String: [String: Any]] = [:]
    private(set) var events: [[String: Any]] = []
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    func close() { Darwin.close(fd) }
    func send(_ method: String, _ params: [String: Any] = [:]) throws -> String {
        sequence += 1
        let id = String(sequence)
        let packet = try EngineControlFramer.encode(["v": 1, "kind": "request", "id": id, "method": method, "params": params])
        let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        #expect(sent == packet.count)
        return id
    }
    func reply(_ id: String) async throws -> [String: Any] {
        for _ in 0..<350 {
            if let reply = replies.removeValue(forKey: id) { return reply }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = recv(fd, &bytes, bytes.count, 0)
            if count > 0 {
                for body in try framer.append(Data(bytes.prefix(count))) {
                    if let row = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        if let key = row["id"] as? String { replies[key] = row }
                        if row["kind"] as? String == "event" { events.append(row) }
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PreflightWire.failure("fixtureTimeout")
    }
}

@MainActor
struct PreflightControlTests {
    @Test(arguments: [false, true])
    func activationDispatchSnapshotsOwnerEOFAndRestart(_ eofDuringActivation: Bool) async throws {
        let root = URL(fileURLWithPath: "/tmp/cp3-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "cp3-control-\(UUID().uuidString)")!
        defaults.set(["exact": "12345678-1234-4234-8234-123456789abc"], forKey: DirectEngineController.verifiedIdentityKey)
        defer { defaults.removeObject(forKey: DirectEngineController.verifiedIdentityKey) }
        let peer = try ActivationPeer(eofDuringActivation ? "owner" : "success")
        try await peer.start(); defer { peer.stop() }
        var starts = 0, exited = false
        let engine = DirectEngineController(managed: true, discover: false, screenPermission: { true },
            startSender: { _ in Issue.record("activation dispatched generic sender") }, identityDefaults: defaults,
            makePreflightUSB: { LoopbackUSB(queue: $0, port: peer.listener.port!) },
            startPreparedSender: { sender, ticket in starts += 1; try await sender.adoptPreparedConnection(ticket) })
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 42, udid: "exact", name: nil)])
        let path = root.appendingPathComponent("Direct/engine.sock").path
        let server = LocalControlServer(controller: engine, path: path, ownerExit: { exited = true })
        try server.start(); defer { server.stop() }
        let client = try PreflightUnixClient(path)
        let hello = try await client.reply(client.send("hello"))
        let instance = (hello["result"] as! [String: Any])["engineInstanceID"] as! String
        _ = try await client.reply(client.send("subscribe"))
        let context = UUID().uuidString.lowercased()
        let prepared = try await client.reply(client.send("prepareReceiver", ["receiverID": "install:12345678-1234-4234-8234-123456789abc",
            "mode": "extend", "transportPreference": "usb", "requestContext": context]))
        let proof = try #require(prepared["result"] as? [String: Any])
        let params: [String: Any] = ["engineInstanceID": instance, "requestContext": context, "preparedHandle": proof["preparedHandle"]!]
        let activate = try client.send("activatePreparedReceiver", params)
        if eofDuringActivation {
            for _ in 0..<100 where peer.activationCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(try await client.reply(client.send("listReceivers"))["ok"] as? Bool == true, "control reads remain live during activation")
        } else {
            let committed = try await client.reply(activate)
            #expect(committed["ok"] as? Bool == true)
            let session = try #require(committed["result"] as? [String: Any])
            #expect(session["activationID"] as? String == proof["activationID"] as? String)
            #expect(try await client.reply(client.send("activatePreparedReceiver", params))["ok"] as? Bool == false)
            _ = try await client.reply(client.send("subscribe"))
            _ = try await client.reply(client.send("listReceivers")) // Drain earlier ordered snapshot events.
            #expect(client.events.contains { row in
                row["event"] as? String == "sessionState" &&
                (row["payload"] as? [String: Any])?["activationID"] as? String == proof["activationID"] as? String
            }, "actual subscribed session events retain activation correlation")
        }
        client.close()
        for _ in 0..<100 where !exited { try await Task.sleep(for: .milliseconds(20)) }
        #expect(exited && engine.grant.active == nil && engine.sessions.isEmpty)
        peer.releaseHello(); try await Task.sleep(for: .milliseconds(50))
        #expect(starts == (eofDuringActivation ? 0 : 1))
        // New Engine instance/control-owner cannot restore or consume the old handle.
        let replacement = DirectEngineController(managed: true, discover: false)
        let restarted = LocalControlServer(controller: replacement, path: path, ownerExit: {})
        try restarted.start(); defer { restarted.stop() }
        let fresh = try PreflightUnixClient(path); defer { fresh.close() }
        let newHello = try await fresh.reply(fresh.send("hello"))
        #expect((newHello["result"] as? [String: Any])?["engineInstanceID"] as? String != instance)
        #expect(try await fresh.reply(fresh.send("activatePreparedReceiver", params))["ok"] as? Bool == false)
        #expect(replacement.grant.active == nil && replacement.sessions.isEmpty)
    }

    @Test func slowPrepareCancelReplayAndOwnerEOFOnActualUnixSocket() async throws {
        // Short path is required by Darwin sockaddr_un's 104-byte limit, not SSD convenience.
        let root = URL(fileURLWithPath: "/tmp/cp2-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "cp2-ipc-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(["exact": "12345678-1234-4234-8234-123456789abc"], forKey: DirectEngineController.verifiedIdentityKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = StalledPreflightUSB(), second = StalledPreflightUSB(), third = StalledPreflightUSB()
        var sockets = [first, second, third]
        let engine = DirectEngineController(managed: true, discover: false, screenPermission: { true }, startSender: { _ in
            Issue.record("prepare called media startSender")
        }, identityDefaults: defaults, makePreflightUSB: { _ in sockets.removeFirst() })
        engine.receivedUSBDevices([UsbmuxDevice(deviceID: 42, udid: "exact", name: nil)])
        let generation = engine.grant.generation
        var exited = false
        let path = root.appendingPathComponent("Direct/engine.sock").path
        let server = LocalControlServer(controller: engine, path: path, ownerExit: { exited = true })
        try server.start()
        defer { server.stop() }
        let client = try PreflightUnixClient(path)
        let hello = try await client.reply(client.send("hello"))
        let result = try #require(hello["result"] as? [String: Any])
        #expect((result["capabilities"] as? [String: Any])?["receiverPreflight"] as? Int == 1)
        let instance = try #require(result["engineInstanceID"] as? String)
        let context = UUID().uuidString.lowercased()
        let params: [String: Any] = ["receiverID": "install:12345678-1234-4234-8234-123456789abc", "mode": "extend",
            "transportPreference": "usb", "requestContext": context]
        let preparing = try client.send("prepareReceiver", params)
        #expect(try await client.reply(client.send("listReceivers"))["ok"] as? Bool == true)
        let duplicate = try await client.reply(client.send("prepareReceiver", params))
        #expect((duplicate["error"] as? [String: Any])?["code"] as? String == "preflight.busy")
        let wrong = try await client.reply(client.send("cancelPreparedReceiver", ["engineInstanceID": "wrong", "requestContext": context]))
        #expect(wrong["ok"] as? Bool == false)
        let cancelled = try await client.reply(client.send("cancelPreparedReceiver", ["engineInstanceID": instance, "requestContext": context]))
        #expect((cancelled["result"] as? [String: Any])?["state"] as? String == "cancelled")
        #expect(first.closed == 1)
        #expect(try await client.reply(preparing)["ok"] as? Bool == false)
        #expect(try await client.reply(client.send("activatePreparedReceiver", ["preparedHandle": UUID().uuidString]))["ok"] as? Bool == false)
        #expect(try await client.reply(client.send("cancelPreparedReceiver", ["engineInstanceID": instance, "requestContext": context]))["ok"] as? Bool == true)
        let timed = try client.send("prepareReceiver", params.merging(["requestContext": UUID().uuidString.lowercased()]) { _, new in new })
        let timeout = try await client.reply(timed)
        #expect((timeout["error"] as? [String: Any])?["code"] as? String == "preflight.expired")
        #expect(second.closed == 1)
        _ = try client.send("prepareReceiver", params.merging(["requestContext": UUID().uuidString.lowercased()]) { _, new in new })
        #expect(try await client.reply(client.send("listReceivers"))["ok"] as? Bool == true)
        client.close()
        for _ in 0..<100 where !exited { try await Task.sleep(for: .milliseconds(20)) }
        #expect(exited)
        // EOF retirement is queued ahead of this callback; allow its I/O queue to drain.
        try await Task.sleep(for: .milliseconds(50))
        #expect(third.closed == 1 && engine.grant.active == nil && engine.sessions.isEmpty)
        #expect(engine.grant.generation > generation) // Existing EOF stop revokes generation, not a start.
    }
}
