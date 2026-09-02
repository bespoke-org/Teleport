import Foundation

private func requireFile(_ path: String) {
    precondition(FileManager.default.fileExists(atPath: path), "expected file at \(path)")
}

private func requireMissing(_ path: String) {
    precondition(!FileManager.default.fileExists(atPath: path), "obsolete architecture file remains at \(path)")
}

do {
        requireFile("teleport/Connection/ConnectionProvider.swift")
        requireFile("teleport/Connection/ConnectionRequest.swift")
        requireFile("teleport/Connection/ConnectionState.swift")
        requireFile("teleport/Connection/ConnectionStateStore.swift")
        requireFile("teleport/Connection/BackendConnectionProvider.swift")
        requireFile("teleport/Connection/ConnectionProviderFactory.swift")
        requireFile("teleport/SystemProxy/SystemProxyConnectionProvider.swift")
        requireFile("teleport/VPN/RootXrayConnectionProvider.swift")
        requireMissing("teleport/Connection/ConnectionBackendFactory.swift")

        requireFile("teleport/XrayCore/XrayConfigurationWriter.swift")
        requireFile("teleport/Geodata/GeodataUpdateService.swift")
        requireMissing("teleport/Xray/XrayConfigurationWriter.swift")
        requireMissing("teleport/Xray/GeodataUpdateService.swift")

        requireFile("teleport/SystemProxy/SystemProxyConnectionBackend.swift")
        requireFile("teleport/SystemProxy/SystemProxyService.swift")
        requireFile("teleport/SystemProxy/XrayRuntimeManager.swift")
        requireMissing("teleport/Proxy/SystemProxyService.swift")
        requireMissing("teleport/Xray/XrayRuntimeManager.swift")

        requireFile("teleport/VPN/XrayTunConnectionBackend.swift")
        requireFile("teleport/VPN/PrivilegedHelperClient.swift")
        requireFile("teleport/VPN/PrivilegedXrayRuntimeManager.swift")
        requireFile("teleport/VPN/XrayTunRouteInspector.swift")
        requireFile("teleport/VPN/XrayTunSessionState.swift")
        requireMissing("teleport/Xray/PrivilegedHelperClient.swift")
        requireMissing("teleport/Xray/PrivilegedXrayRuntimeManager.swift")
        requireMissing("teleport/Xray/XrayTunRouteInspector.swift")
        requireMissing("teleport/Xray/XrayTunSessionState.swift")

        requireFile("teleport/HelperInstallation/BundledArtifactPolicy.swift")
        requireFile("teleport/HelperInstallation/BundledArtifactVerifier.swift")
        requireFile("teleport/HelperInstallation/PrivilegedHelperInstaller.swift")
        requireFile("teleport/HelperInstallation/PrivilegedShellRunner.swift")
        requireMissing("teleport/Xray/PrivilegedHelperInstaller.swift")
        requireMissing("teleport/Xray/PrivilegedShellRunner.swift")

        requireFile("TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift")
        requireFile("TeleportPrivilegedHelper/IPC/HelperMessages.swift")
        requireFile("TeleportPrivilegedHelper/IPC/HelperServer.swift")
        requireFile("TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift")
        requireFile("TeleportPrivilegedHelper/Session/XrayTunController.swift")
        requireFile("TeleportPrivilegedHelper/Support/HelperConfiguration.swift")
        requireFile("TeleportPrivilegedHelper/Support/HelperPlatform.swift")
        requireFile("TeleportPrivilegedHelper/Support/HelperShellRunner.swift")
        requireFile("TeleportPrivilegedHelper/Xray/ManagedXrayProcess.swift")

        let mainPath = "TeleportPrivilegedHelper/main.swift"
        let mainSource = try String(contentsOfFile: mainPath, encoding: .utf8)
        precondition(mainSource.contains("HelperServer().run()"), "expected helper entry point in \(mainPath)")
        precondition(!mainSource.contains("final class HelperServer"), "expected HelperServer to be extracted from \(mainPath)")
        precondition(!mainSource.contains("final class XrayTunController"), "expected XrayTunController to be extracted from \(mainPath)")
        precondition(!mainSource.contains("makeStartScript"), "expected route scripts to be extracted from \(mainPath)")
        precondition(mainSource.split(separator: "\n").count < 20, "expected \(mainPath) to remain entry-only")

    print("verify_architecture_layout: all checks passed")
} catch {
    fputs("verify_architecture_layout: \(error)\n", stderr)
    exit(1)
}
