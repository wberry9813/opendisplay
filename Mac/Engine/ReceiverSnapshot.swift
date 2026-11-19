import Foundation

enum ReceiverSnapshot {
    /// UUID spelling is not identity. Do not case-fold arbitrary/unknown identifiers.
    static func installID(_ value: String?) -> String? {
        value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }

    static func receiverID(_ value: String) -> String {
        guard value.hasPrefix("install:"), let id = installID(String(value.dropFirst(8))) else { return value }
        return "install:\(id)"
    }

    static func sameDevice(serviceInstallID: String?, usbInstallID: String?) -> Bool {
        if let service = installID(serviceInstallID), let usb = installID(usbInstallID) { return service == usb }
        // Name equality cannot establish physical identity (two iPads may share a name).
        return false
    }
    /// One install may advertise several services/interfaces. Identity evidence,
    /// never a display name alone, combines already-correlated transport rows.
    static func deduplicate(_ rows: [[String: Any]]) -> [[String: Any]] {
        var merged: [String: [String: Any]] = [:]
        for row in rows {
            guard let raw = row["receiverID"] as? String else { continue }
            let id = receiverID(raw)
            var row = row
            row["receiverID"] = id
            if var existing = merged[id] {
                let transports = Set(existing["transports"] as? [String] ?? [])
                    .union(row["transports"] as? [String] ?? [])
                existing["transports"] = transports.sorted()
                existing["usbUDIDs"] = Set(existing["usbUDIDs"] as? [String] ?? [])
                    .union(row["usbUDIDs"] as? [String] ?? []).sorted()
                #if DEBUG
                let route = DirectIdentityDiagnostics.fingerprint(id)
                DirectIdentityDiagnostics.event("helper.snapshot-group", ["route_fp": route,
                    "reason": "same-receiver-id", "transports": transports.sorted().joined(separator: ","),
                    "usb_udid_fps": (existing["usbUDIDs"] as? [String] ?? []).map { DirectIdentityDiagnostics.comparisonFingerprint($0) }.sorted().joined(separator: ",")], key: "snapshot-group:\(route)")
                #endif
                for (key, value) in row where existing[key] == nil { existing[key] = value }
                merged[id] = existing
            } else { merged[id] = row }
        }
        return merged.keys.sorted().compactMap { merged[$0] }
    }
}
