import Foundation

/// Resolves only a proxy endpoint through a fixed HTTPS service. curl inherits
/// the helper's private group; neither system DNS nor a user's proxy/curlrc is used.
struct EndpointResolver {
    static func resolve(_ request: ResolveEndpointRequest) throws -> ResolveEndpointResponse {
        var addresses: [String] = []
        for type in ["A", "AAAA"] {
            var components = URLComponents(string: "https://\(LeakGuardRuleset.bootstrapAddress)/dns-query")!
            components.queryItems = [.init(name: "name", value: request.host), .init(name: "type", value: type)]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.arguments = ["-q", "--fail", "--silent", "--noproxy", "*", "--proxy", "",
                                 "--proto", "=https", "--max-time", "4", "--connect-timeout", "2",
                                 "--max-filesize", "65536", "--interface", "if!" + request.interface,
                                 "--header", "accept: application/dns-json", components.url!.absoluteString]
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, bytes.count <= 65536 else { continue }
            addresses += try parse(bytes, recordType: type == "A" ? 1 : 28)
        }
        return ResolveEndpointResponse(addresses: Array(Set(addresses)).sorted().prefix(16).map { $0 })
    }

    static func parse(_ data: Data, recordType: Int) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["Status"] as? Int == 0 else { return [] }
        return ((object["Answer"] as? [[String: Any]]) ?? []).compactMap {
            guard $0["type"] as? Int == recordType, let address = $0["data"] as? String,
                  isNumericIPAddress(address), address.contains(":") == (recordType == 28) else { return nil }
            return address
        }
    }
}
