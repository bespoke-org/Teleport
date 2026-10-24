import Darwin
import Foundation

struct ClientAuthenticator {
    func configureAndAuthorize(_ connection: NSXPCConnection) -> Bool {
        let consoleOwner = consoleUserIDs()
        guard consoleOwner.uid != 0,
              connection.effectiveUserIdentifier == consoleOwner.uid,
              let approval = HelperInstallationManifest.loadApproved() else {
            return false
        }

        connection.setCodeSigningRequirement(approval.clientRequirement)
        return true
    }
}
