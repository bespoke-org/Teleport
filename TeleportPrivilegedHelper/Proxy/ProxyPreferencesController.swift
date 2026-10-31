import Foundation

/// Called on the dispatcher's serialized mutation queue. The helper opens and
/// locks preferences as root; no per-connection Authorization Services grant.
final class ProxyPreferencesController: @unchecked Sendable {
    static let shared = ProxyPreferencesController()
    private let lock = NSLock()
    private var transactionID: UUID?
    private let preferences: any ProxyPreferencesAccess

    init(preferences: any ProxyPreferencesAccess = SystemProxyPreferences()) {
        self.preferences = preferences
    }

    func read() throws -> ProxyPreferencesSnapshot {
        lock.lock()
        defer { lock.unlock() }
        // Invalidate older writes, including a request delayed on another XPC
        // connection. A read used for recovery fences every previous transaction.
        transactionID = nil
        do {
            let inventory = try preferences.read()
            let id = UUID()
            transactionID = id
            return ProxyPreferencesSnapshot(transactionID: id, inventory: inventory)
        } catch { throw HelperError(error.localizedDescription) }
    }

    func apply(_ request: ApplyProxyPreferencesRequest) throws -> ApplyProxyPreferencesResponse {
        try request.validateMutations()
        lock.lock()
        defer { lock.unlock() }
        guard transactionID == request.transactionID else { return ApplyProxyPreferencesResponse(applied: false) }
        transactionID = nil
        do {
            var applied = false
            try preferences.transaction { inventory, apply in
                guard request.matches(inventory) else { return }
                try apply(request.mutations)
                applied = true
            }
            return ApplyProxyPreferencesResponse(applied: applied)
        } catch { throw HelperError(error.localizedDescription) }
    }
}

extension XrayTunController {
    func readProxyPreferences(request: ReadProxyPreferencesRequest) throws -> ProxyPreferencesSnapshot {
        try ProxyPreferencesController.shared.read()
    }

    func applyProxyPreferences(request: ApplyProxyPreferencesRequest) throws -> ApplyProxyPreferencesResponse {
        try ProxyPreferencesController.shared.apply(request)
    }
}
