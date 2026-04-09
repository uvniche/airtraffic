import Foundation

extension Airtraffic {
    static func runInteractiveShell(interval: TimeInterval) async {
        startBackgroundAppIfNeeded()
        var showHomeView = true

        while true {
            if showHomeView {
                renderInteractiveHome()
                showHomeView = false
            }
            FileHandle.standardOutput.write(Data("airtraffic> ".utf8))
            guard let line = readLine() else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "exit" || trimmed == "quit" { break }

            clearTerminal()

            let tokens = shellStyleSplit(trimmed)
            guard let command = tokens.first else { continue }
            let tail = Array(tokens.dropFirst())

            if command == "help" {
                HelpCommand(args: tail).run()
                continue
            }

            if command == "daemon" {
                if tail.last != "--daemonized" {
                    launchctlBootout()
                    killExistingDaemons()
                    let exe = CommandLine.arguments[0]
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: exe)
                    child.arguments = ["daemon", "--daemonized"]
                    child.standardInput = FileHandle.nullDevice
                    child.standardOutput = FileHandle.nullDevice
                    child.standardError = FileHandle.nullDevice
                    try? child.run()
                    print("App started. Running in the background.")
                    continue
                }
                await runCollector(interval: interval)
                continue
            }

            if command == "status" {
                StatusCommand().run()
                continue
            }
            if command == "today" {
                await TodayCommand().run()
                showHomeView = true
                continue
            }
            if command == "month" {
                await MonthCommand().run()
                showHomeView = true
                continue
            }
            if command == "since" {
                await SinceCommand(args: tail).run()
                showHomeView = true
                continue
            }
            if command == "export" {
                ExportCommand(args: tail).run()
                continue
            }
            if command == "limit" {
                LimitCommand(args: tail).run()
                continue
            }
            if command == "limits" {
                LimitsCommand().run()
                continue
            }
            if command == "uninstall" {
                UninstallCommand().run()
                continue
            }
            if command == "live" || command == "once" {
                let runOnce = command == "once" || tail.contains("--once")
                await runLiveCommand(interval: interval, once: runOnce)
                showHomeView = true
                continue
            }

            print("Unknown command: \(command)")
            print("Type 'help' to see available commands.")
        }
    }

    static func clearTerminal() {
        FileHandle.standardOutput.write(Data("\u{001B}[2J\u{001B}[H".utf8))
    }

    static func renderInteractiveHome() {
        clearTerminal()
        print("AirTraffic")
        print("macOS CLI Network App")
        print("")
        print("Type 'help' for commands, Ctrl+C to quit.")
    }

    static func shellStyleSplit(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil

        for ch in input {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }

            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(ch)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    static func startBackgroundAppIfNeeded() {
        if isCollectorProbablyRunning() { return }

        // Start the collector only if it isn't already running. Avoid booting out / killing
        // existing jobs here so repeated `swift run airtraffic` is safe/idempotent.
        let exe = CommandLine.arguments[0]
        let child = Process()
        child.executableURL = URL(fileURLWithPath: exe)
        child.arguments = ["daemon", "--daemonized"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
    }
}
