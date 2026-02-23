import Foundation
import Darwin

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 2.0
        var lastSnapshot: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        let nettop = NettopParser()

        print("AirTraffic – live per-app network usage (Ctrl+C to quit)")
        print("Refreshing every \(Int(interval))s…\n")

        while true {
            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    sleep(UInt32(interval))
                    continue
                }

                // Compute deltas if we have a previous snapshot
                var deltas: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = rows.map { row in
                    let (prevIn, prevOut) = lastSnapshot[row.name] ?? (0, 0)
                    let dIn = row.bytesIn >= prevIn ? row.bytesIn - prevIn : row.bytesIn
                    let dOut = row.bytesOut >= prevOut ? row.bytesOut - prevOut : row.bytesOut
                    return (row.name, dIn, dOut)
                }

                lastSnapshot = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, ($0.bytesIn, $0.bytesOut)) })

                // Sort by total bytes (in + out) descending
                deltas.sort { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }

                // Trim to top N and filter zeros if we have enough non-zero
                let nonZero = deltas.filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
                let display = nonZero.isEmpty ? Array(deltas.prefix(20)) : Array(nonZero.prefix(20))

                if isatty(STDOUT_FILENO) != 0 {
                    clearScreen()
                }
                printHeader()
                for row in display {
                    printRow(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut, interval: interval)
                }
                print("\n(Next refresh in \(Int(interval))s. Ctrl+C to quit)")
            } catch {
                fputs("Error: \(error)\n", stderr)
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    static func clearScreen() {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
    }

    static func printHeader() {
        let app = "App / Process".padding(toLength: 36, withPad: " ", startingAt: 0)
        let down = "↓ Down"
        let up = "↑ Up"
        let total = "Total/s"
        print("\(app) \(down)      \(up)       \(total)")
        print(String(repeating: "─", count: 70))
    }

    static func printRow(name: String, bytesIn: UInt64, bytesOut: UInt64, interval: TimeInterval) {
        let inRate = Double(bytesIn) / interval
        let outRate = Double(bytesOut) / interval
        let totalRate = inRate + outRate
        let nameTruncated = name.count > 35 ? String(name.prefix(32)) + "…" : name
        let paddedName = nameTruncated.padding(toLength: 36, withPad: " ", startingAt: 0)
        let downStr = formatBytes(bytesIn) + " (" + formatRate(inRate) + ")"
        let upStr = formatBytes(bytesOut) + " (" + formatRate(outRate) + ")"
        let totalStr = formatRate(totalRate)
        print("\(paddedName) \(downStr.padding(toLength: 14, withPad: " ", startingAt: 0)) \(upStr.padding(toLength: 14, withPad: " ", startingAt: 0)) \(totalStr)")
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

struct NettopParser {
    private let bytesInIndex: Int
    private let bytesOutIndex: Int

    init() {
        self.bytesInIndex = 4
        self.bytesOutIndex = 5
    }

    /// Run nettop once and parse CSV into per-process rows (process name, bytes in, bytes out).
    func sample() throws -> [(name: String, bytesIn: UInt64, bytesOut: UInt64)] {
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

        var rows: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return [] }

        for line in lines.dropFirst(1) {
            let parsed = parseCSVLine(line)
            guard parsed.count > bytesOutIndex,
                  let bytesIn = UInt64(parsed[bytesInIndex].trimmingCharacters(in: .whitespaces)),
                  let bytesOut = UInt64(parsed[bytesOutIndex].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = parsed.count > 1 ? parsed[1].trimmingCharacters(in: .whitespaces) : "?"
            if name.isEmpty || name == "interface" { continue }
            rows.append((name: name, bytesIn: bytesIn, bytesOut: bytesOut))
        }

        return rows
    }

    /// Simple CSV line parse: split by comma (does not handle quoted commas in process name).
    private func parseCSVLine(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}
