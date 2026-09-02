import Foundation

let helperVersion = PrivilegedHelperConstants.version
let helperLabel = PrivilegedHelperConstants.label
let socketPath = PrivilegedHelperConstants.socketPath
let helperStateDirectoryPath = PrivilegedHelperConstants.helperStateDirectoryPath
let installedXrayPath = PrivilegedHelperConstants.installedXrayPath
let helperClientCodeSigningRequirement = "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"6RXJJA7GCX\""
let maxRequestBytes = 2 * 1024 * 1024
let maxConfigBytes = 1024 * 1024
let maxLogReadBytes = 1024 * 1024
let maxCapturedShellOutputBytes = 64 * 1024
