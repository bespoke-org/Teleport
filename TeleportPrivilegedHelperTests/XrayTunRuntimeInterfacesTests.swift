import Foundation
import XCTest

final class XrayTunRuntimeInterfacesTests: XCTestCase {
    func testReadsOnlyTunnelAndUplinkFromPersistedConfig() throws {
        let metadata = try XCTUnwrap(XrayTunRuntimeInterfaces(configData: config()))
        XCTAssertEqual(metadata.tunnel, "utun10")
        XCTAssertEqual(metadata.outbound, "en0")
    }

    func testRejectsAmbiguousOrInvalidInterfaces() throws {
        for tunnel in ["en0", "utun", "utun10\n", "utun99999"] {
            XCTAssertNil(XrayTunRuntimeInterfaces(configData: try config(tunnel: tunnel)), tunnel)
        }
        for outbound in ["", "auto", "utun5", "-en0", "en0; true", "en0\n"] {
            XCTAssertNil(XrayTunRuntimeInterfaces(configData: try config(outbounds: [outbound])), outbound)
        }
        XCTAssertNil(XrayTunRuntimeInterfaces(configData: try config(outbounds: ["en0", "en1"])))
        XCTAssertNil(XrayTunRuntimeInterfaces(configData: try config(outbounds: [])))
        XCTAssertNil(XrayTunRuntimeInterfaces(configData: Data("{}".utf8)))
        XCTAssertNil(XrayTunRuntimeInterfaces(configData: Data("invalid".utf8)))
    }

    func testDoesNotTrustUserOwnedConfigOrSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("xray-tun-config.json")
        try config().write(to: file)
        XCTAssertNil(XrayTunRuntimeInterfaces.load(helperStateDirectoryPath: directory.path))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(XrayTunRuntimeInterfaces.load(helperStateDirectoryPath: directory.path))
    }

    private func config(tunnel: String = "utun10", outbounds: [String] = ["en0", "en0"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "inbounds": [["protocol": "tun", "settings": ["name": tunnel]]],
            "outbounds": outbounds.map { ["streamSettings": ["sockopt": ["interface": $0]]] }
        ])
    }
}
