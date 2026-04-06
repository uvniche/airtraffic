import Foundation
import Darwin
import AppKit

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 1.0
        let args = Array(CommandLine.arguments.dropFirst())
        let primary = args.first
        let once = args.contains("--once") || primary == "once"

        if primary == "daemon" {
            // If we're not already the detached child, stop launchd + kill all
            // existing daemons, then re-launch ourselves and re-register launchd.
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

        if primary == "uninstall" {
            UninstallCommand().run()
            return
        }

        // live (explicit) or no subcommand → live 2s view
        var lastSnapshot: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        let nettop = NettopParser()
        let appResolver = AppNameResolver()
        let tty = openTTY()
        let topN = 20

        if once {
            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    ttyWrite(tty, "No network data available from nettop.\n")
                    return
                }
                let byApp = aggregateByApp(rows, resolver: appResolver)
                let deltas = byApp.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
                for row in deltas.prefix(topN) {
                    ttyWrite(tty, rowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut, interval: interval) + "\n")
                }
            } catch {
                ttyWrite(tty, "Error: \(error)\n")
            }
            return
        }

        // Enter alternate screen buffer — like top/htop, keeps main scrollback clean
        ttyWrite(tty, "\u{1B}[?1049h")
        // Raw mode: suppress echo so scroll/key events don't print garbage on screen
        let savedTermios = enableRawMode(tty: tty)
        // Restore on Ctrl+C
        let sigHandler: @convention(c) (Int32) -> Void = { _ in
            let restoreTTY = FileHandle(forWritingAtPath: "/dev/tty") ?? FileHandle.standardOutput
            var s = rawModeSaved
            tcsetattr(restoreTTY.fileDescriptor, TCSAFLUSH, &s)
            if let d = "\u{1B}[?1049l".data(using: .utf8) { restoreTTY.write(d) }
            exit(0)
        }
        rawModeSaved = savedTermios
        signal(SIGINT, sigHandler)

        while true {
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
                deltas.sort { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }

                let nonZero = deltas.filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
                let display = nonZero.isEmpty ? Array(deltas.prefix(topN)) : Array(nonZero.prefix(topN))

                var out = "\u{1B}[H\u{1B}[J"  // cursor home + erase to end (within alternate buffer)
                out += "AirTraffic – live per-app network usage\n"
                out += "\n"
                out += headerLines().joined(separator: "\n") + "\n"
                for row in display {
                    out += rowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut, interval: interval) + "\n"
                }
                out += "\n"
                out += "Ctrl+C to quit"
                ttyWrite(tty, out)
            } catch {
                ttyWrite(tty, "Error: \(error)\n")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Background collector: periodically samples nettop and persists per-app usage.
    static func runCollector(interval: TimeInterval) async {
        LoginItemInstaller.ensureInstalledIfNeeded()
        // Re-register with launchd now that we're the one true daemon process,
        // so KeepAlive works if we crash (but won't spawn duplicates on normal restart).
        launchctlBootstrap()

        let nettop = NettopParser()
        let resolver = AppNameResolver()
        var state = AirtrafficState.load() ?? AirtrafficState.empty(now: Date())
        // Always stamp the real start time of this daemon process.
        state.collectorStart = Date()

        // Ensure month start exists for older state files.
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
                    let rows = try nettop.sample()
                    guard !rows.isEmpty else { return }
                    let byApp = aggregateByApp(rows, resolver: resolver)
                    let now = Date()

                    // Reset "today" counters if day changed.
                    if !Calendar.current.isDate(now, inSameDayAs: state.todayStart) {
                        state.resetToday(now: now)
                    }

                    // Reset monthly counters if month changed.
                    if let monthStart = state.monthStart,
                       !Calendar.current.isDate(now, equalTo: monthStart, toGranularity: .month) {
                        let calendar = Calendar.current
                        let midnight = calendar.startOfDay(for: now)
                        state.monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? midnight
                        state.monthByApp = [:]
                    }

                    // Compute deltas vs last snapshot and accumulate into today's totals.
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

                        // Accumulate into monthly totals.
                        var monthUsage = state.monthByApp[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                        monthUsage.bytesIn &+= dIn
                        monthUsage.bytesOut &+= dOut
                        state.monthByApp[key] = monthUsage

                        // Accumulate into custom-since totals if configured.
                        if let sinceStart = state.sinceStart, now >= sinceStart {
                            var sinceUsage = state.sinceByApp[key] ?? AppUsage(bytesIn: 0, bytesOut: 0)
                            sinceUsage.bytesIn &+= dIn
                            sinceUsage.bytesOut &+= dOut
                            state.sinceByApp[key] = sinceUsage
                        }
                    }

                    state.lastUpdate = now
                    state.persist()
                } catch {
                    // If nettop fails, quietly exit collector.
                    return
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Sum bytes across all processes belonging to the same app.
    /// Groups by bundle ID when available so two apps that both have a process called
    /// "Helper" don't incorrectly merge into one row.
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

    /// Filter noisy system discovery traffic that is not useful in user-facing usage tables.
    static func shouldIgnoreAppFromUsageTables(_ appName: String) -> Bool {
        let normalized = appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized.contains("mdnsresponder") || normalized.contains("mdnshelper")
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

    private static let colName = 36
    private static let colDown = 12
    private static let colUp = 12
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
    /// Falls back to stdout if /dev/tty is unavailable (e.g. in CI).
    static func openTTY() -> FileHandle {
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

    /// Kill all airtraffic daemon processes (those with "daemon" in args) except ourselves.
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

/// Persistent usage state for the daemon.
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

        // If plist already exists, assume it's installed.
        if fm.fileExists(atPath: plistURL.path) {
            return
        }

        do {
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Resolve the current executable path.
            let executableURL: URL = {
                if let url = Bundle.main.executableURL {
                    return url
                }
                let arg0 = CommandLine.arguments.first ?? "airtraffic"
                if arg0.hasPrefix("/") {
                    return URL(fileURLWithPath: arg0)
                } else {
                    let cwd = fm.currentDirectoryPath
                    return URL(fileURLWithPath: arg0, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
                }
            }()

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

            // Ask launchd to load it so it will run at login (and now, if not already).
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
            // Best-effort; failure just means the user can install manually.
            return
        }
    }
}

/// `airtraffic status`
struct StatusCommand {
    func run() {
        guard let state = AirtrafficState.load() else {
            print("Daemon: not running (no state found).")
            return
        }
        let now = Date()
        let active = now.timeIntervalSince(state.lastUpdate) < 10

        print("Daemon: \(active ? "running" : "not running")")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        print("Running since: \(formatter.string(from: state.collectorStart))")
    }
}

// MARK: - Shared live-table helpers for cumulative views

extension Airtraffic {
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
        let topN = 30
        let tty = openTTY()

        ttyWrite(tty, "\u{1B}[?1049h")
        let savedTermios = enableRawMode(tty: tty)
        let sigHandler: @convention(c) (Int32) -> Void = { _ in
            let restoreTTY = FileHandle(forWritingAtPath: "/dev/tty") ?? FileHandle.standardOutput
            var s = rawModeSaved
            tcsetattr(restoreTTY.fileDescriptor, TCSAFLUSH, &s)
            if let d = "\u{1B}[?1049l".data(using: .utf8) { restoreTTY.write(d) }
            exit(0)
        }
        rawModeSaved = savedTermios
        signal(SIGINT, sigHandler)

        while true {
            if let (title, apps) = dataProvider() {
                let display = Array(apps.prefix(topN))
                var out = "\u{1B}[H\u{1B}[J"
                out += title + "\n"
                out += "\n"
                for line in cumulativeHeaderLines() { out += line + "\n" }
                for row in display {
                    out += cumulativeRowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut) + "\n"
                }
                out += "\n"
                out += "Ctrl+C to quit"
                ttyWrite(tty, out)
            } else {
                ttyWrite(tty, "\u{1B}[H\u{1B}[JWaiting for data…\n\nCtrl+C to quit")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

// MARK: - Commands

/// `airtraffic today`
struct TodayCommand {
    func run() async {
        await Airtraffic.runLiveCumulative {
            guard let state = AirtrafficState.load() else { return nil }
            let now = Date()
            guard Calendar.current.isDate(now, inSameDayAs: state.todayStart) else { return nil }
            guard !state.todayByApp.isEmpty else { return nil }
            let apps = state.todayByApp
                .map { (name: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
                .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            return ("Per-app usage since midnight (cumulative):", apps)
        }
    }
}

/// `airtraffic month`
struct MonthCommand {
    func run() async {
        await Airtraffic.runLiveCumulative {
            guard let state = AirtrafficState.load(),
                  let monthStart = state.monthStart else { return nil }
            guard !state.monthByApp.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let apps = state.monthByApp
                .map { (name: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
                .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            return ("Per-app usage since \(formatter.string(from: monthStart)) (cumulative):", apps)
        }
    }
}

/// `airtraffic since dd:MM:yyyy HH:mm`
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

        // Set / reset the since window in persisted state.
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
            return ("Per-app usage since \(displayFormatter.string(from: sinceDate)) (cumulative):", apps)
        }
    }
}

/// `airtraffic export [today|month|since]` – dump usage as CSV to stdout.
struct ExportCommand {
    let args: [String]

    func run() {
        let period = args.first ?? "today"
        guard let state = AirtrafficState.load() else {
            print("No data yet. Is the daemon running? Try: airtraffic daemon")
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

        print("App,Bytes In,Bytes Out,Total Bytes")
        for row in rows {
            let name = row.name.replacingOccurrences(of: ",", with: ";")
            print("\(name),\(row.bytesIn),\(row.bytesOut),\(row.bytesIn + row.bytesOut)")
        }
    }
}

/// `airtraffic uninstall` – remove login item and delete all data.
struct UninstallCommand {
    func run() {
        let fm = FileManager.default
        let plistURL = LoginItemInstaller.plistURL

        // Unload LaunchAgent so launchd stops respawning, then kill all daemons.
        Airtraffic.launchctlBootout()
        Airtraffic.killExistingDaemons()
        // Remove the plist so it doesn’t run at next login.
        if fm.fileExists(atPath: plistURL.path) {
            try? fm.removeItem(at: plistURL)
        }

        // Delete all stored data (state.json and the app support directory).
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dataDir = base.appendingPathComponent("airtraffic", isDirectory: true)
        if fm.fileExists(atPath: dataDir.path) {
            try? fm.removeItem(at: dataDir)
        }

        print("Uninstalled. Login item removed and all data deleted.")
    }
}

/// Global storage for the saved terminal state so the C signal handler can access it.
var rawModeSaved = termios()

extension Airtraffic {
    /// Put the tty into raw mode (no echo, no canonical input) so scroll/key events
    /// from the trackpad don't get echoed as garbage characters on screen.
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

struct NettopParser {
    private let bytesInIndex: Int
    private let bytesOutIndex: Int

    init() {
        self.bytesInIndex = 4
        self.bytesOutIndex = 5
    }

    /// Run nettop once and parse CSV into per-process rows (process name, pid, bytes in, bytes out).
    func sample() throws -> [(name: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "1", "-P", "-x", "-t", "wifi", "-t", "wired", "-n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var rows: [(name: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64)] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return [] }

        for line in lines.dropFirst(1) {
            let parsed = parseCSVLine(line)
            guard parsed.count > bytesOutIndex,
                  let bytesIn = UInt64(parsed[bytesInIndex].trimmingCharacters(in: .whitespaces)),
                  let bytesOut = UInt64(parsed[bytesOutIndex].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = parsed.count > 1 ? parsed[1].trimmingCharacters(in: .whitespaces) : "?"
            if name.isEmpty || name == "interface" { continue }
            let pid = extractPID(from: name)
            rows.append((name: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut))
        }

        return rows
    }

    /// Extract PID from nettop process column (e.g. "Chrome.12345" or "Cursor Helper (.5306").
    private func extractPID(from name: String) -> Int32 {
        if let dot = name.lastIndex(of: ".") {
            let after = name[name.index(after: dot)...]
                .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            if let n = Int32(after), n > 0 { return n }
        }
        if let openParen = name.lastIndex(of: "(") {
            let after = name[name.index(after: openParen)...]
                .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            if let n = Int32(after), n > 0 { return n }
        }
        return -1
    }

    /// Simple CSV line parse: split by comma (does not handle quoted commas in process name).
    private func parseCSVLine(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Resolves PID to app display name and group key via NSRunningApplication; caches results.
final class AppNameResolver {
    private struct Resolved {
        let displayName: String
        /// Bundle ID when available; falls back to displayName. Used as the aggregation key
        /// so two different apps that both expose a process called "Helper" stay separate.
        let groupKey: String
    }

    private var cache: [Int32: Resolved] = [:]
    private let lock = NSLock()

    func resolve(forPID pid: Int32, fallbackProcessName: String) -> (displayName: String, groupKey: String) {
        let r = _resolve(forPID: pid, fallbackProcessName: fallbackProcessName)
        return (r.displayName, r.groupKey)
    }

    /// Convenience wrapper kept for any remaining call sites.
    func appName(forPID pid: Int32, fallbackProcessName: String) -> String {
        _resolve(forPID: pid, fallbackProcessName: fallbackProcessName).displayName
    }

    private func _resolve(forPID pid: Int32, fallbackProcessName: String) -> Resolved {
        guard pid > 0 else {
            let name = friendlyName(stripPID(from: fallbackProcessName))
            return Resolved(displayName: name, groupKey: name)
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pid] { return cached }
        let raw: String
        let bundleID: String?
        if let app = NSRunningApplication(processIdentifier: pid) {
            raw = app.localizedName ?? app.executableURL?.lastPathComponent ?? stripPID(from: fallbackProcessName)
            bundleID = app.bundleIdentifier
        } else {
            // nettop truncates process names to 16 chars; use proc_pidpath for the full executable name.
            raw = executableName(forPID: pid) ?? stripPID(from: fallbackProcessName)
            bundleID = nil
        }
        let displayName = friendlyName(raw)
        // Use displayName as the group key so that a main app (which has a bundle ID) and
        // its helper processes (which don't) both resolve to the same key via friendlyName.
        // e.g. "ChatGPT" (bundle: com.openai.chat) and "ChatGPTHelper" (no bundle) both → "ChatGPT".
        let groupKey = displayName
        let resolved = Resolved(displayName: displayName, groupKey: groupKey)
        cache[pid] = resolved
        return resolved
    }

    /// Returns the last path component of the executable for a given PID via proc_pidpath.
    private func executableName(forPID pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let ret = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard ret > 0 else { return nil }
        let path = String(cString: buf)
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Maps raw resolved names and daemon executable names to clean, user-facing labels.
    private func friendlyName(_ raw: String) -> String {
        let lower = raw.lowercased()

        // iCloud sync daemons — group them all under one label
        if lower == "bird" || lower == "cloudd" || lower == "nsurlsessiond"
            || lower == "com.apple.bird" || lower.hasPrefix("bird.") {
            return "iCloud Sync"
        }

        // Strip Electron/Chromium/plugin helper suffixes so e.g.:
        //   "Cursor Helper (Renderer)", "Cursor Helper (Plugin): extension-host",
        //   "Google Chrome Helper", "ChatGPTHelper"
        // all collapse to just the app name.
        if let helperRange = raw.range(of: "\\s*Helper.*", options: [.regularExpression, .caseInsensitive]) {
            let base = String(raw[..<helperRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { return base }
        }

        return raw
    }

    private func stripPID(from processName: String) -> String {
        if let dot = processName.lastIndex(of: "."), processName[processName.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            return String(processName[..<dot]).trimmingCharacters(in: .whitespaces)
        }
        if let open = processName.lastIndex(of: "(") {
            let after = processName[processName.index(after: open)...].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            if after.allSatisfy({ $0.isNumber }) {
                return String(processName[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return processName
    }
}
