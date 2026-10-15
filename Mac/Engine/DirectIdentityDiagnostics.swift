import Foundation
import CryptoKit
import OSLog

/// Privacy-safe discovery diagnostics; never used for connection/correlation decisions.
enum DirectIdentityDiagnostics {
    static func fingerprint(_ value: String?) -> String {
        guard let value else { return "none" }
        return SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func comparisonFingerprint(_ value: String?) -> String {
        fingerprint(value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    #if DEBUG
    private static let logger = Logger(subsystem: "com.dmer.SideLinker.DirectEngine", category: "identity")
    private static let lock = NSLock()
    private static var last: [String: String] = [:]
    #endif
    static func beginInspection() {
        #if DEBUG
        lock.withLock { last.removeAll(keepingCapacity: true) }
        event("helper.inspection-begin", [:])
        #endif
    }
    static func event(_ event: String, _ fields: [String: String], key: String? = nil) {
        #if DEBUG
        let line = "SLIdentity v1 role=helper event=\(event) " + fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
        if let key {
            let changed = lock.withLock { () -> Bool in
                guard last[key] != line else { return false }
                if last.count >= 512 { last.removeAll(keepingCapacity: true) }
                last[key] = line
                return true
            }
            guard changed else { return }
        }
        logger.notice("\(line, privacy: .public)")
        #endif
    }
}
