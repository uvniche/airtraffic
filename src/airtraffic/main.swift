import Foundation
import Darwin
import AppKit

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 2.0
        let args = Array(CommandLine.arguments.dropFirst())
        let primary = args.first
        let once = args.contains("--once") || primary == "once"

        if primary == "daemon" {
            await runCollector(interval: interval)
            return
        }

        if primary == "status" {
            StatusCommand().run()
            return
        }

        if primary == "today" {
            TodayCommand().run()
            return
        }

        // live (explicit) or no subcommand → live 2s view
        var lastSnapshot: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        let nettop = NettopParser()
        let appResolver = AppNameResolver()

        print("AirTraffic – live per-app network usage (Ctrl+C to quit)")
        print("Refreshing every \(Int(interval))s…\n")

        let topN = 20
        let isTTY = isatty(STDOUT_FILENO) != 0
        var renderedLines: Int? = nil

        if once {
            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    print("No network data available from nettop.")
                    return
                }
                let byApp = aggregateByApp(rows, resolver: appResolver)
                let deltas = byApp.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
                let lines = renderLines(
                    display: Array(deltas.prefix(topN)),
                    topN: topN,
                    interval: interval,
                    includeFooter: false
                )
                if isTTY {
                    writeFrame(lines, moveUp: nil)
                } else {
                    for line in lines { print(line) }
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
            }
            return
        }

        while true {
            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    sleep(UInt32(interval))
                    continue
                }

                // Aggregate by app name (sum across all processes of the same app)
                let byApp = aggregateByApp(rows, resolver: appResolver)

                // Compute deltas if we have a previous snapshot
                var deltas: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = byApp.map { row in
                    let (prevIn, prevOut) = lastSnapshot[row.name] ?? (0, 0)
                    let dIn = row.bytesIn >= prevIn ? row.bytesIn - prevIn : row.bytesIn
                    let dOut = row.bytesOut >= prevOut ? row.bytesOut - prevOut : row.bytesOut
                    return (row.name, dIn, dOut)
                }

                lastSnapshot = Dictionary(uniqueKeysWithValues: byApp.map { ($0.name, ($0.bytesIn, $0.bytesOut)) })

                // Sort by total bytes (in + out) descending
                deltas.sort { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }

                // Trim to top N and filter zeros if we have enough non-zero
                let nonZero = deltas.filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
                let display = nonZero.isEmpty ? Array(deltas.prefix(topN)) : Array(nonZero.prefix(topN))

                let lines = renderLines(
                    display: display,
                    topN: topN,
                    interval: interval,
                    includeFooter: true
                )

                if isTTY {
                    writeFrame(lines, moveUp: renderedLines)
                    renderedLines = lines.count
                } else {
                    for line in lines { print(line) }
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Background collector: periodically samples nettop and persists per-app usage.
    static func runCollector(interval: TimeInterval) async {
        LoginItemInstaller.ensureInstalledIfNeeded()

        let nettop = NettopParser()
        let resolver = AppNameResolver()
        var state = AirtrafficState.load() ?? AirtrafficState.empty(now: Date())

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
    static func aggregateByApp(
        _ rows: [(name: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64)],
        resolver: AppNameResolver
    ) -> [(name: String, bytesIn: UInt64, bytesOut: UInt64)] {
        var sum: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for row in rows {
            let appName = resolver.appName(forPID: row.pid, fallbackProcessName: row.name)
            let existing = sum[appName] ?? (0, 0)
            sum[appName] = (existing.0 + row.bytesIn, existing.1 + row.bytesOut)
        }
        return sum.map { (name: $0.key, bytesIn: $0.value.0, bytesOut: $0.value.1) }
    }

    static func headerLines() -> [String] {
        let app = fit("App", width: colName)
        let down = fit("↓ Down", width: colDown)
        let up = fit("↑ Up", width: colUp)
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
        let downStr = "\(formatBytes(bytesIn)) \(formatRate(inRate))"
        let upStr = "\(formatBytes(bytesOut)) \(formatRate(outRate))"
        let totalStr = formatRate(totalRate)

        return "\(nameCol) \(fit(downStr, width: colDown)) \(fit(upStr, width: colUp)) \(fit(totalStr, width: colTotal))"
    }

    private static let colName = 36
    private static let colDown = 20
    private static let colUp = 20
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
        var lines: [String] = []
        lines.append(contentsOf: headerLines())

        for i in 0..<topN {
            if i < display.count {
                let row = display[i]
                lines.append(rowLine(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut, interval: interval))
            } else {
                lines.append("")
            }
        }

        if includeFooter {
            lines.append("")
            lines.append("(Next refresh in \(Int(interval))s. Ctrl+C to quit)")
        }
        return lines
    }

    static func writeFrame(_ lines: [String], moveUp: Int?) {
        // Overwrite the previously-rendered table in place (no scrolling).
        if let moveUp, moveUp > 0 {
            print("\u{1B}[\(moveUp)A", terminator: "")
        }
        for line in lines {
            // Clear line and write new content.
            print("\u{1B}[2K\r\(line)")
        }
        fflush(stdout)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.2f MiB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.2f KiB", Double(bytes) / 1024)
        } else {
            return "\(bytes) B"
        }
    }

    static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_073_741_824 {
            return String(format: "%.2f GiB/s", bytesPerSec / 1_073_741_824)
        } else if bytesPerSec >= 1_048_576 {
            return String(format: "%.2f MiB/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.2f KiB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }
}

/// Persistent usage state for background collector.
struct AirtrafficState: Codable {
    var collectorStart: Date
    var lastUpdate: Date
    var todayStart: Date
    var todayByApp: [String: AppUsage]
    var lastSnapshot: [String: AppUsage]

    static func empty(now: Date) -> AirtrafficState {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        return AirtrafficState(
            collectorStart: now,
            lastUpdate: now,
            todayStart: midnight,
            todayByApp: [:],
            lastSnapshot: [:]
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
    private static let label = "com.uvniche.airtraffic.collector"

    static func ensureInstalledIfNeeded() {
        let fm = FileManager.default
        let launchAgentsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")

        // If plist already exists, assume it's installed.
        if fm.fileExists(atPath: plistURL.path) {
            return
        }

        do {
            try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

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
            print("Collector: not running (no state found).")
            return
        }
        let now = Date()
        let active = now.timeIntervalSince(state.lastUpdate) < 10

        print("Collector: \(active ? "running" : "not running")")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        print("Running since: \(formatter.string(from: state.collectorStart))")

        let apps = state.todayByApp.sorted { lhs, rhs in
            let l = lhs.value.bytesIn + lhs.value.bytesOut
            let r = rhs.value.bytesIn + rhs.value.bytesOut
            return l > r
        }
        if !apps.isEmpty {
            print("\nToday so far (top 10 apps by bytes):")
            for (name, usage) in apps.prefix(10) {
                let total = usage.bytesIn + usage.bytesOut
                print("- \(name): \(Airtraffic.formatBytes(total)) (↓ \(Airtraffic.formatBytes(usage.bytesIn)), ↑ \(Airtraffic.formatBytes(usage.bytesOut)))")
            }
        }
    }
}

/// `airtraffic today`
struct TodayCommand {
    func run() {
        guard let state = AirtrafficState.load() else {
            print("No usage data recorded yet.")
            return
        }
        let now = Date()
        if !Calendar.current.isDate(now, inSameDayAs: state.todayStart) {
            print("No data for today yet.")
            return
        }

        let apps = state.todayByApp.sorted { lhs, rhs in
            let l = lhs.value.bytesIn + lhs.value.bytesOut
            let r = rhs.value.bytesIn + rhs.value.bytesOut
            return l > r
        }
        if apps.isEmpty {
            print("No data recorded for today yet.")
            return
        }

        print("Per-app usage since midnight:")
        for (name, usage) in apps {
            let total = usage.bytesIn + usage.bytesOut
            print("- \(name): \(Airtraffic.formatBytes(total)) (↓ \(Airtraffic.formatBytes(usage.bytesIn)), ↑ \(Airtraffic.formatBytes(usage.bytesOut)))")
        }
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

/// Resolves PID to app display name via NSRunningApplication; caches results.
final class AppNameResolver {
    private var cache: [Int32: String] = [:]
    private let lock = NSLock()

    func appName(forPID pid: Int32, fallbackProcessName: String) -> String {
        guard pid > 0 else { return stripPID(from: fallbackProcessName) }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pid] { return cached }
        let name: String
        if let app = NSRunningApplication(processIdentifier: pid) {
            name = app.localizedName ?? app.executableURL?.lastPathComponent ?? stripPID(from: fallbackProcessName)
        } else {
            name = stripPID(from: fallbackProcessName)
        }
        cache[pid] = name
        return name
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
