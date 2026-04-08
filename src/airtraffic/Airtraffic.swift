import Foundation

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 1.0
        let args = Array(CommandLine.arguments.dropFirst())
        let primary = args.first
        let once = args.contains("--once") || primary == "once"

        // No command -> interactive shell mode.
        if primary == nil {
            await runInteractiveShell(interval: interval)
            return
        }

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
                print("App started. Running in the background.")
                return
            }
            await runCollector(interval: interval)
            return
        }

        if primary == "status" {
            StatusCommand().run()
            return
        }

        if primary == "help" || primary == "--help" || primary == "-h" {
            HelpCommand(args: Array(args.dropFirst())).run()
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

        await runLiveCommand(interval: interval, once: once)
    }
}
