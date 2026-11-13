// GPL-3.0. Entire production holder + real PhoneInfo decoder; synthetic Network/DNS I/O.
// This recreates the observed byte COUNTS, not the unavailable historical payload.
import Foundation

struct PanelFacts: Equatable {
    let pixelsWide: Int, pixelsHigh: Int
    let scale: Double
    let pointsWide: Int?, pointsHigh: Int?
}
enum DirectIdentityDiagnostics {
    private static let lock = NSLock()
    private static var rows: [(String, [String: String])] = []
    static func fingerprint(_ value: String?) -> String { "fixture" }
    static func event(_ name: String, _ fields: [String: String], key: String? = nil) {
        lock.withLock { rows.append((name, fields)) }
    }
    static func reset() { lock.withLock { rows = [] } }
    static func contains(_ name: String, _ field: String, _ value: String) -> Bool {
        lock.withLock { rows.contains { $0.0 == name && $0.1[field] == value } }
    }
    static func values() -> String { lock.withLock { String(describing: rows) } }
}

@main enum ReplyChecks {
    static func main() throws {
        let shape = PreflightWire.messageShape(Data(#"{"type":"PRIVATE-TYPE","PRIVATE-KEY":"PRIVATE-VALUE","nonce":"PRIVATE-NONCE"}"#.utf8))
        check(shape["message_type"] == "unknown" && shape["other_field_count"] == "1", "unknown type/keys summarized only")
        check(!String(describing: shape).contains("PRIVATE"), "shape never exposes arbitrary strings")
        let install = "12345678-1234-4234-8234-123456789abc"
        for fault in ["valid", "fragmented", "malformedFrame", "malformedJSON", "helloBinding", "phoneInfo", "eof",
                      "cancelBeforeReply", "browserAfterProof", "holderInvalidation", "explicitCancellation"] {
            DirectIdentityDiagnostics.reset()
            let interface = FixtureNWInterface(index: 29, type: .wiredEthernet)
            let result = FixtureNWBrowser.Result(endpoint: .service(name: "receiver", type: "_sldirect._tcp",
                domain: "local.", interface: interface), interfaces: [interface])
            let holder = ReceiverPreflightHolder(context: "context", receiverID: "install:" + install,
                install: install, route: .network(result, wifiOnly: false), diagnosticGeneration: 42)
            var completions = 0, retires = 0, success = false, code: String?
            holder.start(completion: { outcome in
                completions += 1
                switch outcome {
                case .success: success = true
                case .failure(let error): code = error.code
                }
            }, onRetire: { retires += 1 })
            wait { callbackQueue != nil }
            emit(29)
            wait { callbackQueue.sync { FixtureNWConnection.current?.pendingRead != nil } }
            let connection = FixtureNWConnection.current!
            let request = try PreflightWire.object(Data(connection.sent.dropFirst(4)))
            check(connection.sent.count == 280 && Array(connection.sent.prefix(4)) == [0, 0, 1, 20],
                "exact 280-byte request / 276-byte JSON with big-endian prefix")
            check(connection.pinnedIndex == 29, "same scoped interface29 dialed once")
            let epoch = "12345678-1234-4234-8234-123456789def", nonce = String(repeating: "a", count: 64)
            var binding: [String: Any] = ["v": 1, "probeID": request["probeID"]!, "activationID": request["activationID"]!,
                "receiverEpoch": epoch, "nonce": nonce, "receiverMin": 1]
            if fault == "helloBinding" { binding["activationID"] = UUID().uuidString.lowercased() }
            var hello: [String: Any] = ["type": "hello", "id": install, "pv": 3, "pixelsWide": 2360,
                "pixelsHigh": 1640, "scale": 2, "device": "iPad", "preflight": binding]
            if fault == "phoneInfo" { hello["pixelsWide"] = "bad" }
            var reply: [String: Any] = ["protocol": "sldirect-preflight", "v": 1, "type": "compatibilityReply",
                "probeID": request["probeID"]!, "installID": install, "receiverEpoch": epoch,
                "nonce": nonce, "receiverPV": 3, "receiverMin": 1, "route": "network"]
            // A legal ignored full-hello field sizes the synthetic reply exactly.
            var packet = Data()
            for padding in 0...600 {
                hello["fixturePadding"] = String(repeating: "x", count: padding)
                reply["hello"] = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys]).base64EncodedString()
                packet = try PreflightWire.packet(reply)
                if packet.count == 1181 { break }
            }
            check(packet.count == 1181 && Array(packet.prefix(4)) == [0, 0, 4, 153],
                "exact 1181-byte reply / 1177-byte JSON with big-endian prefix")
            let sensitive = "PRIVATE-CREDENTIAL-SENTINEL"
            if fault == "malformedFrame" { packet = Data([0, 0, 64, 1]) }
            if fault == "malformedJSON" {
                let invalid = Data(("{\"" + sensitive + "\":").utf8)
                packet = withUnsafeBytes(of: UInt32(invalid.count).bigEndian) { Data($0) } + invalid
            }
            if fault == "cancelBeforeReply" {
                var done = false
                holder.cancel(reason: .bonjourRouteWithdrawn) { done = true }; wait { done }
            }
            callbackQueue.sync {
                var offset = 0
                while offset < packet.count, connection.pendingRead != nil {
                    let count = min(connection.allowance, fault == "fragmented" ? 1 : packet.count, packet.count - offset)
                    connection.deliver(Data(packet[offset..<offset + count]), eof: fault == "eof" && offset + count == packet.count)
                    offset += count
                    if fault == "cancelBeforeReply" { break } // queued receive after barrier must be inert
                }
            }
            wait { completions == 1 }
            if ["valid", "fragmented", "browserAfterProof", "holderInvalidation", "explicitCancellation"].contains(fault) {
                check(success && connection.cancels == 0, "valid reply does not self-cancel: \(fault)")
                check(DirectIdentityDiagnostics.contains("preflight.proof-validated", "body_bytes", "1177"), "proof actually validated")
                check(DirectIdentityDiagnostics.contains("preflight.frame-complete", "frame_sha256", PreflightWire.sha256(packet)), "exact header+body fingerprint")
                check(DirectIdentityDiagnostics.contains("preflight.frame-complete", "message_type", "compatibilityReply"), "whitelisted parsed type")
                if ["browserAfterProof", "holderInvalidation", "explicitCancellation"].contains(fault) {
                    let reason: PreflightCancelReason = fault == "browserAfterProof" ? .bonjourRouteWithdrawn :
                        fault == "holderInvalidation" ? .prepareAuthorityInvalid : .ownerCancelRequest
                    holder.cancel(reason: reason) {}; wait { retires == 1 }
                    check(DirectIdentityDiagnostics.contains("preflight.retire", "proof_validated", "true"), "cancellation after valid proof is distinguished")
                    check(DirectIdentityDiagnostics.contains("preflight.cancel-call", "reason", reason.rawValue), "stable cancellation reason distinguished")
                }
            } else {
                check(!success && connection.cancels == 1, "invalid/cancel/EOF reply fails closed once: \(fault)")
                check(code == (fault == "cancelBeforeReply" ? "preflight.cancelled" : fault == "eof" ? "preflight.unavailable" : "preflight.invalidMessage"), "original outward error unchanged")
                if ["helloBinding", "phoneInfo"].contains(fault) {
                    check(DirectIdentityDiagnostics.contains("preflight.proof-rejected", "reason", fault == "phoneInfo" ? "phoneInfoDecode" : "helloBinding"), "proof failure origin identified")
                }
                if fault == "malformedFrame" {
                    check(DirectIdentityDiagnostics.contains("preflight.frame-error", "frame_sha256", PreflightWire.sha256(packet)), "malformed frame identified before proof")
                }
                if fault == "malformedJSON" {
                    check(DirectIdentityDiagnostics.contains("preflight.frame-complete", "json", "invalid"), "complete frame, invalid JSON distinguished")
                    check(DirectIdentityDiagnostics.contains("preflight.proof-rejected", "reason", "replyJSON"), "JSON stage distinguished")
                }
            }
            let logs = DirectIdentityDiagnostics.values()
            check(!logs.contains(sensitive) && !logs.contains(nonce) && !logs.contains(epoch) && !logs.contains(install), "diagnostics contain no raw secrets/identities/unknown keys")
            var done = false
            holder.cancel { done = true }; wait { done && retires == 1 }
            check(completions == 1 && connection.cancels == 1 && connection.sent.count == 280,
                "one terminal completion/socket cancellation; no activation/retry/media")
            print("COMPLETED diagnostic cause", fault)
            FixtureNWConnection.current = nil; callbackQueue = nil
        }
        finishChecks()
    }
}
