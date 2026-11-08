import Combine
import Foundation

nonisolated enum MCPAccess: String, CaseIterable {
    case off
    case readOnly
    case readWrite

    var title: String {
        switch self {
        case .off: return "Off"
        case .readOnly: return "Read only"
        case .readWrite: return "Read and edit"
        }
    }
}

@MainActor
final class TeleportMCPController: ObservableObject {
    static let defaultsKey = "mcpAccess"
    @Published private(set) var access: MCPAccess
    @Published private(set) var error: String?
    @Published private(set) var lastOperation: String?
    private let defaults: UserDefaults
    private var server: MCPLocalServer?
    private var service: TeleportMCPService?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        access = MCPAccess(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .off
    }

    func attach(to model: AppViewModel) {
        service = TeleportMCPService(model: model, access: { [weak self] in self?.access ?? .off })
        startIfNeeded()
    }

    func setAccess(_ value: MCPAccess) {
        access = value
        defaults.set(value.rawValue, forKey: Self.defaultsKey)
        error = nil
        if value == .off {
            stop()
        } else {
            startIfNeeded()
        }
    }

    func stop() {
        generation = UUID()
        server?.stop()
        server = nil
    }

    private func startIfNeeded() {
        guard access != .off, server == nil, service != nil else { return }
        let token = generation
        do {
            server = try MCPLocalServer { [weak self] request in
                await self?.handle(request, generation: token) ?? Data("{\"content\":[{\"type\":\"text\",\"text\":\"Teleport is unavailable\"}],\"isError\":true}".utf8)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handle(_ request: Data, generation token: UUID) async -> Data {
        guard !Task.isCancelled, token == generation, let service else {
            return try! JSONSerialization.data(withJSONObject: MCPProtocolSession.toolError("MCP session was disabled. Reconnect the client."))
        }
        if let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
           let name = object["name"] as? String, MCPTools.definitions.contains(where: { $0["name"] as? String == name }) {
            lastOperation = name
        }
        return await service.handle(request)
    }

    var clientConfiguration: String {
        let command = Bundle.main.executableURL?.path ?? "/Applications/Teleport.app/Contents/MacOS/Teleport"
        let value: [String: Any] = ["mcpServers": ["teleport": ["command": command, "args": ["--mcp"]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
