import Foundation

/// Bridges genuinely blocking leaf work — `Process` waits, `networksetup`, TCP
/// readiness polling — off the cooperative thread pool.
///
/// The connection boundary is asynchronous, but the macOS APIs underneath it are
/// not. Running those waits directly inside an `async` call would park a
/// cooperative thread for seconds. Operations are already serialized by
/// `BackendConnectionProvider`, so one private serial queue is enough.
nonisolated enum BlockingWork {
    private static let queue = DispatchQueue(
        label: "dev.x.teleport.blocking-work",
        qos: .userInitiated
    )

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }
}
