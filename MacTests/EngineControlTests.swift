import Foundation
import Network
import Testing

struct EngineControlTests {
    @Test func identityDiagnosticFingerprintsAreStableAndNotRaw() {
        #expect(DirectIdentityDiagnostics.fingerprint("abc") == "ba7816bf8f01cfea")
        #expect(DirectIdentityDiagnostics.fingerprint(nil) == "none")
        #expect(DirectIdentityDiagnostics.comparisonFingerprint(" 00008020-ABC\n") == DirectIdentityDiagnostics.fingerprint("00008020-abc"))
        #expect(!DirectIdentityDiagnostics.fingerprint("private-serial").contains("private-serial"))
    }
    @Test func fragmentedAndCoalescedFrames() throws {
        let packet = try EngineControlFramer.encode(["v": 1, "kind": "request", "id": "a", "method": "hello"])
        var framer = EngineControlFramer()
        var frames: [Data] = []
        for byte in packet { frames += try framer.append(Data([byte])) }
        #expect(frames.count == 1)
        #expect(try EngineControlRequest(frames[0]).method == "hello")
        #expect(try framer.append(packet + packet).count == 2)
    }

    @Test(arguments: [0, 262_145, Int(UInt32.max)])
    func invalidFrameSizes(length: Int) {
        var framer = EngineControlFramer()
        let header = withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) }
        #expect(throws: EngineControlError.self) { try framer.append(header) }
    }

    @Test func maximumFrameAndTrailingFragment() throws {
        let payload = Data(repeating: 32, count: EngineControlFramer.maximum)
        let header = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        var framer = EngineControlFramer()
        #expect(try framer.append(header + payload + Data([0, 0])).first == payload)
        #expect(try framer.append(Data([0, 1, 123])) == [Data([123])])
    }

    @Test(arguments: ["[]", "{}", #"{"v":true,"kind":"request","id":"a","method":"hello"}"#,
        #"{"v":2,"kind":"request","id":"a","method":"hello"}"#,
        #"{"v":1,"kind":"event","id":"a","method":"hello"}"#,
        #"{"v":1,"kind":"request","id":"","method":"hello"}"#,
        #"{"v":1,"kind":"request","id":"a","method":"hello","params":[]}"#])
    func invalidMessages(json: String) {
        #expect(throws: (any Error).self) { try EngineControlRequest(Data(json.utf8)) }
    }

    @Test func optionalFieldsIgnored() throws {
        let request = try EngineControlRequest(Data(#"{"v":1,"kind":"request","id":"a","method":"hello","future":5,"params":{"future":true}}"#.utf8))
        #expect(request.id == "a")
    }

    @Test func grantIsIdempotentBusyAndRevocable() throws {
        var grant = ManagedSessionGrant()
        #expect(!grant.permitsRecovery(generation: 0))
        let first = try grant.start(receiverID: "fixture", preference: .usb)
        let token = grant.generation
        #expect(first == (try grant.start(receiverID: "fixture", preference: .usb)))
        #expect(throws: EngineControlError.self) { try grant.start(receiverID: "other", preference: .usb) }
        #expect(throws: EngineControlError.self) { try grant.start(receiverID: "fixture", preference: .wifi) }
        #expect(grant.permitsRecovery(generation: token))
        grant.stop()
        grant.stop()
        #expect(!grant.permitsRecovery(generation: token))
        let next = try grant.start(receiverID: "fixture", preference: .auto)
        #expect(first.sessionID != next.sessionID)
        #expect(!grant.permitsRecovery(generation: token))
    }

    @Test func installIdentityDedupeNotNameDedupe() {
        #expect(!ReceiverSnapshot.sameDevice(serviceInstallID: "1", usbInstallID: "2"))
        #expect(!ReceiverSnapshot.sameDevice(serviceInstallID: "1", usbInstallID: "1"), "unknown identities fail closed")
        #expect(!ReceiverSnapshot.sameDevice(serviceInstallID: nil, usbInstallID: nil))
        #expect(!ReceiverSnapshot.sameDevice(serviceInstallID: "1", usbInstallID: nil))
        let rows: [[String: Any]] = [
            ["receiverID": "install:1", "name": "iPad", "transports": ["usb"], "usbUDIDs": ["udid-1"]],
            ["receiverID": "install:1", "name": "Renamed", "transports": ["wifi"]],
            ["receiverID": "install:2", "name": "iPad", "transports": ["wifi"]]]
        let snapshot = ReceiverSnapshot.deduplicate(rows)
        #expect(snapshot.count == 2)
        #expect(snapshot[0]["transports"] as? [String] == ["usb", "wifi"])
        #expect(snapshot[0]["usbUDIDs"] as? [String] == ["udid-1"])
        #expect(snapshot[1]["receiverID"] as? String == "install:2")
    }
}

@MainActor
struct EngineControllerTests {
    @Test(arguments: [false, true])
    func canonicalHelloKeepsOneConnectableInstall(lowercaseFirst: Bool) async throws {
        let suite = "stage-f-identity-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let install = "ab000000-0000-4000-8000-000000000001"
        let device = UsbmuxDevice(deviceID: 987_101, udid: "stage-f-usb", name: "Same")
        let engine = DirectEngineController(managed: true, discover: false,
            screenPermission: { true }, startSender: { _ in }, identityDefaults: defaults)
        let queue = DispatchQueue(label: "stage-f-bonjour")
        let advertisement = try NWListener(using: .tcp, on: .any)
        let name = "StageF-\(UUID())"
        var txt = NWTXTRecord(); txt["id"] = install.uppercased()
        advertisement.service = NWListener.Service(name: name, type: "_sldirect._tcp", domain: nil, txtRecord: txt)
        advertisement.newConnectionHandler = { $0.cancel() }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sldirect._tcp", domain: nil), using: .tcp)
        advertisement.start(queue: queue); browser.start(queue: queue)
        defer { browser.cancel(); advertisement.cancel() }
        var located: NWBrowser.Result?
        for _ in 0..<100 {
            located = browser.browseResults.first { result in
                if case .service(let found, _, _, _) = result.endpoint { return found == name }; return false
            }
            if located != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let service = try #require(located, "own Bonjour fixture must be observable")
        engine.receivedUSBDevices([device])
        _ = try engine.startManagedSession(receiverID: "device:\(device.udid)", preference: .usb)
        let session = try #require(engine.sessions.first)
        for id in lowercaseFirst ? [install, install.uppercased()] : [install.uppercased(), install] {
            let data = try JSONSerialization.data(withJSONObject: ["pixelsWide": 1920, "pixelsHigh": 1080, "scale": 2, "id": id])
            session.sender.onHello?(try JSONDecoder().decode(PhoneInfo.self, from: data))
            engine.receivedBonjourResults([service])
            #expect(engine.receiverSnapshots().count == 1)
            #expect(engine.receiverSnapshots().first?["receiverID"] as? String == "install:\(install)")
            #expect(engine.receiverSnapshots().first?["transports"] as? [String] == ["usb", "wifi"])
            #expect(ReceiverSnapshot.sameDevice(serviceInstallID: install.uppercased(), usbInstallID: id))
            _ = try engine.preflightRoute(receiverID: "install:\(id)", preference: .usb)
        }
        engine.stopManagedSession()
        engine.receivedBonjourResults([])
        engine.receivedUSBDevices([])
        engine.receivedUSBDevices([device])
        engine.receivedBonjourResults([service])
        #expect(engine.receiverSnapshots().count == 1)
        _ = try engine.startManagedSession(receiverID: "install:\(install.uppercased())", preference: .usb)
        #expect(engine.sessions.count == 1)
        engine.stopManagedSession()
        #expect(!ReceiverSnapshot.sameDevice(serviceInstallID: UUID().uuidString, usbInstallID: install))
        #expect(!ReceiverSnapshot.sameDevice(serviceInstallID: "unknown", usbInstallID: "unknown"))
        // Two actual USB routes claiming the same install are not made connectable by grouping.
        let other = UsbmuxDevice(deviceID: 987_102, udid: "stage-f-other", name: "Same")
        engine.receivedUSBDevices([other])
        _ = try engine.startManagedSession(receiverID: "device:\(other.udid)", preference: .usb)
        let duplicate = try #require(engine.sessions.first)
        let data = try JSONSerialization.data(withJSONObject: ["pixelsWide": 1920, "pixelsHigh": 1080, "scale": 2, "id": install])
        duplicate.sender.onHello?(try JSONDecoder().decode(PhoneInfo.self, from: data))
        engine.stopManagedSession()
        engine.receivedUSBDevices([device, other])
        #expect(throws: EngineControlError.self) { try engine.preflightRoute(receiverID: "install:\(install)", preference: .usb) }
        #expect(throws: EngineControlError.self) { try engine.startManagedSession(receiverID: "install:\(install)", preference: .usb) }
    }

    private func controller() -> DirectEngineController {
        DirectEngineController(managed: true, discover: false,
                               screenPermission: { true }, startSender: { _ in })
    }
    private let devices = [UsbmuxDevice(deviceID: 987_001, udid: "task09-synthetic", name: "Fixture")]

    @Test func managedWifiSessionRejectsNamesakeUSBAndKeepsVerifiedMigration() throws {
        let suite = "task13-verified-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The previous development cache may have been inferred from names; never trust it.
        defaults.set(["namesake-B": "install-A"], forKey: "installIDByUDID")
        let engine = DirectEngineController(managed: true, discover: false,
            screenPermission: { true }, startSender: { _ in }, identityDefaults: defaults)
        let a = UsbmuxDevice(deviceID: 987_010, udid: "verified-A", name: "Same")
        let b = UsbmuxDevice(deviceID: 987_011, udid: "namesake-B", name: "Same")
        engine.receivedUSBDevices([a])
        let receiver = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: receiver, preference: .auto)
        let session = try #require(engine.sessions.first)
        let install = "ab000000-0000-4000-8000-000000000001"
        let hello = try JSONDecoder().decode(PhoneInfo.self, from: Data("{\"pixelsWide\":1920,\"pixelsHigh\":1080,\"scale\":2,\"id\":\"\(install.uppercased())\"}".utf8))
        session.sender.onHello?(hello) // verified hello on A's live USB route
        #expect((defaults.dictionary(forKey: DirectEngineController.verifiedIdentityKey) as? [String: String])?[a.udid] == install)
        // Model a live Wi-Fi continuation of A. Stop the injected sender before transport changes:
        // this hostless policy test must not dial fake USB devices or create displays.
        session.sender.stop()
        session.onUSB = false
        session.wifiServiceName = "Same"
        engine.receivedUSBDevices([b])
        #expect(engine.sessions.first === session && !session.onUSB)
        #expect(session.usbUDID != b.udid)
        #expect((defaults.dictionary(forKey: DirectEngineController.verifiedIdentityKey) as? [String: String])?[b.udid] == nil)
        #expect(!engine.receiverSnapshots().contains {
            ($0["receiverID"] as? String) == "install:\(install)"
                && ($0["usbUDIDs"] as? [String] ?? []).contains(b.udid)
        })
        let wifiHello = try JSONDecoder().decode(PhoneInfo.self, from: Data(#"{"pixelsWide":1920,"pixelsHigh":1080,"scale":2,"id":"wifi-only"}"#.utf8))
        session.sender.onHello?(wifiHello)
        #expect((defaults.dictionary(forKey: DirectEngineController.verifiedIdentityKey) as? [String: String])?[a.udid] == install,
                "a Wi-Fi hello cannot rewrite the historical USB route mapping")
        session.deviceID = install
        engine.receivedUSBDevices([a])
        #expect(session.onUSB && session.usbUDID == a.udid)
        #expect(engine.sessions.first === session)
        engine.stopManagedSession()
    }

    @Test func discoveryAndDirectConnectArePassiveWithoutGrant() {
        let engine = controller()
        for _ in 0..<3 {
            engine.receivedUSBDevices(devices)
            engine.receivedBonjourResults([])
            engine.connect(to: .usb(udid: devices[0].udid), userInitiated: true)
        }
        #expect(engine.sessions.isEmpty)
        #expect(engine.grant.active == nil)
        #expect(engine.receiverSnapshots().count == 1)
        #expect(engine.receiverSnapshots().first?["usbUDIDs"] as? [String] == [devices[0].udid])
    }

    @Test func explicitStartStopRejectsStaleSleepHelloDisconnectAndTimers() async throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let receiverID = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        let state = try engine.startManagedSession(receiverID: receiverID, preference: .usb)
        let session = try #require(engine.sessions.first)
        let staleSleep = session.sender.onPeerSleeping
        let staleDisconnect = session.sender.onDisconnected
        let staleHello = session.sender.onHello
        #expect(engine.sessions.count == 1)
        #expect(try engine.startManagedSession(receiverID: receiverID, preference: .usb)["sessionID"] as? String == state["sessionID"] as? String)
        engine.stopManagedSession()
        staleSleep?()
        staleDisconnect?()
        let hello = try JSONDecoder().decode(PhoneInfo.self, from: Data(#"{"pixelsWide":1920,"pixelsHigh":1080,"scale":2,"id":"stale"}"#.utf8))
        staleHello?(hello)
        engine.receivedUSBDevices([])
        engine.receivedUSBDevices(devices)
        engine.receivedBonjourResults([])
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.sessions.isEmpty)
        #expect(engine.grant.active == nil)
        _ = try engine.startManagedSession(receiverID: receiverID, preference: .usb)
        let replacement = try #require(engine.sessions.first)
        staleSleep?()
        staleDisconnect?()
        #expect(engine.sessions.first === replacement)
        engine.stopManagedSession()
    }

    @Test func authorizedWakeRecoveryKeepsGrantAndCancelledRecoveryCannotResurrect() async throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: id, preference: .auto)
        let grant = engine.grant.active
        let first = try #require(engine.sessions.first)
        first.sender.onPeerSleeping?()
        #expect(engine.sessions.count == 1)
        #expect(engine.sessions.first !== first)
        #expect(engine.grant.active == grant)
        engine.stopManagedSession()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.sessions.isEmpty)
    }

    @Test func disconnectRecoveryAndHardRevocation() async throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: id, preference: .usb)
        let grant = engine.grant.active
        engine.sessions.first?.sender.onDisconnected?()
        #expect(engine.sessions.isEmpty)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.sessions.count == 1)
        #expect(engine.grant.active == grant)
        engine.sessions.first?.sender.onDisconnected?()
        engine.stopManagedSession()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.sessions.isEmpty)
    }

    @Test func unavailablePreferenceAndForeignTargetDoNotGainAuthority() throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        #expect(throws: EngineControlError.self) { try engine.startManagedSession(receiverID: id, preference: .wifi) }
        #expect(engine.grant.active == nil)
        _ = try engine.startManagedSession(receiverID: id, preference: .usb)
        engine.connect(to: .usb(udid: "unrelated"))
        #expect(engine.sessions.count == 1)
        engine.disconnectAll()
        #expect(engine.grant.active == nil)
    }

    @Test func deniedPermissionDoesNotGrantSession() throws {
        let engine = DirectEngineController(managed: true, discover: false,
                                           screenPermission: { false }, startSender: { _ in })
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        #expect(throws: EngineControlError.self) { try engine.startManagedSession(receiverID: id, preference: .auto) }
        #expect(engine.sessions.isEmpty && engine.grant.active == nil)
    }

    @Test func stoppedSenderRejectsDelayedStartWithoutDialing() async {
        let sender = MacSender(transport: .usb(udid: "never-dial", port: 9000), name: "Fixture", mode: .extend)
        sender.stop()
        await #expect(throws: CancellationError.self) { try await sender.start() }
    }

    @Test func standaloneRetainsMultipleIndependentSessions() {
        let engine = DirectEngineController(managed: false, discover: false, startSender: { _ in })
        engine.usbDevices = [UsbmuxDevice(deviceID: 987_001, udid: "standalone-fixture-1", name: "One"),
                             UsbmuxDevice(deviceID: 987_002, udid: "standalone-fixture-2", name: "Two")]
        engine.connect(to: .usb(udid: "standalone-fixture-1"), userInitiated: true)
        engine.connect(to: .usb(udid: "standalone-fixture-2"), userInitiated: true)
        #expect(engine.sessions.count == 2)
        engine.disconnectAll()
        #expect(engine.sessions.isEmpty)
    }

    // A receiver-announced `closing` is deliberate and terminal: it ends the
    // session AND revokes the managed grant, so a still-attached USB entry or a
    // discovery refresh cannot silently reopen the screen.
    @Test func receiverAnnouncedClosingIsTerminalAndRevokesGrant() async throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: id, preference: .usb)
        let session = try #require(engine.sessions.first)
        #expect(engine.managedSessionSnapshot()["state"] as? String == "connecting")
        session.sender.onPeerClosed?()
        #expect(engine.sessions.isEmpty)
        #expect(engine.grant.active == nil)
        #expect(engine.managedSessionSnapshot()["state"] as? String == "idle",
                "a revoked grant reports idle, never connecting")
        // Discovery and a still-present USB entry must not resurrect it, even
        // past end()'s one-second recovery arm.
        engine.receivedUSBDevices(devices)
        engine.receivedBonjourResults([])
        try await Task.sleep(for: .milliseconds(1200))
        engine.receivedUSBDevices(devices)
        #expect(engine.sessions.isEmpty)
        #expect(engine.grant.active == nil)
        #expect(engine.managedSessionSnapshot()["state"] as? String == "idle")
    }

    // A previously captured onPeerClosed belongs to a retired session; firing it
    // after a replacement started must not kill that replacement.
    @Test func stalePeerClosedCannotKillReplacementSession() throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: id, preference: .usb)
        let stale = try #require(engine.sessions.first)
        let staleClosed = stale.sender.onPeerClosed
        engine.stopManagedSession()
        _ = try engine.startManagedSession(receiverID: id, preference: .usb)
        let replacement = try #require(engine.sessions.first)
        staleClosed?()
        #expect(engine.sessions.first === replacement)
        #expect(engine.grant.active != nil)
        engine.stopManagedSession()
    }

    // Regression: the deliberate-close path must not have changed accidental
    // loss. An unannounced disconnect keeps the grant and recovers; a later
    // deliberate close is still terminal.
    @Test func accidentalLossRecoversWhileDeliberateCloseRevokesGrant() async throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: id, preference: .usb)
        let grant = engine.grant.active
        engine.sessions.first?.sender.onDisconnected?()
        #expect(engine.sessions.isEmpty)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.sessions.count == 1)
        #expect(engine.grant.active == grant)
        let recovered = try #require(engine.sessions.first)
        recovered.sender.onPeerClosed?()
        #expect(engine.grant.active == nil)
        #expect(engine.sessions.isEmpty)
        #expect(engine.managedSessionSnapshot()["state"] as? String == "idle")
        try await Task.sleep(for: .milliseconds(1200))
        engine.receivedUSBDevices(devices)
        engine.receivedBonjourResults([])
        #expect(engine.sessions.isEmpty)
        #expect(engine.grant.active == nil)
    }

    // Regression: the lock/wake path still keeps the grant and rebuilds a
    // wake-waiting replacement session.
    @Test func peerSleepingStillKeepsTheGrant() throws {
        let engine = controller()
        engine.receivedUSBDevices(devices)
        let id = try #require(engine.receiverSnapshots().first?["receiverID"] as? String)
        _ = try engine.startManagedSession(receiverID: id, preference: .auto)
        let grant = engine.grant.active
        let first = try #require(engine.sessions.first)
        first.sender.onPeerSleeping?()
        #expect(engine.grant.active == grant)
        #expect(engine.sessions.count == 1)
        #expect(engine.sessions.first !== first)
        engine.stopManagedSession()
    }
}
