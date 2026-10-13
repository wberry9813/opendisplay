import Foundation
import Darwin
import Testing

@MainActor
struct LocalControlServerTests {
    // Short /tmp paths are deliberate: Darwin sockaddr_un.sun_path is 104 bytes,
    // and per-run XCTest temporary-directory paths can exceed that limit.
    private func fixture() throws -> (URL, String, DirectEngineController) {
        let root = URL(fileURLWithPath: "/tmp/task09-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return (root, root.appendingPathComponent("Direct/engine.sock").path,
                DirectEngineController(managed: true, discover: false, startSender: { _ in }))
    }

    private func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        return address
    }

    private func connectClient(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        var address = address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    private func response(_ fd: Int32, method: String) async throws -> [String: Any] {
        let frame = try EngineControlFramer.encode(["v": 1, "kind": "request", "id": "test", "method": method])
        let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        #expect(sent == frame.count)
        var framer = EngineControlFramer()
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = recv(fd, &bytes, bytes.count, 0)
            if count > 0, let payload = try framer.append(Data(bytes.prefix(count))).first {
                return try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            }
        }
        throw EngineControlError(code: "fixture.timeout", message: "No socket response")
    }

    @Test func privateSocketSingleInstanceAndSafeCleanup() throws {
        let (root, path, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalControlServer(controller: engine, path: path)
        try first.start()
        defer { first.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Direct").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let socketPermissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(socketPermissions?.intValue == 0o600)
        let otherEngine = DirectEngineController(managed: true, discover: false)
        let second = LocalControlServer(controller: otherEngine, path: path)
        #expect(throws: EngineControlError.self) { try second.start() }
        #expect(FileManager.default.fileExists(atPath: path))
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func unsafeSocketSymlinkNeverRemoved() throws {
        let (root, path, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("valuable")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        let server = LocalControlServer(controller: engine, path: path)
        #expect(throws: EngineControlError.self) { try server.start() }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == target.path)
    }

    @Test func staleOwnedSocketRecovered() throws {
        let (root, path, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        #expect(result == 0)
        let server = LocalControlServer(controller: engine, path: path)
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func actualUnixHelloFirstUnknownMethodAndSecondOwner() async throws {
        let (root, path, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalControlServer(controller: engine, path: path)
        try server.start()
        let client = try connectClient(path)
        defer { server.stop(); close(client) } // Stop server before EOF: test must not terminate XCTest.
        let beforeHello = try await response(client, method: "listReceivers")
        #expect(beforeHello["ok"] as? Bool == false)
        #expect(try await response(client, method: "hello")["ok"] as? Bool == true)
        let unknown = try await response(client, method: "futureMethod")
        #expect((unknown["error"] as? [String: Any])?["code"] as? String == "protocol.unknownMethod")
        #expect(try await response(client, method: "listReceivers")["ok"] as? Bool == true)
        let second = try connectClient(path)
        defer { close(second) }
        try await Task.sleep(for: .milliseconds(50))
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(second, &bytes, bytes.count, 0)
        #expect(count > 0)
        var framer = EngineControlFramer()
        let payload = try #require(try framer.append(Data(bytes.prefix(max(0, count)))).first)
        let rejection = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect((rejection["error"] as? [String: Any])?["code"] as? String == "control.ownerExists")
        #expect(engine.grant.active == nil && engine.sessions.isEmpty)
    }
}
