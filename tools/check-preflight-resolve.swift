// GPL-3.0. Synthetic imported API boundary; production holder/callback is compiled whole.
import Foundation
import Network
import dnssd

struct EngineControlError: Error { let code: String; let message: String }
#if !REPLY_CHECKS
enum WireProtocol { static let version = 3; static let minSupportedPeer = 1 }
struct PhoneInfo: Codable {}
#endif
protocol PreflightUSBIO {}
struct PreflightUSBSocket: PreflightUSBIO { init(queue: DispatchQueue) {} }
final class PreflightUSBOperation {
    init(udid: String, expectedDeviceID: Int, factory: () -> PreflightUSBIO) {}
    func start(_ completion: (Result<FixtureNWConnection?, EngineControlError>) -> Void) { fatalError("unexpected USB") }
    func cancel() {}
}
struct FixtureNWInterface {
    enum Kind { case wifi, wiredEthernet }
    let index: Int
    let type: Kind
}
enum FixtureNWEndpoint {
    case service(name: String, type: String, domain: String, interface: FixtureNWInterface?)
    struct Host { init(_ text: String) {} }
    struct Port { init?(rawValue: UInt16) {} }
}
enum FixtureNWBrowser {
    struct Result {
        enum Metadata { case bonjour([String: String]) }
        let metadata = Metadata.bonjour(["pf": "1", "pfp": "9002"])
        let endpoint: FixtureNWEndpoint
        let interfaces: [FixtureNWInterface]
    }
}
final class FixtureNWParameters {
    static var tcp: FixtureNWParameters { FixtureNWParameters() }
    var requiredInterface: FixtureNWInterface?
    var requiredInterfaceType: FixtureNWInterface.Kind?
}
final class FixtureNWConnection {
    enum State { case ready, failed, cancelled }
    enum Completion { case contentProcessed((Error?) -> Void) }
    var stateUpdateHandler: ((State) -> Void)?
    #if REPLY_CHECKS
    static var current: FixtureNWConnection!
    var sent = Data()
    var cancels = 0
    var pendingRead: ((Data?, Int?, Bool, Error?) -> Void)?
    var allowance = 0
    var pinnedIndex: Int?
    init(host: FixtureNWEndpoint.Host, port: FixtureNWEndpoint.Port, using parameters: FixtureNWParameters) {
        pinnedIndex = parameters.requiredInterface?.index; Self.current = self
    }
    func start(queue: DispatchQueue) { queue.async { self.stateUpdateHandler?(.ready) } }
    func cancel() { cancels += 1 }
    func send(content: Data, completion: Completion) {
        sent.append(content)
        if case .contentProcessed(let callback) = completion { callback(nil) }
    }
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, Int?, Bool, Error?) -> Void) {
        check(pendingRead == nil, "only one outstanding exact read")
        allowance = maximumLength; pendingRead = completion
    }
    func deliver(_ data: Data?, eof: Bool = false) {
        let callback = pendingRead; pendingRead = nil
        check(callback != nil, "delivery has outstanding reader")
        check((data?.count ?? 0) <= allowance, "fixture respects actual exact-read allowance")
        callback?(data, nil, eof, nil)
    }
    #else
    init(host: FixtureNWEndpoint.Host, port: FixtureNWEndpoint.Port, using: FixtureNWParameters) { fatalError("unexpected dial") }
    func start(queue: DispatchQueue) { fatalError("unexpected dial") }
    func cancel() {}
    func send(content: Data, completion: Completion) { fatalError("unexpected send") }
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: (Data?, Int?, Bool, Error?) -> Void) { fatalError("unexpected read") }
    #endif
}

