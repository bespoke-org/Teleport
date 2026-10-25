import Foundation

/// Custom URL edits stay local until submitted; provider selections apply immediately.
struct GeodataSourceDraft {
    enum Choice: Hashable {
        case bundled, provider(String), custom
    }

    struct Provider: Identifiable {
        let name: String
        let geositeURLString: String
        let geoipURLString: String
        var id: String { name }
    }

    struct URLs: Equatable {
        var geosite: String?
        var geoip: String?
        var usesDownloads: Bool { geosite != nil || geoip != nil }

        subscript(kind: GeodataKind) -> String? {
            kind == .geosite ? geosite : geoip
        }
    }

    var choice: Choice
    var geositeURL: String
    var geoipURL: String

    init(settings: GeodataSourceSettings) {
        geositeURL = settings.geositeURLString ?? ""
        geoipURL = settings.geoipURLString ?? ""
        if let provider = Self.presets.first(where: {
            $0.geositeURLString == settings.geositeURLString && $0.geoipURLString == settings.geoipURLString
        }) {
            choice = .provider(provider.id)
        } else if Self.savedURLs(settings).usesDownloads {
            choice = .custom
        } else {
            choice = .bundled
        }
    }

    var urls: URLs {
        switch choice {
        case .bundled: return URLs()
        case .custom: return URLs(geosite: Self.normalized(geositeURL), geoip: Self.normalized(geoipURL))
        case .provider(let id):
            guard let provider = Self.presets.first(where: { $0.id == id }) else { return URLs() }
            return URLs(geosite: provider.geositeURLString, geoip: provider.geoipURLString)
        }
    }

    func validationError(for kind: GeodataKind) -> String? {
        guard choice != .bundled else { return nil }
        guard let value = urls[kind] else { return "Enter an HTTPS URL." }
        return GeodataUpdateService.validatedSourceURL(value) == nil ? "Enter a valid HTTPS URL." : nil
    }

    static func savedURLs(_ settings: GeodataSourceSettings) -> URLs {
        URLs(geosite: normalized(settings.geositeURLString), geoip: normalized(settings.geoipURLString))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static let presets: [Provider] = [
        Provider(
            name: "V2Fly (official)",
            geositeURLString: "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat",
            geoipURLString: "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
        ),
        Provider(
            name: "Loyalsoldier",
            geositeURLString: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
            geoipURLString: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        ),
        Provider(
            name: "Rulite",
            geositeURLString: "https://cdn.jsdelivr.net/gh/sendmiche/rulite@latest/geosite.dat",
            geoipURLString: "https://github.com/sendmiche/rulite/releases/latest/download/geoip.dat"
        ),
        Provider(
            name: "RuNet Freedom (Russia)",
            geositeURLString: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat",
            geoipURLString: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"
        )
    ]

}
