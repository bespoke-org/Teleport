import AppKit
import CoreFoundation
import Foundation

/// UI publication must also run while AppKit tracks a menu.
nonisolated enum MainRunLoopWork {
    static func run<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let loop = CFRunLoopGetMain()
            let modes = [CFRunLoopMode.commonModes.rawValue, RunLoop.Mode.eventTracking.rawValue as CFString] as CFArray
            CFRunLoopPerformBlock(loop, modes) {
                continuation.resume(returning: MainActor.assumeIsolated { operation() })
            }
            CFRunLoopWakeUp(loop)
        }
    }
}
