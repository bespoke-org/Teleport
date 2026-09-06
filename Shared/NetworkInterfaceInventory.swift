import Darwin
import Foundation

/// Interface facts read from the kernel through `getifaddrs`, shared by the app
/// and the privileged helper. Reading addresses directly avoids parsing
/// `ifconfig` text, whose layout differs between machines and macOS releases.
nonisolated enum NetworkInterfaceInventory {
    struct InterfaceAddress: Equatable {
        let interfaceName: String
        let family: Int32
        let address: String
        let isLinkLocal: Bool
    }

    static func interfaceNames() -> Set<String> {
        Set(addresses().map(\.interfaceName))
    }

    static func ipv4Address(of interfaceName: String) -> String? {
        addresses().first { $0.interfaceName == interfaceName && $0.family == AF_INET }?.address
    }

    /// True when the interface holds a globally routable IPv6 address (2000::/3).
    /// Link-local and unique-local addresses do not count: with only those, an
    /// IPv6 default route through the tunnel could never reach anything.
    static func hasGlobalIPv6Address(_ interfaceName: String) -> Bool {
        addresses().contains { entry in
            guard entry.interfaceName == interfaceName, entry.family == AF_INET6, !entry.isLinkLocal else {
                return false
            }
            return isGlobalUnicastIPv6(entry.address)
        }
    }

    static func isGlobalUnicastIPv6(_ address: String) -> Bool {
        var raw = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &raw) }) == 1 else { return false }
        let firstByte = withUnsafeBytes(of: raw) { $0[0] }
        return firstByte & 0xE0 == 0x20
    }

    static func addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard let sockaddrPointer = entry.pointee.ifa_addr else {
                if !result.contains(where: { $0.interfaceName == name }) {
                    result.append(InterfaceAddress(interfaceName: name, family: AF_UNSPEC, address: "", isLinkLocal: false))
                }
                continue
            }
            let family = Int32(sockaddrPointer.pointee.sa_family)
            switch family {
            case AF_INET:
                var storage = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &storage, &buffer, socklen_t(buffer.count)) != nil else { continue }
                result.append(InterfaceAddress(interfaceName: name, family: AF_INET, address: String(cString: buffer), isLinkLocal: false))
            case AF_INET6:
                var storage = sockaddrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &storage, &buffer, socklen_t(buffer.count)) != nil else { continue }
                let bytes = withUnsafeBytes(of: storage) { Array($0.prefix(2)) }
                let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
                result.append(InterfaceAddress(interfaceName: name, family: AF_INET6, address: String(cString: buffer), isLinkLocal: isLinkLocal))
            default:
                if !result.contains(where: { $0.interfaceName == name }) {
                    result.append(InterfaceAddress(interfaceName: name, family: family, address: "", isLinkLocal: false))
                }
            }
        }
        return result
    }
}
