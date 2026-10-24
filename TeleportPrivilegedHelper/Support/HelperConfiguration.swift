import Foundation

let helperVersion = PrivilegedHelperConstants.version
let helperLabel = PrivilegedHelperConstants.label
let helperStateDirectoryPath = PrivilegedHelperConstants.helperStateDirectoryPath
let installedXrayPath = PrivilegedHelperConstants.installedXrayPath
/// Clients must be signed by the team that signed this helper. A helper without
/// a Team ID has no team to trust and accepts no client.
let helperClientCodeSigningRequirement = TeleportCodeSigning.currentRequirement()
let maxRequestBytes = 2 * 1024 * 1024
let maxConfigBytes = 1024 * 1024
let maxLogReadBytes = 1024 * 1024
let maxCapturedShellOutputBytes = 64 * 1024
