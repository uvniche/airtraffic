import Foundation

@main
struct Airtraffic {
    static func main() async {
        let interval: TimeInterval = 1.0
        let args = Array(CommandLine.arguments.dropFirst())

        if shouldOpenTerminalForBundledLaunch(args: args) {
            openTerminalForBundledLaunch()
            return
        }

        // Default behavior: ensure the real AirTraffic app bundle exists in Applications.
        // Skip for the daemonized collector child to avoid extra work during background runs.
        if !args.contains("--daemonized") {
            ensureBundledAppInstalledIfNeeded()
        }

        // Internal-only daemon collector path used by the background child process.
        if args.first == "daemon", args.last == "--daemonized" {
            await runCollector(interval: interval)
            return
        }

        // Only supported one-shot: uninstall (e.g. `swift run airtraffic uninstall`).
        if args == ["uninstall"] {
            UninstallCommand().run()
            return
        }

        await runInteractiveShell(interval: interval)
    }
}