private var callback: DNSServiceResolveReply!
private var callbackContext: UnsafeMutableRawPointer!
var callbackQueue: DispatchQueue!
private var serviceRef: DNSServiceRef!
private var live = Set<DNSServiceRef>()
private var resolves = 0
private var addressCalls: [(UInt32, String)] = []
private var deallocations = 0
private var initialIndex: UInt32 = 0
private let resolverStarted = DispatchSemaphore(value: 0)
func FixtureDNSServiceResolve(_ ref: UnsafeMutablePointer<DNSServiceRef?>, _ flags: UInt32,
    _ index: UInt32, _ name: String, _ type: String, _ domain: String,
    _ reply: @escaping DNSServiceResolveReply, _ context: UnsafeMutableRawPointer) -> DNSServiceErrorType {
    resolves += 1; initialIndex = index; callback = reply; callbackContext = context
    serviceRef = OpaquePointer(bitPattern: 0x1000)!; live.insert(serviceRef); ref.pointee = serviceRef
    return DNSServiceErrorType(kDNSServiceErr_NoError)
}
func FixtureDNSServiceSetDispatchQueue(_ ref: DNSServiceRef, _ queue: DispatchQueue) -> DNSServiceErrorType {
    callbackQueue = queue
    if ref == serviceRef { resolverStarted.signal() }
    return DNSServiceErrorType(kDNSServiceErr_NoError)
}
func FixtureDNSServiceRefDeallocate(_ ref: DNSServiceRef) {
    check(live.remove(ref) != nil, "resolver deallocated exactly once"); deallocations += 1
}
func FixtureDNSServiceGetAddrInfo(_ ref: UnsafeMutablePointer<DNSServiceRef?>, _ flags: UInt32,
    _ index: UInt32, _ protocolFlags: UInt32, _ host: String,
    _ reply: @escaping DNSServiceGetAddrInfoReply, _ context: UnsafeMutableRawPointer) -> DNSServiceErrorType {
    addressCalls.append((index, host))
    let addressRef = OpaquePointer(bitPattern: 0x2000)!
    live.insert(addressRef); ref.pointee = addressRef
    #if REPLY_CHECKS
    callbackQueue.async {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                reply(addressRef, UInt32(kDNSServiceFlagsAdd), index, 0, nil, $0, 0, context)
            }
        }
    }
    #endif
    return DNSServiceErrorType(kDNSServiceErr_NoError)
}
private var failures = 0
func finishChecks() { exit(failures == 0 ? 0 : 1) }
func check(_ value: Bool, _ message: String) {
    if !value { failures += 1; print("FAIL", message) }
}
func wait(_ predicate: () -> Bool, seconds: TimeInterval = 1) {
    let end = Date().addingTimeInterval(seconds)
    while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(predicate(), "wait completed within bound")
}
func emit(_ index: UInt32, error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)) {
    callbackQueue.sync {
        "receiver.local.".withCString { host in
            callback(serviceRef, 0, index, error, nil, host, 0, 0, nil, callbackContext)
        }
    }
}

#if !REPLY_CHECKS
@main enum ResolveChecks {
    static func main() {
        for scenario in ["19-27-26", "timeout", "cancel-late", "duplicate", "wifi-only", "wifi-timeout", "scoped"] {
            resolves = 0; addressCalls = []; deallocations = 0; live = []; callbackQueue = nil
            let wifiOnly = scenario.hasPrefix("wifi")
            let wifi = FixtureNWInterface(index: 27, type: .wifi)
            let wired = FixtureNWInterface(index: 26, type: .wiredEthernet)
            let interfaces = wifiOnly ? [wired, wifi, FixtureNWInterface(index: 28, type: .wifi)] : [wired, wifi]
            let scoped = scenario == "scoped" ? wired : nil
            let result = FixtureNWBrowser.Result(endpoint: .service(name: "receiver", type: "_sldirect._tcp",
                domain: "local.", interface: scoped), interfaces: interfaces)
            let holder = ReceiverPreflightHolder(context: "context", receiverID: "exact", install: "exact",
                route: .network(result, wifiOnly: wifiOnly))
            var completions = 0, retires = 0, code: String?
            let began = Date()
            holder.start(completion: { outcome in
                completions += 1
                if case .failure(let error) = outcome { code = error.code }
            }, onRetire: { retires += 1 })
            check(resolverStarted.wait(timeout: .now() + 1) == .success, "resolver callback installed")
            callbackQueue.sync {}
            check(resolves == 1 && initialIndex == (scoped == nil ? 0 : 26), "single original resolver/scope")
            emit(19)
            check(addressCalls.isEmpty && live.contains(serviceRef), "19 ignored; same resolver remains alive")
            if scenario == "cancel-late" {
                var cancelled = false
                holder.cancel { cancelled = true }; wait { cancelled }
                emit(27)
                check(addressCalls.isEmpty && code == "preflight.cancelled", "late callback cannot advance cancelled holder")
            } else if scenario == "timeout" || scenario == "wifi-timeout" {
                if wifiOnly { emit(26) }
                wait({ completions == 1 }, seconds: 5.5)
                let elapsed = Date().timeIntervalSince(began)
                check(elapsed >= 4.9 && elapsed < 5.5, "original five-second preparation deadline")
                check(code == "preflight.expired" && addressCalls.isEmpty, "foreign-only answers fail closed on expiry")
                emit(27)
                check(addressCalls.isEmpty, "expired callback cannot advance")
            } else {
                if wifiOnly { emit(26); check(addressCalls.isEmpty, "wifi-only rejects captured wired interface") }
                if scoped != nil { emit(27); check(addressCalls.isEmpty, "scoped endpoint cannot change interface") }
                let accepted: UInt32 = scoped == nil ? 27 : 26
                emit(accepted)
                emit(accepted); emit(26); emit(19, error: DNSServiceErrorType(kDNSServiceErr_Unknown))
                check(addressCalls.count == 1 && addressCalls.first?.0 == accepted && addressCalls.first?.1 == "receiver.local.",
                    "first allowed callback advances once with pinned interface/host")
                check(deallocations == 1 && live.count == 1, "duplicates do not destroy address resolver")
            }
            var cancelled = false
            holder.cancel { cancelled = true }; wait { cancelled && completions == 1 && retires == 1 }
            check(live.isEmpty && resolves == 1, "all resolver ownership cleaned up; no requery")
            withExtendedLifetime(holder) {}
            print("COMPLETED", scenario)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
