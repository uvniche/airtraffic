import Foundation

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 1.0
        let args = Array(CommandLine.arguments.dropFirst())

        // Internal-only daemon collector path used by the background child process.
        if args.first == "daemon", args.last == "--daemonized" {
            await runCollector(interval: interval)
            return
        }

        if args == ["stop"] {
            StopCommand().run()
            return
        }

        if args == ["uninstall"] {
            UninstallCommand().run()
            return
        }

        await runInteractiveShell(interval: interval)
    }
}
