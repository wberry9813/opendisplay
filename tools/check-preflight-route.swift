// GPL-3.0. Actual public browser snapshots; only DNS/TCP APIs and unrelated
// controller effects are doubled. Never launches Product or contacts an iPad.
import Foundation
import Network
import dnssd

struct EngineControlError: Error { let code: String; let message: String }
struct PanelFacts: Equatable {
    let pixelsWide: Int; let pixelsHigh: Int; let scale: Double
    let pointsWide: Int?; let pointsHigh: Int?
}
enum EngineTransportPreference { case auto, usb, wifi }
struct UsbmuxDevice { let udid: String; let deviceID: Int }
protocol PreflightUSBIO {}
struct PreflightUSBSocket: PreflightUSBIO { init(queue: DispatchQueue) {} }
final class PreflightUSBOperation {
    init(udid: String, expectedDeviceID: Int, factory: () -> PreflightUSBIO) {}
    func start(_ completion: (Result<FixtureNWConnection?, EngineControlError>) -> Void) { fatalError("USB forbidden") }
    func cancel() {}
}
final class FixtureNWConnection {
    enum State { case ready, failed, cancelled }
    enum Completion { case contentProcessed((Error?) -> Void) }
    static var current: FixtureNWConnection!
    static var made = 0
    var state = State.ready
    var stateUpdateHandler: ((State) -> Void)?
    var sent = [Data](), cancels = 0, starts = 0
    var pendingRead: ((Data?, Int?, Bool, Error?) -> Void)?
    var allowance = 0, inbound = Data(), hello = Data()
    var queue: DispatchQueue!
    let pinnedIndex: Int?
    init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        precondition(port.rawValue == 9002)
        pinnedIndex = parameters.requiredInterface?.index
        Self.current = self; Self.made += 1
    }
    func start(queue: DispatchQueue) {
        starts += 1; self.queue = queue
        queue.async { self.stateUpdateHandler?(.ready) }
    }
    func cancel() { cancels += 1 }
    func send(content: Data, completion: Completion) {
        sent.append(content)
        let row = try! PreflightWire.object(Data(content.dropFirst(4)))
        if row["type"] as? String == "activate" {
            var ack = row; ack["type"] = "activationAck"
            inbound.append(try! PreflightWire.packet(ack))
            inbound.append(withUnsafeBytes(of: UInt32(hello.count).bigEndian) { Data($0) })
            inbound.append(hello)
            queue.async { self.pump() }
        }
        if case .contentProcessed(let callback) = completion { callback(nil) }
    }
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, Int?, Bool, Error?) -> Void) {
        precondition(pendingRead == nil, "one outstanding read")
        pendingRead = completion; allowance = maximumLength
        queue.async { self.pump() }
    }
    func pump() {
        guard !inbound.isEmpty, let read = pendingRead else { return }
        let data = Data(inbound.prefix(allowance)); inbound.removeFirst(data.count)
        pendingRead = nil; read(data, nil, false, nil)
    }
    func reply() {
        let request = try! PreflightWire.object(Data(sent[0].dropFirst(4)))
        let epoch = UUID().uuidString.lowercased(), nonce = String(repeating: "a", count: 64)
        hello = try! JSONSerialization.data(withJSONObject: ["type": "hello", "pv": 3, "id": install,
            "pixelsWide": 1920, "pixelsHigh": 1080, "scale": 2,
            "preflight": ["v": 1, "probeID": request["probeID"]!, "activationID": request["activationID"]!,
                "receiverEpoch": epoch, "nonce": nonce, "receiverMin": 1]], options: [.sortedKeys])
        inbound.append(try! PreflightWire.packet(["protocol": "sldirect-preflight", "v": 1,
            "type": "compatibilityReply", "probeID": request["probeID"]!, "installID": install,
            "receiverEpoch": epoch, "nonce": nonce, "receiverPV": 3, "receiverMin": 1,
            "route": "network", "hello": hello.base64EncodedString()]))
        pump()
    }
}
enum DNSFixture {
    static var queue: DispatchQueue!
    static var callback: DNSServiceResolveReply!
    static var context: UnsafeMutableRawPointer!
    static var resolves = 0, addresses = 0
}
func FixtureDNSServiceResolve(_ ref: UnsafeMutablePointer<DNSServiceRef?>, _ flags: UInt32,
    _ index: UInt32, _ name: String, _ type: String, _ domain: String,
    _ reply: @escaping DNSServiceResolveReply, _ context: UnsafeMutableRawPointer) -> DNSServiceErrorType {
    DNSFixture.resolves += 1; DNSFixture.callback = reply; DNSFixture.context = context
    ref.pointee = OpaquePointer(bitPattern: 0x1000)!; return 0
}
func FixtureDNSServiceSetDispatchQueue(_ ref: DNSServiceRef, _ queue: DispatchQueue) -> DNSServiceErrorType {
    DNSFixture.queue = queue; return 0
}
func FixtureDNSServiceRefDeallocate(_ ref: DNSServiceRef) {}
func FixtureDNSServiceGetAddrInfo(_ ref: UnsafeMutablePointer<DNSServiceRef?>, _ flags: UInt32,
    _ index: UInt32, _ protocolFlags: UInt32, _ host: String,
    _ reply: @escaping DNSServiceGetAddrInfoReply, _ context: UnsafeMutableRawPointer) -> DNSServiceErrorType {
    DNSFixture.addresses += 1
    let addressRef = OpaquePointer(bitPattern: 0x2000)!
    ref.pointee = addressRef
    DNSFixture.queue.async {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                reply(addressRef, UInt32(kDNSServiceFlagsAdd), index, 0, nil, $0, 0, context)
            }
        }
    }
    return 0
}
func spin(_ message: String, seconds: Double = 2, _ predicate: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    precondition(predicate(), message)
}
let install = "12345678-1234-4234-8234-123456789abc"
let type = "_slrt20._tcp", name = "Route20-" + UUID().uuidString.prefix(8)
let a = if_nametoindex(CommandLine.arguments[1]), b = if_nametoindex(CommandLine.arguments[2])
var current: [NWBrowser.Result] = []
func indices(_ result: NWBrowser.Result) -> Set<UInt32> { Set(result.interfaces.map { UInt32($0.index) }) }
func valid(_ result: NWBrowser.Result, id: String = install, pv: String = "3") -> Bool {
    if case .bonjour(let txt) = result.metadata { return txt["id"] == id && txt["pv"] == pv && txt["pf"] == "1" && txt["pfp"] == "9002" }
    return false
}
func register(_ interface: UInt32, service: String = String(name), id: String = install, pv: String = "3") -> DNSServiceRef {
    var ref: DNSServiceRef?, txt = Data()
    for row in ["id="+id, "pv="+pv, "pf=1", "pfp=9002"] {
        txt.append(UInt8(row.utf8.count)); txt.append(contentsOf: row.utf8)
    }
    let code = txt.withUnsafeBytes { bytes in
        DNSServiceRegister(&ref, UInt32(kDNSServiceFlagsNoAutoRename), interface, service, type, "local.", nil,
            UInt16(49198).bigEndian, UInt16(txt.count), bytes.baseAddress, { _,_,error,_,_,_,_ in
                precondition(error == 0, "register callback")
            }, nil)
    }
    precondition(code == 0 && ref != nil, "register")
    precondition(DNSServiceSetDispatchQueue(ref!, .main) == 0)
    return ref!
}
let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .tcp)
browser.browseResultsChangedHandler = { results, _ in current = Array(results) }
browser.start(queue: .main)
precondition(a != 0 && b != 0 && a != b, "two existing interfaces required")
let ra = register(a)
spin("A snapshot", seconds: 8) { current.count == 1 && indices(current[0]) == [a] && valid(current[0]) }
let capturedA = current[0]
let rb = register(b)
spin("AB snapshot", seconds: 8) { current.count == 1 && indices(current[0]) == [a,b] && valid(current[0]) }
let capturedAB = current[0]
precondition(capturedA != capturedAB && capturedA.endpoint == capturedAB.endpoint)
print("REAL_RESULT A_to_AB equal=false same_endpoint=true A_retained=true"); fflush(stdout)
DNSServiceRefDeallocate(ra); DNSServiceRefDeallocate(rb)
spin("withdrawal", seconds: 8) { current.isEmpty }
func snapshot(_ interface: UInt32, service: String = String(name), id: String = install, pv: String = "3") -> NWBrowser.Result {
    let ref = register(interface, service: service, id: id, pv: pv)
    spin("fresh metadata-complete snapshot", seconds: 8) {
        current.count == 1 && indices(current[0]) == [interface] && valid(current[0], id: id, pv: pv)
    }
    let result = current[0]
    DNSServiceRefDeallocate(ref)
    spin("fixture withdrawal", seconds: 8) { current.isEmpty }
    return result
}
// B-only/changed records are fresh actual observations replayed into the callback,
// not a claim about a physical in-flight device transition.
let capturedB = snapshot(b)
let changedService = snapshot(a, service: String(name)+"-other")
let changedTXT = snapshot(a, pv: "4")
let changedInstall = snapshot(a, id: "22345678-1234-4234-8234-123456789abc")
browser.cancel()
precondition(capturedB.endpoint == capturedA.endpoint && changedTXT.endpoint == capturedA.endpoint)

