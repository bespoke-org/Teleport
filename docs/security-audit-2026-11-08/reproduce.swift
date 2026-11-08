import Foundation
// Historical reproducer for the audited source snapshot before the DNS/PF fixes.
// Success confirms the old vulnerabilities. Current regression checks live in XCTest.
let parser = ConnectionLinkParser()
let configuration = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@proxy.example:443?security=tls")
let writer = XrayConfigurationWriter(proxyEndpoint: .default)
let data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun99", outboundInterface: "en0", dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.168.1.1"]))
let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
print("DNS:", String(data: try JSONSerialization.data(withJSONObject: payload["dns"]!, options: [.sortedKeys]), encoding: .utf8)!)
let routing = payload["routing"] as! [String: Any]
print("DNS_ROUTES:", (routing["rules"] as! [[String: Any]]).filter { ($0["inboundTag"] as? [String]) == ["dns-internal"] })
let dns = payload["dns"] as! [String: Any]
precondition((dns["servers"] as! [Any]).contains { ($0 as? String) == "192.168.1.1" })
precondition(dns["disableFallback"] == nil)
print("CONFIRMED: full-proxy config has a direct system-DNS fallback")
let unsafe = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@proxy.example:443?security=tls&allowInsecure=1")
precondition(unsafe.allowsInsecureTLS)
let clear = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@proxy.example:443?security=none")
precondition(clear.security == .none)
print("CONFIRMED: insecure TLS and plaintext VLESS accepted")
let header = Data(#"{"Name":"Synthetic subscription","GlobalProxy":false}"#.utf8).base64EncodedString()
let parsed = SubscriptionRoutingHeaderParser().parse(header)
var profiles = [SplitTunnelProfile(name: "User proxy profile")]
var selected = Optional(profiles[0].id)
var enabled = false
parsed.routing!.apply(to: &profiles, sourceID: UUID(), selectedProfileID: &selected, isEnabled: &enabled)
precondition(enabled && profiles.first { $0.id == selected }!.defaultAction == .direct)
print("CONFIRMED: subscription header activates default-direct routing")
let rules = LeakGuardRuleset.rules(stage: .session(tunnelInterface: "utun99"), protectedHosts: ["192.0.2.1"])
precondition(rules.contains("pass out quick all user root"))
precondition(rules.contains("to any port { 53, 853 }"))
print("CONFIRMED: guard allows all root egress and unrestricted DNS ports")
