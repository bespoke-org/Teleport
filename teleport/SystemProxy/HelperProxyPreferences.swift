import Foundation
import Synchronization

/// The journal stays in the app. All privileged writes, including recovery, go
/// through the approved helper. The synchronous coordinator calls this on a
/// dispatch queue, never the main actor or the cooperative executor.
nonisolated final class HelperProxyPreferences: ProxyPreferencesAccess {
    private let reader = SystemProxyPreferences()
    private let client: PrivilegedHelperClient
    private let ensureInstalled: @Sendable () async throws -> Void

    init(
        client: PrivilegedHelperClient = PrivilegedHelperClient(),
        ensureInstalled: @escaping @Sendable () async throws -> Void = {
            guard let runtime = Bundle.main.url(forResource: "xray", withExtension: nil) else {
                throw XrayRuntimeManager.RuntimeError.binaryNotFound
            }
            try await PrivilegedHelperInstaller().ensureInstalled(runtimeURL: runtime)
        }
    ) {
        self.client = client
        self.ensureInstalled = ensureInstalled
    }

    func read() throws -> ProxyInventory { try reader.read() }

    func transaction(_ body: (ProxyInventory, ([ProxyMutation]) throws -> Void) throws -> Void) throws {
        let client = client
        let ensureInstalled = ensureInstalled
        let snapshot = try Self.wait {
            try await ensureInstalled()
            // A queue barrier is necessary even after a lost reply: a local read
            // could otherwise discard the journal before an earlier write lands.
            return try await client.readProxyPreferences()
        }
        try body(snapshot.inventory) { mutations in
            try Self.wait {
                try await client.applyProxyPreferences(ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: snapshot.inventory, mutations: mutations))
            }
        }
    }

    func observe(_ changed: @escaping @Sendable () -> Void) -> (any ProxyPreferencesObserving)? {
        reader.observe(changed)
    }

    private static func wait<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let result = Mutex<Result<T, Error>?>(nil)
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            let value: Result<T, Error>
            do { value = .success(try await operation()) }
            catch { value = .failure(error) }
            result.withLock { $0 = value }
            ready.signal()
        }
        ready.wait()
        return try result.withLock { try $0!.get() }
    }
}
