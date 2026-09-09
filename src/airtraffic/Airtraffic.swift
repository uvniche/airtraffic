import Foundation

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 1.0
        let args = Array(CommandLine.arguments.dropFirst())

        // Internal-only collector path used by the LaunchAgent.
        if args.first == "daemon" {
            await runCollector(interval: interval)
            return
        }

        guard let command = args.first else {
            HelpCommand().run()
            return
        }

        let tail = Array(args.dropFirst())
        let collectorCommands: Set<String> = [
            "today", "month", "since", "export", "limit", "limits", "live", "once",
        ]
        if collectorCommands.contains(command) {
            startCollectorIfNeeded()
        }

        switch command {
        case "help":
            if tail.isEmpty {
                HelpCommand().run()
            } else {
                print("Usage: airtraffic help")
            }
        case "status":
            StatusCommand().run()
        case "quit", "stop":
            StopCommand().run()
        case "today":
            await TodayCommand().run()
        case "month":
            await MonthCommand().run()
        case "since":
            await SinceCommand(args: tail).run()
        case "export":
            ExportCommand(args: tail).run()
        case "limit":
            LimitCommand(args: tail).run()
        case "limits":
            LimitsCommand().run()
        case "live", "once":
            await runLiveCommand(
                interval: interval,
                once: command == "once" || tail.contains("--once")
            )
        case "uninstall":
            UninstallCommand().run()
        default:
            print("Unknown command: \(command)")
            print("Run 'airtraffic help' to see available commands.")
        }
    }
}
