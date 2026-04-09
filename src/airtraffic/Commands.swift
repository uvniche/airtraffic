import Foundation

// MARK: - Byte helpers

/// Parses human-readable byte strings like "500MB", "2GB", "1.5 GB" into bytes.
func parseBytes(_ s: String) -> UInt64? {
    let cleaned = s.trimmingCharacters(in: .whitespaces).uppercased()
        .replacingOccurrences(of: " ", with: "")
    let units: [(suffix: String, multiplier: UInt64)] = [
        ("GB", 1_000_000_000),
        ("MB", 1_000_000),
        ("KB", 1_000),
        ("B",  1),
    ]
    for (suffix, multiplier) in units {
        if cleaned.hasSuffix(suffix) {
            let numStr = String(cleaned.dropLast(suffix.count))
            if let value = Double(numStr), value > 0 {
                return UInt64(value * Double(multiplier))
            }
        }
    }
    return nil
}

func formatBytesLimit(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000_000 {
        return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    } else if bytes >= 1_000_000 {
        return String(format: "%.2f MB", Double(bytes) / 1_000_000)
    } else if bytes >= 1_000 {
        return String(format: "%.2f KB", Double(bytes) / 1_000)
    }
    return "\(bytes) B"
}

// MARK: - airtraffic status

struct StatusCommand {
    func run() {
        guard let state = AirtrafficState.load() else {
            print("App: not running (no state found).")
            return
        }
        let now = Date()
        let active = now.timeIntervalSince(state.lastUpdate) < 10

        print("App: \(active ? "running" : "not running")")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        print("Running since: \(formatter.string(from: state.collectorStart))")
    }
}

// MARK: - airtraffic help

struct HelpCommand {
    let args: [String]

    func run() {
        let topic = args.first?.lowercased()
        switch topic {
        case nil:
            printRoot()
        case "usage":
            printUsage()
        case "limits":
            printLimits()
        default:
            print("Unknown category: \(topic!)")
            print("")
            printRoot()
        }
    }

    private func printRoot() {
        print("""
        AirTraffic

        Use: help <category>

        Categories:
          usage
          limits
        """)
    }

    private func printUsage() {
        print("""
        AirTraffic

        Usage:
          status - Show how long the app has been running
          live - Live per-app view, refresh every second
          today - Per-app usage since 12:00 AM today
          month - Per-app usage since 12:00 AM on the first day of the current month
          since - Per-app usage since a specific date & time (format: dd:MM:yyyy HH:mm)
          export - Export per-app usage as a CSV file (period: today, month, or since)
        """)
    }

    private func printLimits() {
        print("""
        AirTraffic

        Limits:
          limit <app> <threshold> - Set a daily per-app data cap. Sends a macOS notification when exceeded
          limit <threshold> - Set an overall daily data cap (default when app is omitted)
          limits - Show all active limits with current usage vs cap
          limit clear - Remove a limit
        """)
    }

}

// MARK: - airtraffic today

struct TodayCommand {
    func run() async {
        await Airtraffic.runTodayLive()
    }
}

// MARK: - airtraffic month

