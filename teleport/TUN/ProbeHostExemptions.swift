import Foundation

/// The uplink addresses a health probe holds open through the leak guard.
///
/// A probe's Xray runs as the user, so the guard's `user root` exception does not
/// cover it, and `block drop` returns nothing the socket can see: the probe waits
/// out its timeout and reports that the server did not answer a question it was
/// never asked. The probe therefore opens the address it is about to question and
/// closes it again once it has an answer.
///
/// Counted rather than a plain set. The probe queue runs several checks at once
/// and two of them can name the same address — a subscription that publishes one
/// server under two names, or the same server probed twice — so the first to
/// finish must not close a path the second is still using.
///
/// Kept as a value type with no helper and no packet filter behind it, so the
/// bookkeeping can be verified directly, in the manner of `LeakGuardRuleset`.
nonisolated struct ProbeHostExemptions: Equatable, Sendable {
    /// How many of a server's addresses one check may open. The helper refuses a
    /// request naming more hosts than it will route, and a refused request leaves
    /// the guard unrenewed — so a full probe queue has to fit inside
    /// `TUNHelperProtocol.maximumProtectedHosts` alongside the session's own
    /// servers. Enough for a name published over both families with a pair spare.
    static let maximumAddressesPerProbe = 4

    private var retainCounts: [String: Int] = [:]

    init() {}

    /// Sorted, so that the same set of open addresses always produces the same
    /// ruleset and the guard is not re-engaged over a dictionary's ordering.
    var addresses: [String] {
        retainCounts.keys.sorted()
    }

    /// Returns whether the set of open addresses changed, which is the caller's
    /// signal that the guard has to be re-engaged. Opening an address that is
    /// already open changes nothing but its count.
    mutating func retain(_ addresses: [String]) -> Bool {
        var didChange = false
        for address in addresses where !address.isEmpty {
            let count = retainCounts[address] ?? 0
            retainCounts[address] = count + 1
            didChange = didChange || count == 0
        }
        return didChange
    }

    /// Releasing an address that was never opened is not an error: a probe that
    /// opened nothing releases nothing, and says so the same way.
    mutating func release(_ addresses: [String]) -> Bool {
        var didChange = false
        for address in addresses {
            guard let count = retainCounts[address] else { continue }
            if count > 1 {
                retainCounts[address] = count - 1
            } else {
                retainCounts.removeValue(forKey: address)
                didChange = true
            }
        }
        return didChange
    }
}
