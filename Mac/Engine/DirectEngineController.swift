import AppKit
import Network
import Combine

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    var lifecycle = "connecting"
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    var protocolVersion: Int?
    // Power actions the receiver offers on the live path (PROTOCOL.md 6.6).
    // Every hello replaces it, so it follows the session on and off the cable.
    @Published var powerActions: [PowerAction] = []
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?
    var startTask: Task<Void, Never>?

    // The live TCP path runs over a cable (Thunderbolt Bridge / Ethernet)
    // rather than WiFi — reported by the sender once connected.
    @Published var wired = false

    var transportLabel: String { onUSB ? "USB" : wired ? "Cable" : "WiFi" }

    // The Display size control (extend only): the choice for this device
    // and what each choice gives on it, from the latest hello.
    private var lastHello: PhoneInfo?
    var receiverMetadata: [String: Any] {
        guard let info = lastHello else { return [:] }
        var result: [String: Any] = [:]
        if let facts = info.panel?.facts {
            result["panel"] = ["pixelsWide": facts.pixelsWide, "pixelsHigh": facts.pixelsHigh,
                               "scale": facts.scale] as [String: Any]
        }
        if let capabilities = info.videoCaps {
            result["codecs"] = Array(Set(capabilities.map(\.codec))).sorted()
        }
        if let rate = info.displayMaxFrameRate { result["displayMaxFrameRate"] = rate }
        return result
    }
    @Published private(set) var displaySize: DisplaySize = .default
    @Published private(set) var displaySizeOutcomes: [DisplaySizeOutcome] = []

    func helloArrived(_ info: PhoneInfo) {
        lastHello = info
        refreshDisplaySize()
    }

    func setDisplaySize(_ size: DisplaySize) {
        guard let info = lastHello else { return }
        sender.setDisplaySize(size, for: info)
        refreshDisplaySize()
    }

    /// Also called when the picker opens: the outcomes can change without a
    /// hello (an HEVC failure, a refused 2x mode).
    func refreshDisplaySize() {
        guard let info = lastHello else { return }
        displaySize = DisplaySizeStore.load(key: sender.displaySizeKey(for: info))
        let outcomes = sender.displaySizeOutcomes(for: info)
        if outcomes != displaySizeOutcomes { displaySizeOutcomes = outcomes }
    }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
    }
}

