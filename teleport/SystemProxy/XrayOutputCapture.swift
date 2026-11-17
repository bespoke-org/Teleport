import Darwin
import Foundation

/// One process owns one capture. All reads, diagnostics and disk operations run inline on one
/// dedicated IO queue. DispatchSource coalesces readiness: there is no per-chunk async backlog.
/// close() is called off this queue, after the child exits (or fails to spawn).
nonisolated final class XrayOutputCapture: @unchecked Sendable {
    static let diagnosticLimit = 256 * 1024
    private static let prefixLimit = 64 * 1024
    private static let marker = Data("\n… xray output omitted …\n".utf8)
    private let queue = DispatchQueue(label: "dev.x.teleport.xray-output", qos: .utility)
    private let reader: FileHandle
    private let source: DispatchSourceRead
    private let cancelled = DispatchGroup()
    private var sink: XrayLogSink?
    private var prefix = Data()
    private var tail = Data()
    private var omitted = false
    private var diskFailed = false
    private var state: State = .open
    private var expectedExit = false
    private enum State { case open, draining, closed }

    init(reader: FileHandle, directory: URL, policy: XrayLogPolicy,
         clock: @escaping () -> Date = Date.init,
         write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        self.reader = reader
        let descriptor = reader.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(.EIO)
        }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // Disk failures must not prevent draining the child pipe or bounded RAM diagnostics.
        do {
            sink = try XrayLogSink(directory: directory, policy: policy, clock: clock, write: write)
            try sink?.append(Data("\n===== xray started \(TeleportLog.timestamp()) =====\n".utf8))
        } catch {
            sink?.close()
            sink = nil
            diskFailed = true
        }
        cancelled.enter()
        let cancelled = self.cancelled
        source.setCancelHandler {
            try? reader.close()
            cancelled.leave()
        }
        source.setEventHandler { [weak self] in self?.readAvailable(maximum: 64 * 1024) }
        source.resume()
    }

    func expectExit() { queue.sync { expectedExit = true } }
    var expectsExit: Bool { queue.sync { expectedExit } }
    var storedByteCount: Int { queue.sync { prefix.count + tail.count + (omitted ? Self.marker.count : 0) } }
    var hasDiskFailure: Bool { queue.sync { diskFailed } }

    func capturedOutput() -> String? {
        queue.sync {
            guard !prefix.isEmpty || !tail.isEmpty || diskFailed else { return nil }
            var data = prefix
            if omitted { data.append(Self.marker) }
            data.append(tail)
            // Lossy decoding keeps split/malformed UTF-8 from erasing all diagnostics.
            let text = String(decoding: data, as: UTF8.self)
            return diskFailed ? "[Xray disk logging unavailable]\n" + text : text
        }
    }

    /// A barrier for accepted reads/writes; the dispatch cancellation handler closes the fd
    /// only after the last event handler returns. Repeated close/EOF is safe.
    func close() {
        queue.sync {
            guard state != .closed else { return }
            state = .draining
            // After process exit only the bounded kernel pipe contents remain. The cap also
            // makes failed-spawn/fixture teardown safe if a writer was mistakenly left open.
            readAvailable(maximum: 1024 * 1024)
            finish()
        }
        cancelled.wait()
    }

    private func readAvailable(maximum: Int) {
        guard state != .closed else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var remaining = maximum
        while remaining > 0 {
            let count = Darwin.read(reader.fileDescriptor, &buffer, min(buffer.count, remaining))
            if count > 0 {
                consume(Data(buffer.prefix(count)))
                remaining -= count
            } else if count == 0 {
                finish()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish()
                return
            }
        }
    }

    private func consume(_ data: Data) {
        let headCount = min(Self.prefixLimit - prefix.count, data.count)
        prefix.append(data.prefix(headCount))
        let rest = data.dropFirst(headCount)
        let capacity = Self.diagnosticLimit - Self.prefixLimit
        if tail.count + rest.count > capacity { omitted = true }
        let tailCapacity = capacity - (omitted ? Self.marker.count : 0)
        if rest.count >= tailCapacity {
            tail = Data(rest.suffix(tailCapacity))
        } else {
            let excess = max(0, tail.count + rest.count - tailCapacity)
            if excess > 0 { tail.removeFirst(excess) }
            tail.append(contentsOf: rest)
        }
        do {
            try sink?.append(data)
        } catch {
            // Stop trying disk IO for this run: no recursive logging/retry storm.
            sink?.close()
            sink = nil
            diskFailed = true
        }
    }

    private func finish() {
        guard state != .closed else { return }
        state = .closed
        sink?.close()
        sink = nil
        source.cancel()
    }
}
