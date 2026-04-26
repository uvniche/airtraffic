import Foundation
import Darwin
import AppKit
import UserNotifications

extension Airtraffic {
    static func currentExecutableURL() -> URL {
        let fm = FileManager.default
        if let url = Bundle.main.executableURL {
            return url
        }
        let arg0 = CommandLine.arguments.first ?? "airtraffic"
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0)
        }
        let cwd = fm.currentDirectoryPath
        return URL(fileURLWithPath: arg0, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
    }

    static func startCollectorIfNeeded() {
        let desiredExe = currentExecutableURL().path
        if isCollectorProbablyRunning() {
            if runningCollectorProgramPathFromLaunchctl() == desiredExe {
                return
            }
            // Migration path: collector is up, but using a different executable path.
            launchctlBootout()
            killExistingDaemons()
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: desiredExe)
        child.arguments = ["daemon", "--daemonized"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
    }

    static func isCollectorProbablyRunning(activeStateThresholdSeconds: TimeInterval = 10) -> Bool {
        if let state = AirtrafficState.load() {
            let now = Date()
            if now.timeIntervalSince(state.lastUpdate) < activeStateThresholdSeconds {
                return true
            }
        }

        guard let pid = runningCollectorPIDFromLaunchctl() else { return false }
        // `kill(pid, 0)` doesn't actually signal; it checks for existence/permission.
        return kill(pid, 0) == 0
    }

    private static func runningCollectorPIDFromLaunchctl() -> pid_t? {
        let uid = getuid()
        let context = "gui/\(uid)/\(LoginItemInstaller.label)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["print", context]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Example line: "pid = 12345"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("pid =") else { continue }
            let parts = trimmed.split(separator: " ")
            if let last = parts.last, let pid = Int32(last) {
                return pid_t(pid)
            }
        }
        return nil
    }

    private static func runningCollectorProgramPathFromLaunchctl() -> String? {
        let uid = getuid()
        let context = "gui/\(uid)/\(LoginItemInstaller.label)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["print", context]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Example line: "program = /path/to/airtraffic"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("program =") else { continue }
            return String(trimmed.dropFirst("program =".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Fires a macOS local notification. Requests permission on first call.
    static func sendLimitNotification(title: String, body: String) {
        if shouldUseAppleScriptNotifications() {
            sendAppleScriptNotification(title: title, body: body)
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    static func shouldUseAppleScriptNotifications() -> Bool {
        let bundleURLPath = Bundle.main.bundleURL.path
        return bundleURLPath.contains("/.build/")
    }

    static func sendAppleScriptNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \(appleScriptQuoted(body)) with title \(appleScriptQuoted(title)) sound name \"default\""
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static func appleScriptQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func collectorLogURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("airtraffic", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("collector.log")
    }

    static func logCollectorError(_ error: Error) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] collector tick failed: \(String(describing: error))\n"
        let logURL = collectorLogURL()
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    static func runCollector(interval: TimeInterval) async {
        LoginItemInstaller.ensureInstalledIfNeeded()
        launchctlBootstrap()

        let nettop = NettopParser()
        let resolver = AppNameResolver()
        var state = AirtrafficState.load() ?? AirtrafficState.empty(now: Date())
        state.collectorStart = Date()

        if state.monthStart == nil {
            let now = Date()
            let calendar = Calendar.current
            let midnight = calendar.startOfDay(for: now)
            state.monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? midnight
            state.monthByApp = [:]
        }

        while true {
            autoreleasepool {
                do {
                    state.reloadMutableConfig()
                    let rows = try nettop.sample()
                    guard !rows.isEmpty else { return }
                    let byApp = aggregateByApp(rows, resolver: resolver)
                    let now = Date()

                    if !Calendar.current.isDate(now, inSameDayAs: state.todayStart) {
                        state.resetToday(now: now)
                    }

                    if let monthStart = state.monthStart,
                       !Calendar.current.isDate(now, equalTo: monthStart, toGranularity: .month) {
                        let calendar = Calendar.current
                        let midnight = calendar.startOfDay(for: now)
                        state.monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? midnight
                        state.monthByApp = [:]
                    }

                    for row in byApp {
                        let key = row.name
                        let previous = state.lastSnapshot[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                        // If per-process counters reset/restart, treat current sample as new baseline traffic
                        // (same behavior as `live`) instead of dropping the app from cumulative views.
                        let dIn = row.bytesIn >= previous.bytesIn ? row.bytesIn - previous.bytesIn : row.bytesIn
                        let dOut = row.bytesOut >= previous.bytesOut ? row.bytesOut - previous.bytesOut : row.bytesOut
                        state.lastSnapshot[key] = AppUsage(bytesIn: row.bytesIn, bytesOut: row.bytesOut)
                        if dIn == 0 && dOut == 0 { continue }

                        var todayUsage = state.todayByApp[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                        todayUsage.bytesIn &+= dIn
                        todayUsage.bytesOut &+= dOut
                        state.todayByApp[key] = todayUsage

                        var monthUsage = state.monthByApp[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                        monthUsage.bytesIn &+= dIn
                        monthUsage.bytesOut &+= dOut
                        state.monthByApp[key] = monthUsage

                        if let sinceStart = state.sinceStart, now >= sinceStart {
                            var sinceUsage = state.sinceByApp[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                            sinceUsage.bytesIn &+= dIn
                            sinceUsage.bytesOut &+= dOut
                            state.sinceByApp[key] = sinceUsage
                        }
                    }

                    state.lastUpdate = now
                    state.persist()

                    for (app, cap) in state.limits {
                        guard !state.notifiedLimits.contains(app) else { continue }
                        let usage = state.todayByApp[app]
                        let used = (usage?.bytesIn ?? 0) + (usage?.bytesOut ?? 0)
                        if used >= cap {
                            sendLimitNotification(
                                title: "\(app) data limit reached",
                                body: "\(app) has used \(formatBytesLimit(used)) today (limit: \(formatBytesLimit(cap)))."
                            )
                            state.notifiedLimits.insert(app)
                            state.persist()
                        }
                    }

                    if let totalCap = state.totalLimit, !state.notifiedLimits.contains("__total__") {
                        let totalUsed = state.todayByApp.values.reduce(UInt64(0)) { $0 + $1.bytesIn + $1.bytesOut }
                        if totalUsed >= totalCap {
                            sendLimitNotification(
                                title: "Daily data limit reached",
                                body: "Total usage today is \(formatBytesLimit(totalUsed)) (limit: \(formatBytesLimit(totalCap)))."
                            )
                            state.notifiedLimits.insert("__total__")
                            state.persist()
                        }
                    }
                } catch {
                    logCollectorError(error)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    static func aggregateByApp(
        _ rows: [(name: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64)],
        resolver: AppNameResolver
    ) -> [(name: String, bytesIn: UInt64, bytesOut: UInt64)] {
        var sum: [String: (displayName: String, bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for row in rows {
            let resolved = resolver.resolve(forPID: row.pid, fallbackProcessName: row.name)
            if shouldIgnoreAppFromUsageTables(resolved.displayName) { continue }
            let existing = sum[resolved.groupKey] ?? (resolved.displayName, 0, 0)
            sum[resolved.groupKey] = (existing.0, existing.1 + row.bytesIn, existing.2 + row.bytesOut)
        }
        return sum.map { (name: $0.value.displayName, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
    }

    static func shouldIgnoreAppFromUsageTables(_ appName: String) -> Bool {
        let normalized = appName.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("mdnsresponder") || normalized.contains("mdnshelper") { return true }
        let wordCount = appName.split(separator: " ").count
        return wordCount >= 4
    }

    static let colName = 36
    static let colDown = 12
    static let colUp = 12
    static let colTotal = 10

    static func rowLine(name: String, bytesIn: UInt64, bytesOut: UInt64, interval: TimeInterval) -> String {
        let inRate = Double(bytesIn) / interval
        let outRate = Double(bytesOut) / interval
        let totalRate = inRate + outRate
        let nameCol = fit(name, width: colName)
        return "\(nameCol) \(fit(formatRate(inRate), width: colDown)) \(fit(formatRate(outRate), width: colUp)) \(fit(formatRate(totalRate), width: colTotal))"
    }

    static func fit(_ s: String, width: Int) -> String {
        if width <= 0 { return "" }
        if s.count == width { return s }
        if s.count < width { return s.padding(toLength: width, withPad: " ", startingAt: 0) }
        return String(s.prefix(width))
    }

    static func openTTY() -> FileHandle {
        if let tty = FileHandle(forUpdatingAtPath: "/dev/tty") { return tty }
        if let tty = FileHandle(forWritingAtPath: "/dev/tty") { return tty }
        return FileHandle.standardOutput
    }

    static func ttyWrite(_ tty: FileHandle, _ s: String) {
        if let data = s.data(using: .utf8) { tty.write(data) }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.2f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1000 { return String(format: "%.2f KB", Double(bytes) / 1000) }
        return "\(bytes) B"
    }

    static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000_000 { return String(format: "%.2f GB/s", bytesPerSec / 1_000_000_000) }
        if bytesPerSec >= 1_000_000 { return String(format: "%.2f MB/s", bytesPerSec / 1_000_000) }
        if bytesPerSec >= 1000 { return String(format: "%.2f KB/s", bytesPerSec / 1000) }
        return String(format: "%.0f B/s", bytesPerSec)
    }

    static func launchctlBootout() {
        let plistURL = LoginItemInstaller.plistURL
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(getuid())", plistURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    static func launchctlBootstrap() {
        let plistURL = LoginItemInstaller.plistURL
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    static func killExistingDaemons() {
        let myPID = getpid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "ps -ax -o pid=,args= | grep 'airtraffic daemon' | grep -v grep"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if let pidStr = parts.first, let pid = pid_t(pidStr), pid != myPID {
                kill(pid, SIGTERM)
            }
        }
        usleep(500_000)
    }
}
