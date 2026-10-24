import Foundation
import Security

/// The code-signing requirement the app and the helper apply to each other.
///
/// Both executables are signed with the one Team ID in `DEVELOPMENT_TEAM`
/// (set in Config/Local.xcconfig), so each reads that ID from its own signature
/// rather than carrying a copy of it: a build made by another team trusts that
/// team's binaries and no one else's, with no source edit.
nonisolated enum TeleportCodeSigning {
    static let appIdentifier = "dev.x.teleport"

    static func requirement(teamIdentifier: String) -> String {
        "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// The requirement for executables signed like this one, or nil when this
    /// one carries no Team ID (an unsigned or ad hoc signed build). Callers treat
    /// nil as "trust nothing".
    static func currentRequirement() -> String? {
        currentTeamIdentifier().map(requirement(teamIdentifier:))
    }

    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            return nil
        }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
