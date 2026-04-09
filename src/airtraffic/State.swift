import Foundation

struct AirtrafficState: Codable {
    var collectorStart: Date
    var lastUpdate: Date
    var todayStart: Date
    var todayByApp: [String: AppUsage]
    var lastSnapshot: [String: AppUsage]
    var monthStart: Date?
    var monthByApp: [String: AppUsage] = [:]
    var sinceStart: Date?
    var sinceByApp: [String: AppUsage] = [:]

    /// Per-app daily byte limits keyed by app display name.
    var limits: [String: UInt64] = [:]
    /// Optional overall daily byte limit across all apps.
    var totalLimit: UInt64? = nil
    /// Tracks which limit keys have already triggered a notification today.
    /// Uses app name for per-app limits and the special key "__total__" for the overall limit.
    var notifiedLimits: Set<String> = []

    static func empty(now: Date) -> AirtrafficState {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? midnight
        return AirtrafficState(
            collectorStart: now,
            lastUpdate: now,
            todayStart: midnight,
            todayByApp: [:],
            lastSnapshot: [:],
            monthStart: monthStart,
            monthByApp: [:],
            sinceStart: nil,
            sinceByApp: [:]
        )
    }

    mutating func resetToday(now: Date) {
        let calendar = Calendar.current
        todayStart = calendar.startOfDay(for: now)
        todayByApp = [:]
        notifiedLimits = []
    }

    static func stateURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("airtraffic", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    static func load() -> AirtrafficState? {
        let url = stateURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AirtrafficState.self, from: data)
    }

    func persist() {
        let url = Self.stateURL()
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Reload only the fields that CLI commands can mutate while the daemon is running.
    /// Call this at the top of each collector tick so that `limit`, `since`, etc. are
    /// never silently overwritten by the daemon's stale in-memory copy.
    mutating func reloadMutableConfig() {
        guard let fresh = Self.load() else { return }
        limits = fresh.limits
        totalLimit = fresh.totalLimit
        notifiedLimits = fresh.notifiedLimits
        if fresh.sinceStart != sinceStart {
            sinceStart = fresh.sinceStart
            sinceByApp = fresh.sinceByApp
        }
    }
}

struct AppUsage: Codable {
    var bytesIn: UInt64
    var bytesOut: UInt64
}

/// Installs a LaunchAgent so the collector runs automatically at login.
enum LoginItemInstaller {
    static let label = "com.uvniche.airtraffic.collector"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static func ensureInstalledIfNeeded() {
        let fm = FileManager.default
        let plistURL = Self.plistURL
        let executableURL = Airtraffic.preferredCollectorExecutableURL()
        var shouldRewrite = true

        if fm.fileExists(atPath: plistURL.path),
           let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = plist["ProgramArguments"] as? [String],
           args.count >= 2,
           args[0] == executableURL.path,
           args[1] == "daemon" {
            shouldRewrite = false
        }

        if !shouldRewrite { return }

        do {
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: plistURL.path) {
                try? fm.removeItem(at: plistURL)
            }

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executableURL.path, "daemon"],
                "RunAtLoad": true,
                "KeepAlive": true,
            ]

            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)

            let uid = getuid()
            let context = "gui/\(uid)"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["bootstrap", context, plistURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        } catch {
            return
        }
    }
}
