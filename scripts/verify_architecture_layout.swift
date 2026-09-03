import Foundation

private func requireFile(_ path: String) {
    precondition(FileManager.default.fileExists(atPath: path), "expected file at \(path)")
}

private func requireMissing(_ path: String) {
    precondition(!FileManager.default.fileExists(atPath: path), "obsolete architecture file remains at \(path)")
}

private func readSource(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

private func recursivelyEnumeratedSwiftFiles(in root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    return enumerator.compactMap { entry in
        guard let relativePath = entry as? String, relativePath.hasSuffix(".swift") else { return nil }
        return root + "/" + relativePath
    }
}

private func requireNoForbiddenDetails(_ details: [String], in path: String) throws {
    let source = try readSource(path)
    for detail in details {
        precondition(!source.contains(detail), "\(path) contains forbidden architecture detail \(detail)")
    }
}

do {
    let requiredFiles = [
        "teleport/Connection/ConnectionProvider.swift",
        "teleport/Connection/ConnectionRequest.swift",
        "teleport/Connection/ConnectionState.swift",
        "teleport/Connection/ConnectionStateStore.swift",
        "teleport/Connection/ConnectionPresentation.swift",
        "teleport/Connection/ConnectionBackend.swift",
        "teleport/Connection/BackendConnectionProvider.swift",
        "teleport/Connection/ConnectionProviderFactory.swift",
        "teleport/SystemProxy/SystemProxyConnectionProvider.swift",
        "teleport/VPN/RootXrayConnectionProvider.swift",
        "teleport/XrayCore/XrayConfigurationWriter.swift",
        "teleport/Geodata/GeodataUpdateService.swift",
        "teleport/SystemProxy/SystemProxyConnectionBackend.swift",
        "teleport/SystemProxy/SystemProxyService.swift",
        "teleport/SystemProxy/XrayRuntimeManager.swift",
        "teleport/VPN/XrayTunConnectionBackend.swift",
        "teleport/VPN/PrivilegedHelperClient.swift",
        "teleport/VPN/PrivilegedXrayRuntimeManager.swift",
        "teleport/VPN/VPNHelperTransport.swift",
        "teleport/VPN/XPCVPNHelperTransport.swift",
        "teleport/VPN/XrayTunRouteInspector.swift",
        "teleport/VPN/XrayTunSessionState.swift",
        "teleport/HelperInstallation/BundledArtifactPolicy.swift",
        "teleport/HelperInstallation/BundledArtifactVerifier.swift",
        "teleport/HelperInstallation/PrivilegedHelperInstaller.swift",
        "teleport/HelperInstallation/PrivilegedShellRunner.swift",
        "Shared/VPNHelperXPCProtocol.swift",
        "Shared/VPNHelperMessages.swift",
        "Shared/VPNHelperProtocolError.swift",
        "TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift",
        "TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift",
        "TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift",
        "TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift",
        "TeleportPrivilegedHelper/IPC/HelperXPCListenerDelegate.swift",
        "TeleportPrivilegedHelper/IPC/HelperXPCService.swift",
        "TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift",
        "TeleportPrivilegedHelper/Session/XrayTunController.swift",
        "TeleportPrivilegedHelper/Support/HelperConfiguration.swift",
        "TeleportPrivilegedHelper/Support/HelperError.swift",
        "TeleportPrivilegedHelper/Support/HelperPlatform.swift",
        "TeleportPrivilegedHelper/Support/HelperShellRunner.swift",
        "TeleportPrivilegedHelper/Xray/ManagedXrayProcess.swift"
    ]
    for path in requiredFiles {
        requireFile(path)
    }

    let obsoleteFiles = [
        "teleport/Connection/ConnectionBackendFactory.swift",
        "teleport/Xray/XrayConfigurationWriter.swift",
        "teleport/Xray/GeodataUpdateService.swift",
        "teleport/Proxy/SystemProxyService.swift",
        "teleport/Xray/XrayRuntimeManager.swift",
        "teleport/Xray/PrivilegedHelperClient.swift",
        "teleport/Xray/PrivilegedXrayRuntimeManager.swift",
        "teleport/Xray/XrayTunRouteInspector.swift",
        "teleport/Xray/XrayTunSessionState.swift",
        "teleport/Xray/PrivilegedHelperInstaller.swift",
        "teleport/Xray/PrivilegedShellRunner.swift",
        "TeleportPrivilegedHelper/IPC/HelperMessages.swift",
        "TeleportPrivilegedHelper/IPC/HelperServer.swift"
    ]
    for path in obsoleteFiles {
        requireMissing(path)
    }

    let upperLayerForbiddenDetails = [
        "ConnectionBackend",
        "PrivilegedHelperClient",
        "PrivilegedXrayRuntimeManager",
        "XrayTunRouteInspector",
        "XrayConfigurationWriter",
        "NSXPCConnection",
        "dev.x.teleport.helper",
        "VPNHelperProtocol.revision",
        "requestID",
        "sessionID",
        "xray-tun-session.json",
        "PrivilegedHelperConstants.version",
        "utun"
    ]
    try requireNoForbiddenDetails(upperLayerForbiddenDetails, in: "teleport/ViewModels/AppViewModel.swift")
    try requireNoForbiddenDetails(
        ["NSXPCConnection", "dev.x.teleport.helper", "VPNHelperProtocol.revision", "requestID", "sessionID"],
        in: "teleport/Connection/ConnectionProvider.swift"
    )

    let productionRoots = ["Shared", "TeleportPrivilegedHelper", "teleport"]
    let forbiddenSocketDetails = [
        "AF_UNIX",
        "sockaddr_un",
        "LOCAL_PEERPID",
        "getpeereid",
        "socketPath",
        "/var/run/dev.x.teleport.helper.sock",
        "HelperServer",
        "PrivilegedHelperRequest",
        "PrivilegedHelperResponse"
    ]
    for root in productionRoots {
        for path in recursivelyEnumeratedSwiftFiles(in: root) {
            try requireNoForbiddenDetails(forbiddenSocketDetails, in: path)
        }
    }

    let mainPath = "TeleportPrivilegedHelper/main.swift"
    let mainSource = try readSource(mainPath)
    precondition(mainSource.contains("NSXPCListener(machServiceName: VPNHelperProtocol.machServiceName)"), "expected XPC Mach-service listener in \(mainPath)")
    precondition(mainSource.contains("listener.resume()"), "expected XPC listener activation in \(mainPath)")
    precondition(!mainSource.contains("SIGPIPE"), "obsolete socket signal handling remains in \(mainPath)")
    precondition(mainSource.split(separator: "\n").count < 20, "expected \(mainPath) to remain entry-only")

    print("verify_architecture_layout: all checks passed")
} catch {
    fputs("verify_architecture_layout: \(error)\n", stderr)
    exit(1)
}
