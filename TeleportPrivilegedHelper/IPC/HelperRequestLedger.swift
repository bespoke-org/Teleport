import CryptoKit
import Foundation

struct HelperRequestFingerprint: Hashable, Sendable {
    let command: VPNHelperCommand
    let payloadDigest: Data

    init(command: VPNHelperCommand, payload: Data) {
        self.command = command
        payloadDigest = Data(SHA256.hash(data: payload))
    }
}

enum HelperLedgerLookup: Equatable, Sendable {
    case unknown
    case inProgress
    case completed(Data)
    case conflict
}

enum HelperRequestLedgerError: Error, Equatable {
    case capacityExceeded
}

struct HelperRequestLedger {
    private enum EntryState {
        case inProgress
        case completed(Data, completedAt: Date)
    }

    private struct Entry {
        let fingerprint: HelperRequestFingerprint
        let insertionOrder: UInt64
        var state: EntryState
    }

    private let maximumEntries: Int
    private let maximumAge: TimeInterval
    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]
    private var nextInsertionOrder: UInt64 = 0

    init(maximumEntries: Int, maximumAge: TimeInterval, now: @escaping () -> Date = Date.init) {
        precondition(maximumEntries > 0)
        precondition(maximumAge >= 0)
        self.maximumEntries = maximumEntries
        self.maximumAge = maximumAge
        self.now = now
    }

    mutating func lookup(requestID: UUID, fingerprint: HelperRequestFingerprint) -> HelperLedgerLookup {
        pruneExpiredEntries()
        guard let entry = entries[requestID] else {
            return .unknown
        }
        guard entry.fingerprint == fingerprint else {
            return .conflict
        }
        switch entry.state {
        case .inProgress:
            return .inProgress
        case let .completed(responseData, _):
            return .completed(responseData)
        }
    }

    mutating func begin(requestID: UUID, fingerprint: HelperRequestFingerprint) throws {
        pruneExpiredEntries()
        guard entries[requestID] == nil else {
            return
        }

        while entries.count >= maximumEntries {
            guard let oldestCompletedRequestID else {
                throw HelperRequestLedgerError.capacityExceeded
            }
            entries.removeValue(forKey: oldestCompletedRequestID)
        }

        entries[requestID] = Entry(
            fingerprint: fingerprint,
            insertionOrder: nextInsertionOrder,
            state: .inProgress
        )
        nextInsertionOrder &+= 1
    }

    mutating func complete(
        requestID: UUID,
        fingerprint: HelperRequestFingerprint,
        responseData: Data
    ) {
        pruneExpiredEntries()
        guard var entry = entries[requestID], entry.fingerprint == fingerprint else {
            return
        }
        entry.state = .completed(responseData, completedAt: now())
        entries[requestID] = entry
        pruneCompletedEntriesToMaximumCount()
    }

    private var oldestCompletedRequestID: UUID? {
        entries
            .filter { _, entry in
                if case .completed = entry.state { return true }
                return false
            }
            .min { lhs, rhs in lhs.value.insertionOrder < rhs.value.insertionOrder }?
            .key
    }

    private mutating func pruneExpiredEntries() {
        let currentTime = now()
        entries = entries.filter { _, entry in
            switch entry.state {
            case .inProgress:
                return true
            case let .completed(_, completedAt):
                return currentTime.timeIntervalSince(completedAt) <= maximumAge
            }
        }
    }

    private mutating func pruneCompletedEntriesToMaximumCount() {
        while entries.count > maximumEntries, let oldestCompletedRequestID {
            entries.removeValue(forKey: oldestCompletedRequestID)
        }
    }
}
