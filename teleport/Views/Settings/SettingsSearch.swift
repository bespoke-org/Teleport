import Foundation

struct SettingsSearchResult: Identifiable, Equatable {
    let section: SettingsSection
    let title: String
    var id: String { "\(section.rawValue).\(title)" }
    var subtitle: String? {
        if title != section.title { return section.title }
        return section == section.sidebarSection ? nil : section.sidebarSection.title
    }
}

enum SettingsSearch {
    private struct Entry {
        let result: SettingsSearchResult
        let keywords: String
    }

    // Keep labels aligned with the controls on each settings page. Search never
    // reads portal names, subscription URLs, or other user configuration.
    private static let entries: [Entry] =
        SettingsSection.allCases.map {
            let keywords: String
            switch $0 {
            case .advanced: keywords = "advanced diagnostics"
            case .tunnel: keywords = "tunnel split tunneling traffic"
            default: keywords = ""
            }
            return Entry(result: SettingsSearchResult(section: $0, title: $0.title), keywords: keywords)
        } + [
            entry(.general, "Connection mode", "tun tunnel system proxy vpn"),
            entry(.general, "Protect traffic during tunnel interruptions", "kill switch leak guard protection reconnect"),
            entry(.general, "Show Teleport in Dock", "app switcher cmd tab"),
            entry(.general, "Animate menu bar icon", "animation"),
            entry(.general, "Show portal latency", "ping speed menu bar"),
            entry(.general, "Portal order", "sort subscription original name latency"),
            entry(.general, "Launch at login", "startup automatic start"),
            entry(.general, "Connect on launch", "startup automatic connection"),
            entry(.general, "App icon", "appearance color palette graphite purple teal orange"),
            entry(.portals, "Add portal", "import subscription link qr code connection server"),
            entry(.portals, "Routing profile", "assign subscription standalone portal inherit personal"),
            entry(.tunnel, "Split routing", "split tunneling global enable disable bypass rules domains ip"),
            entry(.tunnel, "Profiles", "routing profile editor rules copy personal provider"),
            entry(.tunnel, "Unmatched traffic", "default route proxy direct"),
            entry(.tunnel, "Geodata", "geosite geoip domain ip lists"),
            entry(.tunnel, "Source", "custom urls geosite geoip domain ip lists"),
            entry(.tunnel, "Automatic updates", "geodata interval schedule download"),
            entry(.advanced, "MCP access", "ai assistants model context protocol routing subscriptions"),
            entry(.advanced, "Local proxy ports", "http https socks5 localhost 127.0.0.1"),
            entry(.advanced, "Privileged helper", "uninstall maintenance administrator"),
            entry(.advanced, "Capture network state", "diagnostics routes dns firewall"),
            entry(.logs, "Logs", "debug errors troubleshooting xray helper"),
            entry(.about, "Versions", "version teleport xray build"),
            entry(.about, "Project links", "github source code license"),
        ]

    static func results(for query: String) -> [SettingsSearchResult] {
        let words = normalized(query).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else {
            return SettingsSection.sidebarSections.map { SettingsSearchResult(section: $0, title: $0.title) }
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            let text = normalized(entry.result.title + " " + entry.keywords)
            guard words.allSatisfy({ text.contains($0) }), seen.insert(entry.result.id).inserted else { return nil }
            return entry.result
        }
    }

    private static func entry(_ section: SettingsSection, _ title: String, _ keywords: String) -> Entry {
        Entry(result: SettingsSearchResult(section: section, title: title), keywords: keywords)
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
