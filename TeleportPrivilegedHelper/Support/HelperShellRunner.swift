import Foundation

struct HelperShellRunner {
    func run(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stdout = BoundedOutputCollector(maxBytes: maxCapturedShellOutputBytes)
        let stderr = BoundedOutputCollector(maxBytes: maxCapturedShellOutputBytes)
        drain(outputPipe, into: stdout)
        drain(errorPipe, into: stderr)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stopDraining(outputPipe, into: stdout)
            stopDraining(errorPipe, into: stderr)
            throw error
        }

        stopDraining(outputPipe, into: stdout)
        stopDraining(errorPipe, into: stderr)

        guard process.terminationStatus == 0 else {
            throw HelperError([stderr.text(), stdout.text()].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    private func drain(_ pipe: Pipe, into collector: BoundedOutputCollector) {
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }
    }

    private func stopDraining(_ pipe: Pipe, into collector: BoundedOutputCollector) {
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        collector.append(fileHandle.readDataToEndOfFile())
    }
}

private final class BoundedOutputCollector {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        if data.count > maxBytes {
            data = Data(data.suffix(maxBytes))
            truncated = true
        }
    }

    func text() -> String {
        lock.lock()
        let capturedData = data
        let wasTruncated = truncated
        lock.unlock()

        var output = String(decoding: capturedData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if wasTruncated {
            output = "[output truncated to last \(maxBytes) bytes]\n" + output
        }
        return output
    }
}
