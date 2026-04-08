import Foundation
import Darwin
import AppKit
import UserNotifications

extension Airtraffic {
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
                        let dIn = row.bytesIn >= previous.bytesIn ? row.bytesIn - previous.bytesIn : 0
                        let dOut = row.bytesOut >= previous.bytesOut ? row.bytesOut - previous.bytesOut : 0
                        if dIn == 0 && dOut == 0 { continue }
                        var todayUsage = state.todayByApp[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                        todayUsage.bytesIn &+= dIn
                        todayUsage.bytesOut &+= dOut
                        state.todayByApp[key] = todayUsage
                        state.lastSnapshot[key] = AppUsage(bytesIn: row.bytesIn, bytesOut: row.bytesOut)

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

    static func headerLines() -> [String] {
        let app = fit("App", width: colName)
        let down = fit("↓ Down/s", width: colDown)
        let up = fit("↑ Up/s", width: colUp)
        let total = fit("Total/s", width: colTotal)
        return [
            "\(app) \(down) \(up) \(total)",
            String(repeating: "─", count: colName + 1 + colDown + 1 + colUp + 1 + colTotal),
        ]
    }

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
        if width == 1 { return "…" }
        return String(s.prefix(width - 1)) + "…"
    }

    static func renderLines(
        display: [(name: String, bytesIn: UInt64, bytesOut: UInt64)],
        topN: Int,
        interval: TimeInterval,
        includeFooter: Bool
    ) -> [String] {
        var lines: [String] = display.prefix(topN).map {
            rowLine(name: $0.name, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, interval: interval)
        }
        if includeFooter {
            lines.append("")
            lines.append("Esc - go back")
        }
        return lines
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
