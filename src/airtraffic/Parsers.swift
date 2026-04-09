import Foundation
import AppKit

struct NettopParser {
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
        let header = parseCSVLine(lines[0])
        let indexes = inferColumnIndexes(from: header)

        for line in lines.dropFirst(1) {
            let parsed = parseCSVLine(line)
            guard parsed.count > indexes.bytesOutIndex,
                  let bytesIn = UInt64(parsed[indexes.bytesInIndex].trimmingCharacters(in: .whitespaces)),
                  let bytesOut = UInt64(parsed[indexes.bytesOutIndex].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = parsed.count > indexes.nameIndex ? parsed[indexes.nameIndex].trimmingCharacters(in: .whitespaces) : "?"
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

    private func inferColumnIndexes(from header: [String]) -> (nameIndex: Int, bytesInIndex: Int, bytesOutIndex: Int) {
        // Historical nettop output has process name at index 1, bytes in/out at 4/5.
        // Keep those defaults for backward compatibility if matching fails.
        var nameIndex = 1
        var bytesInIndex = 4
        var bytesOutIndex = 5

        for (idx, raw) in header.enumerated() {
            let key = normalizeHeaderKey(raw)

            if key == "processname" || key == "process" || key == "name" {
                nameIndex = idx
            }

            if bytesInIndex == 4, key.contains("bytesin") || key.contains("rxbytes") || key == "bytesreceived" {
                bytesInIndex = idx
            }

            if bytesOutIndex == 5, key.contains("bytesout") || key.contains("txbytes") || key == "bytessent" {
                bytesOutIndex = idx
            }
        }

        return (nameIndex, bytesInIndex, bytesOutIndex)
    }

    private func normalizeHeaderKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// CSV parser that supports quoted fields and escaped quotes ("").
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
                i = next
                continue
            }

            if ch == ",", !inQuotes {
                fields.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }

        fields.append(current)
        return fields
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

    private func _resolve(forPID pid: Int32, fallbackProcessName: String) -> Resolved {
        guard pid > 0 else {
            let name = friendlyName(stripPID(from: fallbackProcessName))
            return Resolved(displayName: name, groupKey: name)
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pid] { return cached }
        let raw: String
        if let app = NSRunningApplication(processIdentifier: pid) {
            raw = app.localizedName ?? app.executableURL?.lastPathComponent ?? stripPID(from: fallbackProcessName)
        } else {
            // nettop truncates process names to 16 chars; use proc_pidpath for the full executable name.
            raw = executableName(forPID: pid) ?? stripPID(from: fallbackProcessName)
        }
        let displayName = friendlyName(raw)
        // Use displayName as the group key so that a main app (which has a bundle ID) and
        // its helper processes (which don't) both resolve to the same key via friendlyName.
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
