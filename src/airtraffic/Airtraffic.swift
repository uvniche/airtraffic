import Foundation
import Darwin
import AppKit
import UserNotifications

private var rawModeInputFD: Int32 = STDIN_FILENO

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 1.0
        let args = Array(CommandLine.arguments.dropFirst())
        let primary = args.first
        let once = args.contains("--once") || primary == "once"

        if primary == "daemon" {
            if args.last != "--daemonized" {
                launchctlBootout()
                killExistingDaemons()
                let exe = CommandLine.arguments[0]
                let child = Process()
                child.executableURL = URL(fileURLWithPath: exe)
                child.arguments = ["daemon", "--daemonized"]
                child.standardInput  = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError  = FileHandle.nullDevice
                try? child.run()
                print("Daemon started. Running in the background.")
                return
            }
            await runCollector(interval: interval)
            return
        }

        if primary == "status" {
            StatusCommand().run()
            return
        }

        if primary == "today" {
            await TodayCommand().run()
            return
        }

        if primary == "month" {
            await MonthCommand().run()
            return
        }

        if primary == "since" {
            await SinceCommand(args: Array(args.dropFirst())).run()
            return
        }

        if primary == "export" {
            ExportCommand(args: Array(args.dropFirst())).run()
            return
        }

        if primary == "limit" {
            LimitCommand(args: Array(args.dropFirst())).run()
            return
        }

        if primary == "limits" {
            LimitsCommand().run()
            return
        }

        if primary == "uninstall" {
            UninstallCommand().run()
            return
        }

        // live (explicit) or no subcommand → live 2s view
        var lastSnapshot: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        let nettop = NettopParser()
        let appResolver = AppNameResolver()
        let tty = openTTY()
        let pageSize = 10
        var currentPage = 0

        if once {
            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    ttyWrite(tty, "No network data available from nettop.\n")
                    return
                }
                let byApp = aggregateByApp(rows, resolver: appResolver)
                let deltas = byApp
                    .filter { ($0.bytesIn + $0.bytesOut) > 0 }
                    .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
                for row in deltas.prefix(pageSize) {
                    ttyWrite(tty, rowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut, interval: interval) + "\n")
                }
            } catch {
                ttyWrite(tty, "Error: \(error)\n")
            }
            return
        }

        // Enter alternate screen buffer — like top/htop, keeps main scrollback clean
        ttyWrite(tty, "\u{1B}[?1049h\u{1B}[2J\u{1B}[H")
        // Raw mode: suppress echo so scroll/key events don't print garbage on screen
        rawModeInputFD = STDIN_FILENO
        let savedTermios = enableRawMode(tty: FileHandle.standardInput)
        // Restore on Ctrl+C
        let sigHandler: @convention(c) (Int32) -> Void = { _ in
            var s = rawModeSaved
            tcsetattr(rawModeInputFD, TCSAFLUSH, &s)
            let restoreTTY = FileHandle(forWritingAtPath: "/dev/tty") ?? FileHandle.standardOutput
            if let d = "\u{1B}[?1049l".data(using: .utf8) { restoreTTY.write(d) }
            exit(0)
        }
        rawModeSaved = savedTermios
        signal(SIGINT, sigHandler)

        while true {
            if let key = readNavigationKeyNonBlocking() {
                if key == .nextPage {
                    currentPage += 1
                } else if key == .previousPage {
                    currentPage = max(0, currentPage - 1)
                }
            }

            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    continue
                }

                let byApp = aggregateByApp(rows, resolver: appResolver)

                var deltas: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = byApp.map { row in
                    let (prevIn, prevOut) = lastSnapshot[row.name] ?? (0, 0)
                    let dIn = row.bytesIn >= prevIn ? row.bytesIn - prevIn : row.bytesIn
                    let dOut = row.bytesOut >= prevOut ? row.bytesOut - prevOut : row.bytesOut
                    return (row.name, dIn, dOut)
                }

                lastSnapshot = Dictionary(uniqueKeysWithValues: byApp.map { ($0.name, ($0.bytesIn, $0.bytesOut)) })
                deltas = deltas
                    .filter { ($0.bytesIn + $0.bytesOut) > 0 }
                    .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }

                let totalPages = max(1, Int(ceil(Double(deltas.count) / Double(pageSize))))
                currentPage = min(currentPage, totalPages - 1)
                let start = currentPage * pageSize
                let end = min(start + pageSize, deltas.count)
                let display = start < end ? Array(deltas[start..<end]) : []

                var out = "\u{1B}[2J\u{1B}[H"
                out += "AirTraffic - Live\n\n"
                out += headerLines().joined(separator: "\n") + "\n"
                for row in display {
                    out += rowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut, interval: interval) + "\n"
                }
                out += "\n"
                out += "Page \(currentPage + 1)/\(totalPages)\n"
                out += "Controls: →=next page, ←=previous page, Ctrl+C=quit"
                ttyWrite(tty, out)
            } catch {
                ttyWrite(tty, "Error: \(error)\n")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Fires a macOS local notification. Requests permission on first call.
    static func sendLimitNotification(title: String, body: String) {
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

    /// Background collector: periodically samples nettop and persists per-app usage.
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

                    // Check per-app limits.
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

                    // Check overall daily limit.
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

    /// Sum bytes across all processes belonging to the same app.
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

    /// Filter noisy or transient processes that are not useful in user-facing usage tables.
    static func shouldIgnoreAppFromUsageTables(_ appName: String) -> Bool {
        let normalized = appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("mdnsresponder") || normalized.contains("mdnshelper") {
            return true
        }

        // Drop transient CLI invocations — nettop captures the full argv for short-lived
        // processes (e.g. "npm view vercel version"), which look like multi-word shell commands.
        // Real app names never contain more than ~3 words; anything with 4+ space-separated
        // tokens is almost certainly a CLI command, not a persistent app.
        let wordCount = appName.split(separator: " ").count
        if wordCount >= 4 { return true }

        return false
    }

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

    private static let colName  = 36
    private static let colDown  = 12
    private static let colUp    = 12
    private static let colTotal = 10

    static func fit(_ s: String, width: Int) -> String {
        if width <= 0 { return "" }
        if s.count == width { return s }
        if s.count < width {
            return s.padding(toLength: width, withPad: " ", startingAt: 0)
        }
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
            lines.append("Ctrl+C to quit")
        }
        return lines
    }

    /// Open /dev/tty for direct terminal output, bypassing any pipes from swift run.
    static func openTTY() -> FileHandle {
        if let tty = FileHandle(forUpdatingAtPath: "/dev/tty") { return tty }
        if let tty = FileHandle(forWritingAtPath: "/dev/tty") { return tty }
        return FileHandle.standardOutput
    }

    static func ttyWrite(_ tty: FileHandle, _ s: String) {
        if let data = s.data(using: .utf8) {
            tty.write(data)
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.2f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1000 {
            return String(format: "%.2f KB", Double(bytes) / 1000)
        } else {
            return "\(bytes) B"
        }
    }

    static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000_000 {
            return String(format: "%.2f GB/s", bytesPerSec / 1_000_000_000)
        } else if bytesPerSec >= 1_000_000 {
            return String(format: "%.2f MB/s", bytesPerSec / 1_000_000)
        } else if bytesPerSec >= 1000 {
            return String(format: "%.2f KB/s", bytesPerSec / 1000)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }

    /// Unload the LaunchAgent so launchd stops respawning the daemon.
    static func launchctlBootout() {
        let plistURL = LoginItemInstaller.plistURL
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(getuid())", plistURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    /// Re-register the LaunchAgent after the new daemon has been forked.
    static func launchctlBootstrap() {
        let plistURL = LoginItemInstaller.plistURL
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    /// Kill all airtraffic daemon processes except ourselves.
    static func killExistingDaemons() {
        let myPID = getpid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "ps -ax -o pid=,args= | grep 'airtraffic daemon' | grep -v grep"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
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

// MARK: - Shared live-table helpers for cumulative views

extension Airtraffic {
    static func runTodayLive() async {
        let interval: TimeInterval = 1.0
        let pageSize = 10
        let tty = openTTY()
        let nettop = NettopParser()
        let resolver = AppNameResolver()
        var lastSnapshot: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var currentPage = 0

        ttyWrite(tty, "\u{1B}[?1049h\u{1B}[2J\u{1B}[H")
        rawModeInputFD = STDIN_FILENO
        let savedTermios = enableRawMode(tty: FileHandle.standardInput)
        let sigHandler: @convention(c) (Int32) -> Void = { _ in
            var s = rawModeSaved
            tcsetattr(rawModeInputFD, TCSAFLUSH, &s)
            let restoreTTY = FileHandle(forWritingAtPath: "/dev/tty") ?? FileHandle.standardOutput
            if let d = "\u{1B}[?1049l".data(using: .utf8) { restoreTTY.write(d) }
            exit(0)
        }
        rawModeSaved = savedTermios
        signal(SIGINT, sigHandler)

        while true {
            if let key = readNavigationKeyNonBlocking() {
                if key == .nextPage {
                    currentPage += 1
                } else if key == .previousPage {
                    currentPage = max(0, currentPage - 1)
                }
            }

            guard let state = AirtrafficState.load() else {
                ttyWrite(tty, "\u{1B}[2J\u{1B}[HWaiting for data…\n\nCtrl+C to quit")
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                continue
            }

            let now = Date()
            guard Calendar.current.isDate(now, inSameDayAs: state.todayStart), !state.todayByApp.isEmpty else {
                ttyWrite(tty, "\u{1B}[2J\u{1B}[HNo data recorded for today yet.\n\nCtrl+C to quit")
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                continue
            }

            var rateByApp: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
            if let rows = try? nettop.sample(), !rows.isEmpty {
                let byApp = aggregateByApp(rows, resolver: resolver)
                for row in byApp {
                    let (prevIn, prevOut) = lastSnapshot[row.name] ?? (0, 0)
                    let dIn = row.bytesIn >= prevIn ? row.bytesIn - prevIn : row.bytesIn
                    let dOut = row.bytesOut >= prevOut ? row.bytesOut - prevOut : row.bytesOut
                    rateByApp[row.name] = (dIn, dOut)
                }
                lastSnapshot = Dictionary(uniqueKeysWithValues: byApp.map { ($0.name, ($0.bytesIn, $0.bytesOut)) })
            }

            let ranked = state.todayByApp
                .map { (name: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
                .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }

            let totalPages = max(1, Int(ceil(Double(ranked.count) / Double(pageSize))))
            currentPage = min(currentPage, totalPages - 1)
            let start = currentPage * pageSize
            let end = min(start + pageSize, ranked.count)
            let pageRows = start < end ? Array(ranked[start..<end]) : []

            var out = "\u{1B}[2J\u{1B}[H"
            out += "AirTraffic - Today\n\n"
            out += fit("Rank", width: 5) + " "
            out += fit("App", width: colName - 6) + " "
            out += fit("↓ Down", width: colDown) + " "
            out += fit("↑ Up", width: colUp) + " "
            out += fit("Total", width: colTotal) + "\n"
            out += String(repeating: "─", count: 5 + 1 + (colName - 6) + 1 + colDown + 1 + colUp + 1 + colTotal) + "\n"

            for (idx, row) in pageRows.enumerated() {
                let rank = start + idx + 1
                out += fit("\(rank)", width: 5) + " "
                out += fit(row.name, width: colName - 6) + " "
                out += fit(formatBytes(row.bytesIn), width: colDown) + " "
                out += fit(formatBytes(row.bytesOut), width: colUp) + " "
                out += fit(formatBytes(row.bytesIn + row.bytesOut), width: colTotal) + "\n"
            }

            let totalIn = ranked.reduce(UInt64(0)) { $0 + $1.bytesIn }
            let totalOut = ranked.reduce(UInt64(0)) { $0 + $1.bytesOut }
            out += String(repeating: "─", count: 5 + 1 + (colName - 6) + 1 + colDown + 1 + colUp + 1 + colTotal) + "\n"
            out += fit("", width: 5) + " "
            out += fit("TOTAL", width: colName - 6) + " "
            out += fit(formatBytes(totalIn), width: colDown) + " "
            out += fit(formatBytes(totalOut), width: colUp) + " "
            out += fit(formatBytes(totalIn + totalOut), width: colTotal) + "\n"
            out += "\n"
            out += "Page \(currentPage + 1)/\(totalPages)\n"
            out += "Controls: →=next page, ←=previous page, Ctrl+C=quit"
            ttyWrite(tty, out)

            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    enum NavigationKey {
        case nextPage
        case previousPage
    }

    static func readNavigationKeyNonBlocking() -> NavigationKey? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&pfd, 1, 0)
        guard ready > 0, (pfd.revents & Int16(POLLIN)) != 0 else {
            return nil
        }

        var byte: UInt8 = 0
        let bytesRead = Darwin.read(STDIN_FILENO, &byte, 1)
        guard bytesRead == 1 else { return nil }

        // Arrow keys arrive as ANSI escape sequences:
        // Left: ESC [ D, Right: ESC [ C
        if byte == 0x1B {
            var sequence = [UInt8](repeating: 0, count: 2)
            let seqRead = Darwin.read(STDIN_FILENO, &sequence, 2)
            guard seqRead == 2, sequence[0] == 0x5B else { return nil }
            if sequence[1] == 0x44 { return .previousPage } // Left
            if sequence[1] == 0x43 { return .nextPage }     // Right
            return nil
        }

        return nil
    }

    static func cumulativeHeaderLines() -> [String] {
        let app  = fit("App",   width: colName)
        let down = fit("↓ Down", width: colDown)
        let up   = fit("↑ Up",   width: colUp)
        let tot  = fit("Total",  width: colTotal)
        return [
            "\(app) \(down) \(up) \(tot)",
            String(repeating: "─", count: colName + 1 + colDown + 1 + colUp + 1 + colTotal),
        ]
    }

    static func cumulativeRowLine(name: String, bytesIn: UInt64, bytesOut: UInt64) -> String {
        let nameCol = fit(name, width: colName)
        let downStr = formatBytes(bytesIn)
        let upStr   = formatBytes(bytesOut)
        let totStr  = formatBytes(bytesIn + bytesOut)
        return "\(nameCol) \(fit(downStr, width: colDown)) \(fit(upStr, width: colUp)) \(fit(totStr, width: colTotal))"
    }

    /// Shared live-refresh loop for cumulative views (today / month / since).
    static func runLiveCumulative(
        dataProvider: () -> (title: String, apps: [(name: String, bytesIn: UInt64, bytesOut: UInt64)])?
    ) async {
        let interval: TimeInterval = 2.0
        let pageSize = 10
        let tty = openTTY()
        var currentPage = 0

        ttyWrite(tty, "\u{1B}[?1049h\u{1B}[2J\u{1B}[H")
        rawModeInputFD = STDIN_FILENO
        let savedTermios = enableRawMode(tty: FileHandle.standardInput)
        let sigHandler: @convention(c) (Int32) -> Void = { _ in
            var s = rawModeSaved
            tcsetattr(rawModeInputFD, TCSAFLUSH, &s)
            let restoreTTY = FileHandle(forWritingAtPath: "/dev/tty") ?? FileHandle.standardOutput
            if let d = "\u{1B}[?1049l".data(using: .utf8) { restoreTTY.write(d) }
            exit(0)
        }
        rawModeSaved = savedTermios
        signal(SIGINT, sigHandler)

        while true {
            if let key = readNavigationKeyNonBlocking() {
                if key == .nextPage {
                    currentPage += 1
                } else if key == .previousPage {
                    currentPage = max(0, currentPage - 1)
                }
            }

            if let (title, apps) = dataProvider() {
                let totalPages = max(1, Int(ceil(Double(apps.count) / Double(pageSize))))
                currentPage = min(currentPage, totalPages - 1)
                let start = currentPage * pageSize
                let end = min(start + pageSize, apps.count)
                let display = start < end ? Array(apps[start..<end]) : []
                var out = "\u{1B}[2J\u{1B}[H"
                out += title + "\n"
                out += "\n"
                for line in cumulativeHeaderLines() { out += line + "\n" }
                for row in display {
                    out += cumulativeRowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut) + "\n"
                }
                out += "\n"
                out += "Page \(currentPage + 1)/\(totalPages)\n"
                out += "Controls: →=next page, ←=previous page, Ctrl+C=quit"
                ttyWrite(tty, out)
            } else {
                ttyWrite(tty, "\u{1B}[2J\u{1B}[HWaiting for data…\n\nCtrl+C to quit")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

// MARK: - TTY raw mode

extension Airtraffic {
    @discardableResult
    static func enableRawMode(tty: FileHandle) -> termios {
        var saved = termios()
        tcgetattr(tty.fileDescriptor, &saved)
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(tty.fileDescriptor, TCSAFLUSH, &raw)
        return saved
    }
}
