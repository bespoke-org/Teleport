import Darwin
import Foundation

/// Small, non-secret ownership description recovered from the root-owned config.
/// It survives a helper restart without depending on the app's session cache.
struct XrayTunRuntimeInterfaces: Equatable, Sendable {
    let tunnel: String
    let outbound: String

    init?(configData: Data) {
        guard let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let inbounds = config["inbounds"] as? [[String: Any]],
              let outbounds = config["outbounds"] as? [[String: Any]] else { return nil }
        let tunnels = inbounds.filter { $0["protocol"] as? String == "tun" }
        guard tunnels.count == 1,
              let settings = tunnels[0]["settings"] as? [String: Any],
              let tunnel = settings["name"] as? String,
              tunnel.range(of: #"^utun[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        let interfaces = Set(outbounds.compactMap { outbound -> String? in
            let stream = outbound["streamSettings"] as? [String: Any]
            let options = stream?["sockopt"] as? [String: Any]
            return options?["interface"] as? String
        })
        guard interfaces.count == 1, let outbound = interfaces.first,
              outbound != "auto", !outbound.hasPrefix("utun"), outbound.count <= 32,
              outbound.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { return nil }
        self.tunnel = tunnel
        self.outbound = outbound
    }

    static func load(helperStateDirectoryPath: String) -> Self? {
        let path = helperStateDirectoryPath + "/xray-tun-config.json"
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0,
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              info.st_size > 0, info.st_size <= maxConfigBytes,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return Self(configData: data)
    }
}
