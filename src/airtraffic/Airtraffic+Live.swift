import Foundation
import Darwin

extension Airtraffic {
    static func exitLiveView(savedTermios: termios, tty: FileHandle) {
        var restored = savedTermios
        tcsetattr(rawModeInputFD, TCSAFLUSH, &restored)
        signal(SIGINT, SIG_DFL)
        ttyWrite(tty, "\u{1B}[?1049l")
    }

    static func runLiveCommand(interval: TimeInterval, once: Bool) async {
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

        ttyWrite(tty, "\u{1B}[?1049h" + terminalResetPrefix())
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

        let liveClockFormatter = DateFormatter()
        liveClockFormatter.locale = Locale(identifier: "en_US_POSIX")
        liveClockFormatter.dateFormat = "dd:MM:yyyy HH:mm:ss"

        while true {
            if let key = readNavigationKeyNonBlocking() {
                if key == .nextPage {
                    currentPage += 1
                } else if key == .previousPage {
                    currentPage = max(0, currentPage - 1)
                } else if key == .goBack {
                    exitLiveView(savedTermios: savedTermios, tty: tty)
                    return
                }
            }

            do {
                let rows = try nettop.sample()
                guard !rows.isEmpty else {
                    let stamp = liveClockFormatter.string(from: Date())
                    let waiting = terminalResetPrefix()
                        + "AirTraffic - Live (\(stamp))\n\n"
                        + "No network data available from nettop.\n\nEsc - Back"
                    ttyWrite(tty, waiting)
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

                let stamp = liveClockFormatter.string(from: Date())
                var out = terminalResetPrefix()
                out += "AirTraffic - Live (\(stamp))\n\n"
                out += fit("No.", width: 4) + " "
                out += fit("App", width: colName - 5) + " "
                out += fit("↓ Down/s", width: colDown) + " "
                out += fit("↑ Up/s", width: colUp) + " "
                out += fit("Total/s", width: colTotal) + "\n"
                out += String(repeating: "─", count: 4 + 1 + (colName - 5) + 1 + colDown + 1 + colUp + 1 + colTotal) + "\n"
                for (idx, row) in display.enumerated() {
                    let no = start + idx + 1
                    let inRate = Double(row.bytesIn) / interval
                    let outRate = Double(row.bytesOut) / interval
                    let totalRate = inRate + outRate
                    out += fit("\(no)", width: 4) + " "
                    out += fit(row.name, width: colName - 5) + " "
                    out += fit(formatRate(inRate), width: colDown) + " "
                    out += fit(formatRate(outRate), width: colUp) + " "
                    out += fit(formatRate(totalRate), width: colTotal) + "\n"
                }
                let totalInRate = display.reduce(0.0) { $0 + (Double($1.bytesIn) / interval) }
                let totalOutRate = display.reduce(0.0) { $0 + (Double($1.bytesOut) / interval) }
                let totalRate = totalInRate + totalOutRate
                out += String(repeating: "─", count: 4 + 1 + (colName - 5) + 1 + colDown + 1 + colUp + 1 + colTotal) + "\n"
                out += fit("", width: 4) + " "
                out += fit("TOTAL", width: colName - 5) + " "
                out += fit(formatRate(totalInRate), width: colDown) + " "
                out += fit(formatRate(totalOutRate), width: colUp) + " "
                out += fit(formatRate(totalRate), width: colTotal) + "\n"
                out += "\n"
                out += "Page \(currentPage + 1)/\(totalPages)\n"
                out += "Controls: → - Next, ← - Previous, Esc - Back"
                ttyWrite(tty, out)
            } catch {
                ttyWrite(tty, "Error: \(error)\n")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
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
        let displayFormatter = DateFormatter()
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        displayFormatter.dateFormat = "dd:MM:yyyy HH:mm"
        var lastSnapshot: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var currentPage = 0

        ttyWrite(tty, "\u{1B}[?1049h" + terminalResetPrefix())
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
                } else if key == .goBack {
                    exitLiveView(savedTermios: savedTermios, tty: tty)
                    return
                }
            }

            guard let state = AirtrafficState.load() else {
                ttyWrite(tty, terminalResetPrefix() + "Waiting for data…\n\nEsc - Back")
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                continue
            }

            let now = Date()
            guard Calendar.current.isDate(now, inSameDayAs: state.todayStart), !state.todayByApp.isEmpty else {
                ttyWrite(tty, terminalResetPrefix() + "No data recorded for today yet.\n\nEsc - Back")
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                continue
            }

            if let rows = try? nettop.sample(), !rows.isEmpty {
                let byApp = aggregateByApp(rows, resolver: resolver)
                for row in byApp {
                    let _ = lastSnapshot[row.name] ?? (0, 0)
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

            let sinceDate = state.collectorStart
            var out = terminalResetPrefix()
            out += "AirTraffic - Today (since \(displayFormatter.string(from: sinceDate)))\n\n"
            out += fit("No.", width: 5) + " "
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
            out += "Controls: → - Next, ← - Previous, Esc - Back"
            ttyWrite(tty, out)

            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    enum NavigationKey {
        case nextPage
        case previousPage
        case goBack
    }

    static func readNavigationKeyNonBlocking() -> NavigationKey? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&pfd, 1, 0)
        guard ready > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var byte: UInt8 = 0
        let bytesRead = Darwin.read(STDIN_FILENO, &byte, 1)
        guard bytesRead == 1 else { return nil }

        if byte == 0x1B {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let hasSecond = Darwin.poll(&pfd, 1, 20)
            guard hasSecond > 0, (pfd.revents & Int16(POLLIN)) != 0 else {
                return .goBack
            }

            var second: UInt8 = 0
            let secondRead = Darwin.read(STDIN_FILENO, &second, 1)
            guard secondRead == 1 else { return .goBack }
            guard second == 0x5B else { return .goBack }

            let hasThird = Darwin.poll(&pfd, 1, 20)
            guard hasThird > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }
            var third: UInt8 = 0
            let thirdRead = Darwin.read(STDIN_FILENO, &third, 1)
            guard thirdRead == 1 else { return nil }
            if third == 0x44 { return .previousPage }
            if third == 0x43 { return .nextPage }
            return nil
        }
        return nil
    }

    static func terminalResetPrefix() -> String {
        "\u{1B}[?6l\u{1B}[r\u{1B}[2J\u{1B}[1;1H"
    }

    static func cumulativeHeaderLines() -> [String] {
        let no = fit("No.", width: 4)
        let app = fit("App", width: colName - 5)
        let down = fit("↓ Down", width: colDown)
        let up = fit("↑ Up", width: colUp)
        let tot = fit("Total", width: colTotal)
        return [
            "\(no) \(app) \(down) \(up) \(tot)",
            String(repeating: "─", count: 4 + 1 + (colName - 5) + 1 + colDown + 1 + colUp + 1 + colTotal),
        ]
    }

    static func cumulativeRowLine(no: Int, name: String, bytesIn: UInt64, bytesOut: UInt64) -> String {
        let noCol = fit("\(no)", width: 4)
        let nameCol = fit(name, width: colName - 5)
        let downStr = formatBytes(bytesIn)
        let upStr = formatBytes(bytesOut)
        let totStr = formatBytes(bytesIn + bytesOut)
        return "\(noCol) \(nameCol) \(fit(downStr, width: colDown)) \(fit(upStr, width: colUp)) \(fit(totStr, width: colTotal))"
    }

    static func runLiveCumulative(
        dataProvider: () -> (title: String, apps: [(name: String, bytesIn: UInt64, bytesOut: UInt64)])?
    ) async {
        let interval: TimeInterval = 0.2
        let pageSize = 10
        let tty = openTTY()
        var currentPage = 0

        ttyWrite(tty, "\u{1B}[?1049h" + terminalResetPrefix())
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
                } else if key == .goBack {
                    exitLiveView(savedTermios: savedTermios, tty: tty)
                    return
                }
            }