@MainActor
class DirectEngineController: ObservableObject {
    let managed: Bool
    private(set) var grant = ManagedSessionGrant()
    private var managedTargets = Set<String>()
    private var managedInstallID: String?
    private let startSender: (MacSender) async throws -> Void
    private let screenPermission: () -> Bool
    private let identityDefaults: UserDefaults
    static let verifiedIdentityKey = "verifiedUSBInstallIDByUDID"
    var onEvent: ((String, [String: Any]) -> Void)?

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }

    var running: Bool { !sessions.isEmpty }

    private var browser: NWBrowser?
    private var usbWatcher: UsbmuxDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    //  - WiFi devices the user connected before (wifiRemembered) reconnect
    //    in a short window at LAUNCH only — never mid-session.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    // The earlier unreleased cache could contain name-inferred mappings. Do not import it as
    // verified evidence. This disposable cache is populated only by an actual USB hello below.
    @Published private var installIDByUDID: [String: String] = [:] {
        didSet { identityDefaults.set(installIDByUDID, forKey: Self.verifiedIdentityKey) }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)
    // Services whose Bonjour record is currently seen over the direct
    // host-to-host cable. Plugging that cable in is a deliberate act, so a
    // record newly gaining such an interface connects like a cabled iPhone
    // does; plain WiFi discovery never grabs a (possibly shared) receiver
    // after the launch window. Transition-based, so a record that stays on
    // the cable connects once, not on every browse update.
    private var onDirectCable: Set<String> = []
    // Service names the user disconnected while cabled. The record can
    // vanish and return without a replug (the receiver's display sleeps and
    // wakes, it restarts), and a cable-only receiver's unplug looks the
    // same, so the opt-out simply holds until the user connects by hand.
    // In memory: a relaunched sender starts fresh.
    private var cableOptOut: Set<String> = []
    // Every service seen on the cable this run: a Disconnect counts as a
    // cable opt-out even while the record is briefly gone (receiver asleep).
    private var everOnCable: Set<String> = []

    init(managed: Bool = false, discover: Bool = true,
         screenPermission: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         startSender: @escaping (MacSender) async throws -> Void = { try await $0.start() },
         identityDefaults: UserDefaults = .standard) {
        self.managed = managed
        self.screenPermission = screenPermission
        self.startSender = startSender
        self.identityDefaults = identityDefaults
        self.installIDByUDID = identityDefaults.dictionary(forKey: Self.verifiedIdentityKey) as? [String: String] ?? [:]
        if managed { mode = .extend; port = "9000" }
        guard discover else { return }
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            self.receivedUSBDevices(devices)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sldirect._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.receivedBonjourResults(Array(results))
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func receivedUSBDevices(_ devices: [UsbmuxDevice]) {
        #if DEBUG
        diagnoseUSB(devices)
        #endif
        let detached = Set(usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
        usbDevices = devices
        failover(detachedUDIDs: detached)
        autoConnect()
        publishSnapshots()
    }

    #if DEBUG
    private func diagnoseUSB(_ devices: [UsbmuxDevice]) {
        DirectIdentityDiagnostics.event("helper.usbmux-list", ["count": String(devices.count),
            "udid_fps": devices.map { DirectIdentityDiagnostics.comparisonFingerprint($0.udid) }.sorted().joined(separator: ",")], key: "usb-list")
        for device in devices {
            DirectIdentityDiagnostics.event("helper.usbmux-observation", ["udid_fp": DirectIdentityDiagnostics.fingerprint(device.udid),
                "trimmed_casefold_fp": DirectIdentityDiagnostics.comparisonFingerprint(device.udid),
                "name_fp": DirectIdentityDiagnostics.fingerprint(device.name)], key: "usb:\(DirectIdentityDiagnostics.fingerprint(device.udid))")
        }
    }
    private func diagnoseBonjour(_ results: [NWBrowser.Result]) {
        DirectIdentityDiagnostics.event("helper.bonjour-list", ["count": String(results.count),
            "service_fps": results.map { DirectIdentityDiagnostics.fingerprint(serviceName(of: $0)) }.sorted().joined(separator: ",")], key: "bonjour-list")
        for result in results {
            let name = DirectIdentityDiagnostics.fingerprint(serviceName(of: result))
            DirectIdentityDiagnostics.event("helper.bonjour-observation", ["service_fp": name,
                "txt_id_present": String(txtID(of: result) != nil), "install_fp": DirectIdentityDiagnostics.fingerprint(txtID(of: result)),
                "trimmed_casefold_fp": DirectIdentityDiagnostics.comparisonFingerprint(txtID(of: result))], key: "bonjour:\(name)")
        }
    }
    func diagnoseCurrentDiscovery() {
        diagnoseUSB(usbDevices)
        diagnoseBonjour(discovered)
    }
    #endif

    func receivedBonjourResults(_ results: [NWBrowser.Result]) {
        #if DEBUG
        diagnoseBonjour(results)
        #endif
        discovered = results
        endSessionsWhoseServiceVanished()
        autoConnect()
        connectNewlyCabled()
        publishSnapshots()
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Missing evidence
    /// remains unresolved; a display name cannot establish physical identity.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        let matches = ReceiverSnapshot.sameDevice(serviceInstallID: txtID(of: result), usbInstallID: installIDByUDID[device.udid])
        #if DEBUG
        let usb = DirectIdentityDiagnostics.fingerprint(device.udid), service = DirectIdentityDiagnostics.fingerprint(serviceName(of: result))
        DirectIdentityDiagnostics.event("helper.same-device", ["udid_fp": usb, "service_fp": service,
            "txt_install_fp": DirectIdentityDiagnostics.fingerprint(txtID(of: result)),
            "verified_install_fp": DirectIdentityDiagnostics.fingerprint(installIDByUDID[device.udid]),
            "result": String(matches), "reason": matches ? "verified-install-match" : "missing-or-different-verified-install"], key: "pair:\(usb):\(service)")
        #endif
        return matches
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed, case .wifi(let result) = s.target else { return false }
            if let id = installIDByUDID[device.udid], let peer = s.deviceID ?? txtID(of: result) {
                return peer == id
            }
            if managed { return false }
            return serviceName(of: result) != nil && device.name == serviceName(of: result)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)"),
           !direct.failed {
            return direct
        }
        return sessions.first { s in
            guard !s.failed, case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            if managed { return false }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            let name = serviceName(of: result)
            return name != nil && (name == s.wifiServiceName || name == s.name)
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        if managed { recoverManagedSession(); return }
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            if let covering = activeSession(coveringUSB: device) {
                // usbDisabled gates auto-connecting a device, not the
                // transport of a session the user deliberately has running —
                // however it was started, the cable is better: take it.
                upgradeToUSB(covering, device: device)
            } else if !usbDisabled.contains("usb:\(device.udid)") {
                connect(to: .usb(udid: device.udid))
            }
        }
        guard wifiAutoConnectArmed, Date() < wifiAutoConnectDeadline else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            if wifiRemembered.contains(target.sessionID),
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)")
        }
    }

    /// A Mac receiver just appeared on the direct cable: connect to it unless
    /// a session already covers it (a live WiFi session moves onto the cable
    /// through the sender's own upgrade probe instead).
    private func connectNewlyCabled() {
        guard !managed else { return }
        let nowOnCable = Set(discovered.compactMap { result in
            result.interfaces.contains(where: DirectCable.isDirectLink) ? serviceName(of: result) : nil
        })
        let plugged = nowOnCable.subtracting(onDirectCable)
        onDirectCable = nowOnCable
        everOnCable.formUnion(nowOnCable)
        guard autoConnectEnabled, !plugged.isEmpty else { return }
        for result in discovered {
            guard let name = serviceName(of: result), plugged.contains(name),
                  !cableOptOut.contains(name),
                  activeSession(coveringWiFi: result) == nil,
                  !alreadyServedOnCable(result),
                  // A USB-attached phone belongs to the usbmux path and its
                  // own opt-out, never this one.
                  !usbDevices.contains(where: { sameDevice(result, $0) }) else { continue }
            Log.info("\(name) appeared on the direct cable — connecting")
            connect(to: .wifi(result))
        }
    }

    /// A live session may already talk to this receiver under another
    /// service name (renamed while streaming). Match the install id when the
    /// browse result carries TXT; it often does not, so also treat any live
    /// session already on the cable as covering it: a second cabled Mac
    /// receiver at the same time is rare, and a click still connects it.
    private func alreadyServedOnCable(_ result: NWBrowser.Result) -> Bool {
        let id = txtID(of: result)
        return sessions.contains { s in
            guard !s.failed else { return false }
            if let id, s.deviceID == id { return true }
            return s.wired && s.deviceKind == "Mac"
        }
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !managed || grant.preference != .wifi else { return }
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        if managed {
            let advertised: String?
            if case .wifi(let result) = session.target { advertised = txtID(of: result) } else { advertised = nil }
            guard let verified = installIDByUDID[device.udid],
                  verified == (session.deviceID ?? advertised) else { return }
        }
        Log.info("cable attached for route fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        // A transport choice is not identity evidence; only a USB hello may learn a mapping.
        session.sender.switchTransport(to: .usb(udid: device.udid, port: portNum))
    }

    /// Cable unplugged under a live session: fail over to the device's WiFi
    /// service if one is visible. Without one the session keeps its normal
    /// fate — retry over USB through the grace period, then end.
    private func failover(detachedUDIDs: Set<String>) {
        guard (managed ? grant.active != nil && grant.preference != .usb : autoConnectEnabled),
              !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid),
                  let result = wifiService(for: session) else { continue }
            Log.info("cable detached for route fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) — failing over to WiFi")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
            session.sender.switchTransport(to: .tcp(result.endpoint))
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            if managed { return false }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the WiFi twin.
    private func dedupeSessions() {
        // Failed sessions hold no pipeline: a USB corpse must never win the
        // "keep the cable" rule against a working WiFi session.
        let usbSessionIDs = Set(sessions.compactMap { s -> String? in
            if case .usb = s.target, !s.failed { return s.deviceID }
            return nil
        })
        let cabledNames = Set(usbDevices.compactMap { device -> String? in
            guard let s = session(for: "usb:\(device.udid)"), !s.failed else { return nil }
            return device.name
        })
        for s in sessions {
            guard case .wifi(let result) = s.target else { continue }
            let duplicate = (s.deviceID.map { usbSessionIDs.contains($0) } ?? false)
                || (txtID(of: result).map { usbSessionIDs.contains($0) } ?? false)
                || (serviceName(of: result).map { cabledNames.contains($0) } ?? false)
            if duplicate {
                Log.info("two sessions for one device — keeping the cable, dropping route fingerprint \(DirectIdentityDiagnostics.fingerprint(s.id))")
                end(s)
            }
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            return udid == nil ? "Manual (\(host):\(port))" : "iPhone / iPad"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        if managed {
            guard grant.active != nil, managedTargets.contains(target.sessionID) else { return }
            guard sessions.allSatisfy({ $0.id == target.sessionID }) else { return }
            switch (grant.preference, target) {
            case (.usb, .wifi), (.wifi, .usb): return
            default: break
            }
        }
        let id = target.sessionID
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else { return }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose route fingerprint \(DirectIdentityDiagnostics.fingerprint(id)) — taking over from \(DirectIdentityDiagnostics.fingerprint(covering.id))")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        if !managed {
            switch target {
            case .usb: usbDisabled.remove(id)
            case .wifi(let result):
                wifiRemembered.insert(id)
                if userInitiated, let name = serviceName(of: result) { cableOptOut.remove(name) }
            }
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
            } else {
                transport = .usb(udid: udid, port: portNum)
            }
        case .wifi(let result):
            transport = .tcp(result.endpoint)
        }

        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality, displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                                awaitingWake: awaitingWake,
                                wifiOnly: managed && grant.preference == .wifi)
        let session = DeviceSession(id: id, target: target, name: name, sender: sender)
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak self, weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let self, let session, self.isCurrent(session), session.status != text else { return }
            session.status = text
            if text.hasPrefix("Extending") || text.hasPrefix("Mirroring") {
                session.lifecycle = "streaming"
            } else if text.hasPrefix("Waiting") || text.hasPrefix("Connection lost")
                        || text.hasPrefix("Capture stopped") || text.hasPrefix("Preparing") {
                session.lifecycle = "connecting"
            }
            Log.info("status[route fingerprint \(DirectIdentityDiagnostics.fingerprint(id))]: \(text)")
            self.publishSnapshots()
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session, self.isCurrent(session) else { return }
            session.deviceID = info.id
            session.deviceKind = info.device
            session.protocolVersion = info.protocolVersion
            if self.managed { self.managedInstallID = info.id }
            session.helloArrived(info)
            let power = (info.power ?? []).compactMap(PowerAction.init(rawValue:))
            if power != session.powerActions {
                Log.info("session fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) power actions: "
                    + (power.isEmpty ? "none" : power.map(\.rawValue).joined(separator: ",")))
                session.powerActions = power
            }
            if session.onUSB, let udid = session.usbUDID, let installID = info.id {
                self.recordIdentity(installID, forUSB: udid)
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
            self.publishSnapshots()
        }
        sender.onStats = { [weak self, weak session] frames, _ in
            guard let self, let session, self.isCurrent(session) else { return }
            session.framesSent = frames
            session.lifecycle = "streaming"
            self.publishSnapshots()
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session, self.isCurrent(session) else { return }
            Log.info("device disconnected — session fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) stopped")
            self.end(session)
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session, self.isCurrent(session) else { return }
            let target: ConnectionTarget
            if session.onUSB { target = .usb(udid: session.usbUDID) }
            else if let result = self.wifiService(for: session) { target = .wifi(result) }
            else { target = session.target }
            Log.info("session fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session, self.isCurrent(session) else { return }
            Log.info("session fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for route fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session, self.isCurrent(session) else { return }
            Log.info("session fingerprint \(DirectIdentityDiagnostics.fingerprint(session.id)) closed by the receiver — ending")
            self.end(session)
        }
        sessions.append(session)
        session.startTask = Task {
            guard self.isCurrent(session), !Task.isCancelled else { return }
            do {
                try await self.startSender(sender)
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                guard self.isCurrent(session), !Task.isCancelled else { sender.stop(); return }
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                sender.stop()
                self.onEvent?("diagnostic", EngineControlError(code: "engine.internal",
                    message: String(error.localizedDescription.prefix(512)), retryable: true).object)
                self.publishSnapshots()
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        if managed { stopManagedSession(); return }
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi:
            wifiRemembered.remove(session.id)
            if let name = session.wifiServiceName, everOnCable.contains(name) {
                cableOptOut.insert(name)
            }
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        end(session)
    }

    func disconnectAll() {
        if managed { stopManagedSession(); return }
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = session.target
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession) {
        session.startTask?.cancel()
        session.startTask = nil
        session.sender.stop()
        sessions.removeAll { $0 === session }
        if !managed || grant.active != nil { publishSnapshots() }
        if managed, grant.active != nil {
            let generation = grant.generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.grant.permitsRecovery(generation: generation) else { return }
                self.recoverManagedSession()
            }
        }
    }

    private func isCurrent(_ session: DeviceSession) -> Bool {
        sessions.contains { $0 === session } && (!managed || grant.active != nil)
    }

    func receiverSnapshots() -> [[String: Any]] {
        #if DEBUG
        let mappings = installIDByUDID.map { "\(DirectIdentityDiagnostics.fingerprint($0.key))->\(DirectIdentityDiagnostics.fingerprint($0.value))" }.sorted().joined(separator: ",")
        let comparisons = installIDByUDID.map { "\(DirectIdentityDiagnostics.comparisonFingerprint($0.key))->\(DirectIdentityDiagnostics.comparisonFingerprint($0.value))" }.sorted().joined(separator: ",")
        DirectIdentityDiagnostics.event("helper.verified-map", ["pairs_raw": mappings, "pairs_casefold": comparisons,
            "count": String(installIDByUDID.count)], key: "verified-map")
        #endif
        return ReceiverSnapshot.deduplicate(deviceEntries.map { entry in
            var transports: [String] = []
            if entry.usbTarget != nil { transports.append("usb") }
            if entry.wifiTarget != nil { transports.append("wifi") }
            let live = session(for: entry)
            var row: [String: Any] = ["receiverID": receiverID(for: entry), "name": entry.name,
                    "deviceKind": live?.deviceKind ?? "unknown", "transports": transports]
            // Facts only: expose already-known usbmux identity, not discovery or product policy.
            var udids = Set<String>()
            if case .usb(let udid?) = entry.usbTarget { udids.insert(udid) }
            let receiver = receiverID(for: entry)
            if receiver.hasPrefix("install:") {
                let install = String(receiver.dropFirst(8))
                for (udid, knownInstall) in installIDByUDID where knownInstall == install { udids.insert(udid) }
            }
            row["usbUDIDs"] = udids.sorted()
            if let version = live?.protocolVersion {
                row["protocolVersion"] = version
                row["compatible"] = version >= WireProtocol.minSupportedPeer
            }
            if let metadata = live?.receiverMetadata {
                for (key, value) in metadata { row[key] = value }
            }
            #if DEBUG
            let route = DirectIdentityDiagnostics.fingerprint(receiver)
            DirectIdentityDiagnostics.event("helper.snapshot-row", ["route_fp": route,
                "install_fp": DirectIdentityDiagnostics.fingerprint(receiver.hasPrefix("install:") ? String(receiver.dropFirst(8)) : nil),
                "install_casefold_fp": DirectIdentityDiagnostics.comparisonFingerprint(receiver.hasPrefix("install:") ? String(receiver.dropFirst(8)) : nil),
                "usb_udid_fps": udids.map { DirectIdentityDiagnostics.comparisonFingerprint($0) }.sorted().joined(separator: ","),
                "name_fp": DirectIdentityDiagnostics.fingerprint(entry.name),
                "device_kind_fp": DirectIdentityDiagnostics.fingerprint(row["deviceKind"] as? String),
                "transports": transports.sorted().joined(separator: ",")], key: "snapshot:\(route)")
            #endif
            return row
        })
    }

    private func recordIdentity(_ installID: String, forUSB udid: String) {
        guard !installID.isEmpty, !udid.isEmpty else { return }
        installIDByUDID[udid] = installID
        #if DEBUG
        DirectIdentityDiagnostics.event("helper.verified-usb-hello", ["udid_fp": DirectIdentityDiagnostics.fingerprint(udid),
            "install_fp": DirectIdentityDiagnostics.fingerprint(installID)], key: "hello:\(DirectIdentityDiagnostics.fingerprint(udid))")
        #endif
    }

    private func receiverID(for entry: DeviceEntry) -> String {
        if case .usb(let udid?) = entry.usbTarget, let id = installIDByUDID[udid] {
            return "install:\(id)"
        }
        if case .wifi(let result) = entry.wifiTarget, let id = txtID(of: result) {
            return "install:\(id)"
        }
        return entry.id
    }

    func managedSessionSnapshot() -> [String: Any] {
        guard let active = grant.active else { return ["state": "idle"] }
        let session = sessions.first
        let state = session.map { $0.failed ? "failed" : $0.lifecycle } ?? "connecting"
        var result: [String: Any] = ["sessionID": active.sessionID,
            "receiverID": active.receiverID, "state": state]
        if let session {
            result["transport"] = session.onUSB ? "usb" : "wifi"
            result["status"] = String(session.status.prefix(512))
            result["framesSent"] = session.framesSent
        }
        return result
    }

    func permissionSnapshot() -> [String: Any] {
        // Preflight only: never opens permission UI in managed mode.
        ["screenRecording": CGPreflightScreenCaptureAccess() ? "granted" : "unknown",
         "accessibility": AXIsProcessTrusted() ? "granted" : "unknown"]
    }

    /// Explicit local user action, executed in the engine process/TCC principal, never discovery.
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }

    func publishSnapshots() {
        guard onEvent != nil else { return }
        onEvent?("receiverSnapshot", ["receivers": receiverSnapshots()])
        let session = managedSessionSnapshot()
        onEvent?("sessionState", session)
        onEvent?("engineState", ["state": grant.active == nil ? "discovering" : session["state"] ?? "connecting"])
        onEvent?("permissionState", permissionSnapshot())
    }

    func startManagedSession(receiverID: String, preference: EngineTransportPreference) throws -> [String: Any] {
        guard managed else { throw EngineControlError(code: "engine.internal", message: "Not managed") }
        if let active = grant.active {
            guard active.receiverID == receiverID, active.preference == preference else {
                throw EngineControlError(code: "session.busy", message: "Stop the current session first")
            }
            return managedSessionSnapshot()
        }
        guard let entry = deviceEntries.first(where: { self.receiverID(for: $0) == receiverID }) else {
            throw EngineControlError(code: "receiver.notFound", message: "Receiver not currently discovered", retryable: true)
        }
        let target: ConnectionTarget?
        switch preference {
        case .auto: target = entry.preferredTarget
        case .usb: target = entry.usbTarget
        case .wifi: target = entry.wifiTarget
        }
        guard let target else {
            throw EngineControlError(code: "transport.unavailable", message: "Requested transport unavailable", retryable: true)
        }
        guard screenPermission() else {
            throw EngineControlError(code: "permission.screenRecording", message: "Screen Recording required")
        }
        _ = try grant.start(receiverID: receiverID, preference: preference)
        managedTargets = Set([entry.usbTarget, entry.wifiTarget].compactMap { $0?.sessionID })
        connect(to: target)
        publishSnapshots()
        return managedSessionSnapshot()
    }

    func stopManagedSession() {
        let old = grant.active
        grant.stop() // Revoke BEFORE teardown and any asynchronously queued callback.
        managedTargets.removeAll()
        managedInstallID = nil
        if let old {
            onEvent?("engineState", ["state": "stopping"])
            onEvent?("sessionState", ["sessionID": old.sessionID, "receiverID": old.receiverID, "state": "stopping"])
        }
        sessions.forEach { end($0) }
        if let old {
            onEvent?("sessionState", ["sessionID": old.sessionID, "receiverID": old.receiverID, "state": "idle"])
        }
        publishSnapshots()
    }

    private func recoverManagedSession() {
        guard let active = grant.active else { return }
        if let session = sessions.first, !session.failed {
            if active.preference != .wifi,
               let device = usbDevices.first(where: { self.activeSession(coveringUSB: $0) === session }) {
                upgradeToUSB(session, device: device)
            }
            return
        }
        // Only rediscovery of the granted identity may replace an ended pipeline.
        guard let entry = deviceEntries.first(where: { entry in
            receiverID(for: entry) == active.receiverID
                || managedInstallID.map { receiverID(for: entry) == "install:\($0)" } == true
        }) else { return }
        let target: ConnectionTarget?
        switch active.preference {
        case .auto: target = entry.preferredTarget
        case .usb: target = entry.usbTarget
        case .wifi: target = entry.wifiTarget
        }
        guard let target else { return }
        sessions.forEach { end($0) }
        managedTargets.formUnion([entry.usbTarget, entry.wifiTarget].compactMap { $0?.sessionID })
        connect(to: target)
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard !managed else { return }
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? "iPhone / iPad",
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if !managed, UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}