for afterProof in [false, true] {
    for scenario in ["unchanged", "additive", "A-removed", "service-changed", "TXT-changed", "install-changed", "withdrawn", "transport-policy", "AB-retains-pin"] {
        print("SCENARIO_BEGIN \(scenario) afterProof=\(afterProof)"); fflush(stdout)
        DNSFixture.queue = nil; DNSFixture.resolves = 0; DNSFixture.addresses = 0
        FixtureNWConnection.current = nil; FixtureNWConnection.made = 0
        let original = scenario == "AB-retains-pin" ? capturedAB : capturedA
        let holder = ReceiverPreflightHolder(context: UUID().uuidString.lowercased(), receiverID: "install:"+install,
            install: install, route: .network(original, wifiOnly: false), diagnosticGeneration: 42)
        let controller = RouteController()
        controller.discovered = [original]; controller.preparation = (holder, false)
        var completed = 0, retired = 0, success = false
        holder.start(completion: { result in completed += 1; if case .success = result { success = true } },
                     onRetire: { retired += 1 })
        spin("resolver installed") { DNSFixture.queue != nil }
        DNSFixture.queue.sync {
            "receiver.local.".withCString { host in
                DNSFixture.callback(OpaquePointer(bitPattern: 0x1000)!, 0, a, 0, nil, host, 0, 0, nil, DNSFixture.context)
            }
        }
        spin("request/read") { DNSFixture.queue.sync { FixtureNWConnection.current?.pendingRead != nil } }
        let socket = FixtureNWConnection.current!
        precondition(holder.pinnedNetworkInterface?.index == Int(a))
        if afterProof {
            socket.queue.sync { socket.reply() }
            spin("valid proof") { completed == 1 && success }
        }
        let fresh: [NWBrowser.Result]
        switch scenario {
        case "additive": fresh = [capturedAB]
        case "A-removed": fresh = [capturedB]
        case "service-changed": fresh = [changedService]
        case "TXT-changed": fresh = [changedTXT]
        case "install-changed": fresh = [changedInstall]
        case "withdrawn": fresh = []
        default: fresh = [capturedA]
        }
        if scenario == "transport-policy" { controller.freshOverride = .network(capturedA, wifiOnly: true) }
        let expected = ["unchanged", "additive", "AB-retains-pin"].contains(scenario)
        let route = try? controller.observedPreflightRoute(receiverID: holder.receiverID, preference: .auto)
        precondition(route != nil)
        let candidate = controller.freshOverride ?? fresh.first.map { PreflightRoute.network($0, wifiOnly: false) }
        let same = candidate.map { controller.compare(holder.route, $0, pin: holder.pinnedNetworkInterface) } ?? false
        precondition(same == expected, "route verdict \(scenario)")
        // Before a pin is selected, losing any original eligible choice fails closed.
        if scenario == "additive" {
            precondition(controller.compare(holder.route, .network(capturedAB, wifiOnly: false), pin: nil))
        }
        controller.receivedBonjourResults(fresh)
        socket.queue.sync {}
        if expected {
            precondition(socket.cancels == 0 && !controller.preparation!.cancelling)
            if !afterProof {
                socket.queue.sync { socket.reply() }
                spin("same socket proof completes") { completed == 1 && success }
            }
            precondition(holder.pinnedNetworkInterface?.index == Int(a))
            // Exercise the very same socket's strict ACK/full-hello transfer too.
            var ticket: PreparedMediaConnection?, activated = false
            holder.activate { result in
                activated = true
                if case .success(let value) = result { ticket = value }
            }
            spin("same socket activation") { activated }
            precondition(ticket?.connection === socket && socket.pinnedIndex == Int(a) && socket.starts == 1)
            precondition(socket.sent.count == 2 && socket.cancels == 0 && retired == 0)
            ticket = nil
            spin("ticket cleanup") { socket.cancels == 1 }
        } else {
            spin("route retirement") { retired == 1 && controller.preparation == nil }
            precondition(socket.cancels == 1 && socket.sent.count == 1 && completed == 1)
        }
        precondition(DNSFixture.resolves == 1 && DNSFixture.addresses == 1 && FixtureNWConnection.made == 1)
        precondition(socket.sent[0].count == 280 && holder.pinnedNetworkInterface?.index == Int(a))
        print("SCENARIO_PASS \(scenario) afterProof=\(afterProof) pinnedA=true one_socket=true one_cancel=true"); fflush(stdout)
    }
}
print("ROUTE_CHECKS_PASS 18 cases; actual NWBrowser Results/exact callback/whole holder; synthetic DNS/TCP")