            if let (title, apps) = dataProvider() {
                let totalPages = max(1, Int(ceil(Double(apps.count) / Double(pageSize))))
                currentPage = min(currentPage, totalPages - 1)
                let start = currentPage * pageSize
                let end = min(start + pageSize, apps.count)
                let display = start < end ? Array(apps[start..<end]) : []
                var out = terminalResetPrefix()
                out += title + "\n\n"
                for line in cumulativeHeaderLines() { out += line + "\n" }
                for (idx, row) in display.enumerated() {
                    let no = start + idx + 1
                    out += cumulativeRowLine(no: no, name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut) + "\n"
                }
                let totalIn = apps.reduce(UInt64(0)) { $0 + $1.bytesIn }
                let totalOut = apps.reduce(UInt64(0)) { $0 + $1.bytesOut }
                out += String(repeating: "─", count: 4 + 1 + (colName - 5) + 1 + colDown + 1 + colUp + 1 + colTotal) + "\n"
                out += fit("", width: 4) + " "
                out += fit("TOTAL", width: colName - 5) + " "
                out += fit(formatBytes(totalIn), width: colDown) + " "
                out += fit(formatBytes(totalOut), width: colUp) + " "
                out += fit(formatBytes(totalIn + totalOut), width: colTotal) + "\n"
                out += "\n"
                out += "Page \(currentPage + 1)/\(totalPages)\n"
                out += "Controls: → - Next, ← - Previous, Esc - Back"
                ttyWrite(tty, out)
            } else {
                ttyWrite(tty, terminalResetPrefix() + "Waiting for data…\n\nEsc - Back")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

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
