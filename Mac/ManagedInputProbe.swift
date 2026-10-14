import AppKit
import CoreGraphics

/// Branch-local, non-prompting diagnostics. One budget per MacSender, including
/// injector rebuilds. The lock protects setup and sender.video callback overlap.
final class ManagedInputProbe {
    private let enabled = CommandLine.arguments.contains("--engine")
    private let lock = NSLock()
    private var ready = false
    private var messages = Set<String>()
    private var attemptedPost = false

    func inputReady() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !ready else { return }
        ready = true
        Log.info("[managed-input-probe] input-ready \(accessSnapshot()) AX wait is reporting-only; no input bypass")
    }

    func received(_ type: String, injectorPresent: Bool) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard messages.insert(type).inserted else { return }
        Log.info("[managed-input-probe] first-control type=\(type) injectorPresent=\(injectorPresent)")
    }

    func post(_ event: CGEvent) {
        guard enabled else { event.post(tap: .cghidEventTap); return }
        lock.lock()
        let first = !attemptedPost
        attemptedPost = true
        lock.unlock()
        if first {
            Log.info("[managed-input-probe] first-post before tap=cghidEventTap eventType=\(event.type.rawValue) \(accessSnapshot())")
        }
        event.post(tap: .cghidEventTap)
        if first {
            Log.info("[managed-input-probe] first-post after \(accessSnapshot()) callReturned=true delivery=unobservable")
        }
    }

    private func accessSnapshot() -> String {
        let postAccess: String
        if #available(macOS 10.15, *) {
            postAccess = String(CGPreflightPostEventAccess())
        } else {
            postAccess = "unavailable"
        }
        return "pid=\(ProcessInfo.processInfo.processIdentifier) AXIsProcessTrusted=\(AXIsProcessTrusted()) CGPreflightPostEventAccess=\(postAccess)"
    }
}
