import Foundation

enum ReceiverSnapshot {
    static func sameDevice(serviceInstallID: String?, usbInstallID: String?) -> Bool {
        if let serviceInstallID, let usbInstallID { return serviceInstallID == usbInstallID }
        // Name equality cannot establish physical identity (two iPads may share a name).
        return false
    }
    /// One install may advertise several services/interfaces. Identity evidence,
    /// never a display name alone, combines already-correlated transport rows.
    static func deduplicate(_ rows: [[String: Any]]) -> [[String: Any]] {
        var merged: [String: [String: Any]] = [:]
        for row in rows {
            guard let id = row["receiverID"] as? String else { continue }
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
