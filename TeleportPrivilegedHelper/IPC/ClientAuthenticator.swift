import Darwin
import Foundation

struct ClientAuthenticator {
    let requirement: String?

    init(requirement: String? = helperClientCodeSigningRequirement) {
        self.requirement = requirement
    }

    func configureAndAuthorize(_ connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        let consoleOwner = consoleUserIDs()
        guard consoleOwner.uid != 0,
              connection.effectiveUserIdentifier == consoleOwner.uid else {
            return false
        }

        connection.setCodeSigningRequirement(requirement)
        return true
    }
}
