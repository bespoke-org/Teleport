import Foundation

// The scripts that need the app sources are compiled into one binary, so the sources are
// compiled once. Arguments name the scripts to run (e.g. `core`); without them all run.
// All scripts run in one process, so they must not change process-global state (UserDefaults,
// environment, current directory, exit), and their top-level non-private names must be unique.
@main
struct TestApp {
    static func main() async throws {
        let scripts: [(name: String, run: () async throws -> Void)] = [
            ("core", { try TestCore.main() }),
            ("subscription-support", { try TestSubscriptionSupport.main() }),
            ("connection-health", { try TestConnectionHealth.main() }),
            ("connection-provider", { try await TestConnectionProvider.main() }),
            ("split-tunneling", { try TestSplitTunneling.main() }),
            ("geodata", { try TestGeodata.main() }),
            ("persistence", { try TestPersistence.main() }),
            ("uplink-reconciliation", { try TestUplinkReconciliation.main() }),
            ("privileged-helper-client", { try await TestPrivilegedHelperClient.main() }),
            ("mach-service-installation", { try TestMachServiceInstallation.main() }),
        ]
        let names = Array(CommandLine.arguments.dropFirst())
        for name in names where !scripts.contains(where: { $0.name == name }) {
            fputs("Unknown script \(name); known: \(scripts.map(\.name).joined(separator: " "))\n", stderr)
            exit(2)
        }
        for script in scripts where names.isEmpty || names.contains(script.name) {
            try await script.run()
        }
    }
}
