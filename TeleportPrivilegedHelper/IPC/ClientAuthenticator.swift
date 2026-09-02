import Darwin
import Foundation
import Security

struct ClientAuthenticator {
    func authorizePeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw HelperError("Could not verify Teleport client identity")
        }
        let consoleOwner = consoleUserIDs()
        guard uid == consoleOwner.uid else {
            throw HelperError("Rejected request from uid \(uid); expected console uid \(consoleOwner.uid)")
        }
        _ = gid
        try authorizePeerCodeSignature(fd)
    }

    private func authorizePeerCodeSignature(_ fd: Int32) throws {
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDLength) == 0 else {
            throw HelperError("Could not identify Teleport client process")
        }

        var secCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: peerPID] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &secCode)
        guard status == errSecSuccess, let secCode else {
            throw HelperError("Could not inspect Teleport client signature: OSStatus \(status)")
        }

        var requirement: SecRequirement?
        let requirementText = "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"6RXJJA7GCX\""
        status = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw HelperError("Could not create Teleport signature requirement: OSStatus \(status)")
        }

        status = SecCodeCheckValidity(secCode, SecCSFlags(), requirement)
        guard status == errSecSuccess else {
            throw HelperError("Rejected request from unsigned or untrusted Teleport client: OSStatus \(status)")
        }
    }
}