struct MonthCommand {
    func run() async {
        await Airtraffic.runLiveCumulative {
            guard let state = AirtrafficState.load(),
                  state.monthStart != nil else { return nil }
            guard !state.monthByApp.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd:MM:yyyy HH:mm"
            let apps = state.monthByApp
                .map { (name: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
                .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            return ("AirTraffic - Month (since \(formatter.string(from: state.collectorStart)))", apps)
        }
    }
}

// MARK: - airtraffic since dd:MM:yyyy HH:mm

struct SinceCommand {
    let args: [String]

    func run() async {
        guard !args.isEmpty else {
            print("Usage: airtraffic since dd:MM:yyyy HH:mm")
            return
        }

        let dateString = args.joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd:MM:yyyy HH:mm"

        guard let sinceDate = formatter.date(from: dateString) else {
            print("Could not parse date/time '\(dateString)'. Expected format: dd:MM:yyyy HH:mm")
            return
        }

        var state = AirtrafficState.load() ?? AirtrafficState.empty(now: Date())
        let isNewWindow = state.sinceStart != sinceDate
        if isNewWindow {
            state.sinceStart = sinceDate
            state.sinceByApp = [:]
            state.persist()
        }

        let now = Date()
        if now <= sinceDate {
            print("Since-period starts in the future (\(formatter.string(from: sinceDate))). No data yet.")
            return
        }

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short

        await Airtraffic.runLiveCumulative {
            guard let s = AirtrafficState.load() else { return nil }
            guard !s.sinceByApp.isEmpty else { return nil }
            let apps = s.sinceByApp
                .map { (name: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
                .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            return ("AirTraffic - Since \(displayFormatter.string(from: sinceDate))", apps)
        }
    }
}

// MARK: - airtraffic export [today|month|since]

struct ExportCommand {
    let args: [String]

    /// <repo>/exports/ — all CSV exports land here.
    static var exportDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("exports", isDirectory: true)
    }

    func run() {
        let period = args.first ?? "today"
        guard let state = AirtrafficState.load() else {
            print("No data yet. Is the app running? Run: swift run airtraffic")
            return
        }

        let data: [String: AppUsage]
        let label: String
        switch period {
        case "month":
            data = state.monthByApp
            label = "month"
        case "since":
            data = state.sinceByApp
            label = "since"
        default:
            data = state.todayByApp
            label = "today"
        }

        guard !data.isEmpty else {
            print("No data recorded for \(label) yet.")
            return
        }

        let rows = data
            .map { (name: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
            .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }

        var csv = "App,Down,Up,Total\n"
        for row in rows {
            let name = row.name.replacingOccurrences(of: ",", with: ";")
            csv += "\(name),\(formatBytesLimit(row.bytesIn)),\(formatBytesLimit(row.bytesOut)),\(formatBytesLimit(row.bytesIn + row.bytesOut))\n"
        }

        let dir = Self.exportDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("Could not create export folder: \(error)")
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "airtraffic-\(label)-\(timestamp).csv"
        let fileURL = dir.appendingPathComponent(filename)

        do {
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Exported to \(fileURL.path)")
        } catch {
            print("Failed to write CSV: \(error)")
        }
    }
}

// MARK: - airtraffic limit / limits

struct LimitCommand {
    let args: [String]

    func run() {
        var args = self.args
        if args.first == "--total" {
            args.removeFirst()
        }
        guard !args.isEmpty else {
            printUsage()
            return
        }

        var state = AirtrafficState.load() ?? AirtrafficState.empty(now: Date())

        // limit clear <app|bare-size>
        if args.first == "clear" {
            let rest = Array(args.dropFirst())
            let target = rest.joined(separator: " ")
            if rest.count == 1 && parseBytes(rest[0]) != nil {
                state.totalLimit = nil
                state.notifiedLimits.remove("__total__")
                state.persist()
                print("Overall daily limit cleared.")
            } else if target.isEmpty {
                printUsage()
            } else {
                state.limits.removeValue(forKey: target)
                state.notifiedLimits.remove(target)
                state.persist()
                print("Limit cleared for \(target).")
            }
            return
        }

        // limit <threshold> — single bare size treated as overall limit
        if args.count == 1, let bytes = parseBytes(args[0]) {
            state.totalLimit = bytes
            state.notifiedLimits.remove("__total__")
            maybeNotifyImmediatelyForTotalLimit(&state)
            state.persist()
            print("Overall daily limit set to \(formatBytesLimit(bytes)).")
            return
        }

        // limit <app> <threshold>
        guard args.count >= 2 else { printUsage(); return }
        let threshold = args.last!
        let appName = args.dropLast().joined(separator: " ")
        guard let bytes = parseBytes(threshold) else {
            print("Could not parse '\(threshold)'. Use e.g. 500MB or 2GB.")
            return
        }
        state.limits[appName] = bytes
        state.notifiedLimits.remove(appName)
        maybeNotifyImmediatelyForPerAppLimit(&state, appName: appName, cap: bytes)
        state.persist()
        print("Daily limit for \(appName) set to \(formatBytesLimit(bytes)).")
    }

    private func maybeNotifyImmediatelyForTotalLimit(_ state: inout AirtrafficState) {
        guard let cap = state.totalLimit else { return }
        let used = state.todayByApp.values.reduce(UInt64(0)) { $0 + $1.bytesIn + $1.bytesOut }
        guard used >= cap else { return }
        Airtraffic.sendLimitNotification(
            title: "Daily data limit reached",
            body: "Total usage today is \(formatBytesLimit(used)) (limit: \(formatBytesLimit(cap)))."
        )
        state.notifiedLimits.insert("__total__")
    }

    private func maybeNotifyImmediatelyForPerAppLimit(_ state: inout AirtrafficState, appName: String, cap: UInt64) {
        let usage = state.todayByApp[appName]
        let used = (usage?.bytesIn ?? 0) + (usage?.bytesOut ?? 0)
        guard used >= cap else { return }
        Airtraffic.sendLimitNotification(
            title: "\(appName) data limit reached",
            body: "\(appName) has used \(formatBytesLimit(used)) today (limit: \(formatBytesLimit(cap)))."
        )
        state.notifiedLimits.insert(appName)
    }

    private func printUsage() {
        print("""
        Usage:
          airtraffic limit <app> <threshold>      e.g. airtraffic limit "Google Chrome" 500MB
          airtraffic limit <threshold>            e.g. airtraffic limit 2GB (treated as overall limit)
          airtraffic limit clear <app>            remove a per-app limit
          airtraffic limit clear <threshold>      remove the overall limit
        """)
    }
}

struct LimitsCommand {
    func run() {
        guard let state = AirtrafficState.load() else {
            print("No data yet. Is the app running? Run: swift run airtraffic")
            return
        }

        let hasPerApp = !state.limits.isEmpty
        let hasTotal = state.totalLimit != nil

        guard hasPerApp || hasTotal else {
            print("No limits set.")
            return
        }

        if hasTotal {
            let cap = state.totalLimit!
            let used = state.todayByApp.values.reduce(UInt64(0)) { $0 + $1.bytesIn + $1.bytesOut }
            let pct = min(100, Int(Double(used) / Double(cap) * 100))
            let status = used >= cap ? " ⚠ EXCEEDED" : ""
            print("Overall:  \(formatBytesLimit(used)) / \(formatBytesLimit(cap))  (\(pct)%)\(status)")
        }

        if hasPerApp {
            if hasTotal { print("") }
            let sorted = state.limits.sorted { $0.key < $1.key }
            for (app, cap) in sorted {
                let usage = state.todayByApp[app]
                let used = (usage?.bytesIn ?? 0) + (usage?.bytesOut ?? 0)
                let pct = min(100, Int(Double(used) / Double(cap) * 100))
                let status = used >= cap ? " ⚠ EXCEEDED" : ""
                let appCol = app.padding(toLength: 28, withPad: " ", startingAt: 0)
                print("\(appCol)  \(formatBytesLimit(used)) / \(formatBytesLimit(cap))  (\(pct)%)\(status)")
            }
        }
    }
}

// MARK: - airtraffic uninstall

struct UninstallCommand {
    func run() {
        let fm = FileManager.default
        let plistURL = LoginItemInstaller.plistURL

        Airtraffic.launchctlBootout()
        Airtraffic.killExistingDaemons()
        if fm.fileExists(atPath: plistURL.path) {
            try? fm.removeItem(at: plistURL)
        }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dataDir = base.appendingPathComponent("airtraffic", isDirectory: true)
        if fm.fileExists(atPath: dataDir.path) {
            try? fm.removeItem(at: dataDir)
        }

        print("Uninstalled.")
    }
}
