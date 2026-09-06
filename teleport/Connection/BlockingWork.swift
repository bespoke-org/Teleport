import Foundation

/// Bridges genuinely blocking leaf work — `Process` waits, `networksetup`, disk
/// writes of tens of megabytes — off the cooperative thread pool.
///
/// Swift concurrency assumes `async` functions suspend rather than block, and its
/// pool is only about as wide as the machine has cores. The macOS APIs underneath
/// this app do not all have asynchronous forms, so the blocking ones run here, on a
/// private serial queue, instead of parking a cooperative thread for seconds.
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

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
