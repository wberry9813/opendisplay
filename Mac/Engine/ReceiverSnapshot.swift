import Foundation

enum ReceiverSnapshot {
    static func sameDevice(serviceInstallID: String?, usbInstallID: String?,
                           serviceName: String?, usbName: String?) -> Bool {
        if let serviceInstallID, let usbInstallID { return serviceInstallID == usbInstallID }
        return serviceName != nil && serviceName == usbName
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
                for (key, value) in row where existing[key] == nil { existing[key] = value }
                merged[id] = existing
            } else { merged[id] = row }
        }
        return merged.keys.sorted().compactMap { merged[$0] }
    }
}
