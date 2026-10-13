import AppKit
import Darwin

/// AF_UNIX only. All descriptors, protocol state and controller calls are main-actor confined.
@MainActor
final class LocalControlServer {
    private let controller: DirectEngineController
    private let path: String
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var owner: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var heartbeat: Timer?
    private var framer = EngineControlFramer()
    private var output = Data()
    private var greeted = false
    private var subscribed = false
    private var exiting = false
    private var deadline = Date.distantFuture
    private var handshakeDeadline = Date.distantFuture
    private var socketInode: ino_t = 0
    private let instanceID = UUID().uuidString

    init(controller: DirectEngineController, path: String? = nil) {
        self.controller = controller
        self.path = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideLinker/Direct/engine.sock").path
    }

    func start() throws {
        do {
            try preparePath()
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw failure("socket") }
            _ = fcntl(listener, F_SETFL, O_NONBLOCK)
            var address = try unixAddress()
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw failure("bind") }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw failure("stat socket") }
            socketInode = info.st_ino
            guard chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { throw failure("listen") }
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
            source.setEventHandler { [weak self] in self?.acceptClients() }
            acceptSource = source
            source.resume()
            controller.onEvent = { [weak self] event, payload in
                guard let self, self.subscribed else { return }
                self.send(["v": 1, "kind": "event", "event": event, "payload": payload])
            }
            heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Date() > self.deadline || Date() > self.handshakeDeadline { self.ownerLost(); return }
                    if self.subscribed { self.controller.publishSnapshots() }
                }
            }
            Log.info("managed engine listening on local Unix socket")
        } catch { stop(); throw error }
    }

    private func failure(_ operation: String) -> EngineControlError {
        EngineControlError(code: "engine.internal", message: "\(operation): \(String(cString: strerror(errno)))")
    }

    private func unixAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngineControlError(code: "engine.internal", message: "Unix socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private func preparePath() throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try validateDirectory(parent)
        var directoryInfo = stat()
        if lstat(directory, &directoryInfo) != 0 {
            guard errno == ENOENT else { throw failure("inspect directory") }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try validateDirectory(directory)
        guard chmod(directory, 0o700) == 0 else { throw failure("chmod directory") }
        lockFD = open(directory + "/engine.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw failure("open lock") }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(),
              lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_nlink == 1,
              fchmod(lockFD, 0o600) == 0,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw EngineControlError(code: "control.ownerExists", message: "Engine already running or unsafe lock")
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw EngineControlError(code: "engine.internal", message: "Refusing unsafe socket replacement")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw failure("stale probe") }
            defer { close(probe) }
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            var address = try unixAddress()
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected < 0, errno == ECONNREFUSED else {
                throw EngineControlError(code: "control.ownerExists", message: "Socket has a live or uncertain owner")
            }
            guard unlink(path) == 0 else { throw failure("unlink stale socket") }
        } else if errno != ENOENT { throw failure("inspect socket") }
    }

    private func validateDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0 else {
            throw EngineControlError(code: "engine.internal", message: "Unsafe control directory")
        }
    }

    private func acceptClients() {
        for _ in 0..<16 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            if owner >= 0 || exiting {
                if let packet = try? EngineControlFramer.encode(["v": 1, "kind": "response", "id": "",
                    "ok": false, "error": EngineControlError(code: "control.ownerExists", message: "One owner only").object]) {
                    packet.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                }
                close(fd)
                continue
            }
            owner = fd
            handshakeDeadline = Date().addingTimeInterval(5) // Fixed, not extended by invalid requests.
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.readOwner() }
            readSource = source
            source.resume()
        }
    }

    private func readOwner() {
        guard owner >= 0, !exiting else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Bound work per dispatch; a flooding client cannot starve teardown.
        for _ in 0..<16 {
            let count = recv(owner, &bytes, bytes.count, 0)
            if count == 0 { ownerLost(); return }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { ownerLost() }
                return
            }
            do {
                for frame in try framer.append(Data(bytes.prefix(count))) {
                    process(frame)
                    if exiting { return }
                }
            } catch {
                sendError(id: "", error: EngineControlError(code: "protocol.invalidFrame", message: "Invalid framing"))
                finish()
                return
            }
        }
    }

    private func process(_ data: Data) {
        let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String ?? ""
        do {
            let request = try EngineControlRequest(data)
            guard greeted || request.method == "hello" else {
                throw EngineControlError(code: "protocol.invalidMessage", message: "hello must be first")
            }
            var result: [String: Any] = [:]
            switch request.method {
            case "hello":
                greeted = true
                handshakeDeadline = .distantFuture
                result = ["protocolVersion": 1, "engineInstanceID": instanceID,
                          "engineVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
                          "capabilities": ["receiverDiscovery": true, "usb": true, "wifi": true, "extend": true, "input": true]]
            case "subscribe": subscribed = true
            case "listReceivers": result = ["receivers": controller.receiverSnapshots()]
            case "startSession":
                guard let receiverID = request.params["receiverID"] as? String,
                      !receiverID.isEmpty, request.params["mode"] as? String == "extend",
                      let raw = request.params["transportPreference"] as? String,
                      let preference = EngineTransportPreference(rawValue: raw) else {
                    throw EngineControlError(code: "protocol.invalidMessage", message: "Expected receiverID, extend and auto/usb/wifi")
                }
                result = try controller.startManagedSession(receiverID: receiverID, preference: preference)
            case "stopSession":
                if let id = request.params["sessionID"] as? String, let active = controller.grant.active,
                   id != active.sessionID {
                    throw EngineControlError(code: "session.notFound", message: "Session ID does not match")
                }
                controller.stopManagedSession()
            case "shutdown": break
            default:
                throw EngineControlError(code: "protocol.unknownMethod", message: "Unsupported method")
            }
            send(["v": 1, "kind": "response", "id": request.id, "ok": true, "result": result])
            if request.method == "subscribe" { controller.publishSnapshots() }
            if request.method == "shutdown" { finish() }
        } catch let error as EngineControlError { sendError(id: id, error: error) }
        catch { sendError(id: id, error: EngineControlError(code: "protocol.invalidMessage", message: "Invalid JSON request")) }
    }

    private func sendError(id: String, error: EngineControlError) {
        send(["v": 1, "kind": "response", "id": id, "ok": false, "error": error.object])
        if subscribed { send(["v": 1, "kind": "event", "event": "diagnostic", "payload": error.object]) }
    }

    private func send(_ object: [String: Any]) {
        guard owner >= 0 else { return }
        guard let packet = try? EngineControlFramer.encode(object), output.count + packet.count <= 1_048_576 else {
            ownerLost(); return
        }
        if output.isEmpty { deadline = Date().addingTimeInterval(10) }
        output.append(packet)
        flush()
    }

    private func flush() {
        guard owner >= 0 else { return }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.send(owner, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: owner, queue: .main)
                        source.setEventHandler { [weak self] in self?.flush() }
                        writeSource = source
                        source.resume()
                    }
                } else { ownerLost() }
                return
            }
            guard count > 0 else { ownerLost(); return }
            output.removeFirst(count)
        }
        writeSource?.cancel()
        writeSource = nil
        deadline = .distantFuture
    }

    private func ownerLost() { finish() }

    private func finish() {
        guard !exiting else { return }
        exiting = true
        controller.stopManagedSession()
        // Brief bounded response drain; no sender/session remains authorized during it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.stop()
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Darwin.exit(0) }
    }

    func stop() {
        controller.onEvent = nil
        controller.stopManagedSession()
        heartbeat?.invalidate(); heartbeat = nil
        acceptSource?.cancel(); acceptSource = nil
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        if owner >= 0 { close(owner); owner = -1 }
        if listener >= 0 { close(listener); listener = -1 }
        var info = stat()
        if socketInode != 0, lstat(path, &info) == 0, info.st_ino == socketInode,
           info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
        socketInode = 0
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }
}
