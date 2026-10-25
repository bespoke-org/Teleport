// Prints the plaintext of one sealed snapshot file written by ConfigurationStore.
// Usage: security find-generic-password -s dev.x.teleport.configuration -a app-snapshot.key -w \
//            | swift scripts/decrypt-snapshot.swift <sealed file>
// `security -w` prints a binary password as hex, which is what stdin is expected to hold.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: decrypt-snapshot.swift <sealed file>, key as hex on stdin\n".utf8))
    exit(2)
}

let hex = Array(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
let keyBytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) }
guard hex.count == 64, keyBytes.count == 32 else {
    FileHandle.standardError.write(Data("expected a 32-byte key as hex on stdin\n".utf8))
    exit(1)
}

do {
    let sealed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: keyBytes))
    FileHandle.standardOutput.write(plaintext)
} catch {
    FileHandle.standardError.write(Data("could not open the file: \(error)\n".utf8))
    exit(1)
}
