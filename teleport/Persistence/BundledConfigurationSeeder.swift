import Foundation

struct BundledConfigurationSeeder {
    private let bundle: Bundle
    private let parser: ConnectionLinkParser
    private let decoder = JSONDecoder()

    init(bundle: Bundle = .main, parser: ConnectionLinkParser = ConnectionLinkParser()) {
        self.bundle = bundle
        self.parser = parser
    }

    /// Display names of the bundled subscriptions, for offering them to the user
    /// before anything is imported.
    func subscriptionTitles() -> [String] {
        guard let seed = loadSeed() else { return [] }
        return seed.subscriptions.compactMap { subscription in
            subscription.validatedURL.map(subscription.resolvedDisplayName(for:))
        }
    }

    func seed(_ snapshot: AppSnapshot, now: Date = Date()) -> AppSnapshot {
        guard let seed = loadSeed() else {
            return snapshot
        }

        var savedConnections = snapshot.savedConnections
        var subscriptionSources = snapshot.subscriptionSources
        var selectedConnectionID = snapshot.selectedConnectionID

        for subscription in seed.subscriptions {
            guard let url = subscription.validatedURL,
                  !subscriptionSources.contains(where: { $0.urlString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
                continue
            }

            subscriptionSources.append(
                SubscriptionSource(
                    id: UUID(),
                    urlString: url.absoluteString,
                    title: subscription.resolvedDisplayName(for: url),
                    savedAt: now,
                    autoUpdateIntervalMinutes: subscription.normalizedAutoUpdateIntervalMinutes,
                    filterDuplicateImports: subscription.filterDuplicateImports ?? true
                )
            )
        }

        for connection in seed.connections {
            do {
                var configuration = try parser.parse(connection.link)
                if let displayName = connection.normalizedDisplayName {
                    configuration = configuration.withDisplayName(displayName)
                }

                let savedConnection = SavedConnection(
                    id: UUID(),
                    configuration: configuration,
                    savedAt: now,
                    source: nil
                )
                savedConnections.append(savedConnection)

                if selectedConnectionID == nil {
                    selectedConnectionID = savedConnection.id
                }
            } catch {
                continue
            }
        }

        return AppSnapshot(
            savedConnections: savedConnections,
            subscriptionSources: subscriptionSources,
            selectedConnectionID: selectedConnectionID,
            proxyEndpoint: snapshot.proxyEndpoint,
            connectionMode: snapshot.connectionMode,
            subscriptionConnectionSort: snapshot.subscriptionConnectionSort,
            showsLatencyInMenuBarPicker: snapshot.showsLatencyInMenuBarPicker,
            animatesMenuBarIcon: snapshot.animatesMenuBarIcon,
            showsInDock: snapshot.showsInDock,
            connectsOnLaunch: snapshot.connectsOnLaunch
        )
    }

    private func loadSeed() -> BundledConfigurationSeed? {
        guard let seedURL = bundle.url(forResource: "bundled-connections", withExtension: "json"),
              let data = try? Data(contentsOf: seedURL) else {
            return nil
        }
        return try? decoder.decode(BundledConfigurationSeed.self, from: data)
    }
}

private struct BundledConfigurationSeed: Decodable {
    var subscriptions: [BundledSubscription] = []
    var connections: [BundledConnection] = []

    private enum CodingKeys: String, CodingKey {
        case subscriptions
        case connections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([BundledSubscription].self, forKey: .subscriptions) ?? []
        connections = try container.decodeIfPresent([BundledConnection].self, forKey: .connections) ?? []
    }
}

private struct BundledSubscription: Decodable {
    let url: String
    let displayName: String?
    let autoUpdateIntervalMinutes: Int?
    let filterDuplicateImports: Bool?

    var validatedURL: URL? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return url
    }

    var normalizedAutoUpdateIntervalMinutes: Int? {
        guard let autoUpdateIntervalMinutes, autoUpdateIntervalMinutes > 0 else { return nil }
        return autoUpdateIntervalMinutes
    }

    func resolvedDisplayName(for url: URL) -> String {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        return url.host ?? url.absoluteString
    }
}

private struct BundledConnection: Decodable {
    let link: String
    let displayName: String?

    var normalizedDisplayName: String? {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty else {
            return nil
        }
        return displayName
    }
}
