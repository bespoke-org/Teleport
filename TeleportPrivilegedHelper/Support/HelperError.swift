import Darwin
import Foundation

struct HelperError: LocalizedError, TUNHelperClientPresentableError {
    let message: String

    init(_ message: String) {
        self.message = message.isEmpty ? "Privileged helper command failed" : message
    }

    var errorDescription: String? { clientSummary }
    var failureReason: String? { clientDetails }

    var clientSummary: String {
        if message == "Missing geosite.dat" || message == "Missing geoip.dat" || message == "Missing geodata asset directory" {
            return "The tunnel's geodata files are missing. Open Settings → Routing and download the selected profile's geodata before connecting again."
        }
        if message.contains("group/world-writable") || message.contains("not owned") {
            if message.contains("geodata") || message.contains("geosite.dat") || message.contains("geoip.dat") {
                return "The geodata files have incorrect ownership or permissions. Download the selected profile's data again in Settings → Routing to recreate them for your macOS account."
            }
            if message.contains("state directory"), !message.contains("helper state") {
                return "Teleport's support folder has incorrect ownership or permissions. Restore your macOS account's ownership of ~/Library/Application Support/teleport and restrict the folder to that account, then reconnect."
            }
            return "The privileged helper found incorrect ownership or permissions on Teleport's files. Reinstall Teleport's helper with administrator approval to restore its managed files."
        }
        if message.hasPrefix("Rejected") || message.hasPrefix("Missing") {
            return "The privileged helper rejected invalid tunnel settings from Teleport. Update or reinstall Teleport so the app and helper agree on the configuration."
        }
        if message == "Xray tunnel config is too large" {
            return "The tunnel profile contains too many routing rules or additional portals. Reduce them in Settings → Routing, then connect again."
        }
        if message.contains("packet filter") || message.contains("leak-guard firewall") {
            return "macOS could not enable Teleport's traffic-protection firewall. Close other VPN or firewall apps and reconnect. You can also turn off traffic protection in Settings → General if you do not need it."
        }
        if message == "Could not resolve console user home directory" {
            return "The helper could not identify the signed-in macOS user. Sign out of macOS and sign back in before connecting again."
        }
        return message
    }

    var clientDetails: String? { clientSummary == message ? nil : message }

    /// Native system errors carry a stable code. Do not expose an arbitrary
    /// Error's description: it can contain configuration or root-only output.
    static func systemFailure(_ error: Error) -> HelperError? {
        let systemError = error as NSError
        if systemError.domain == NSPOSIXErrorDomain {
            switch Int32(systemError.code) {
            case EACCES, EPERM:
                return HelperError("macOS denied the privileged helper permission to manage the tunnel. Reinstall Teleport's helper with administrator approval, then reconnect.")
            case ENOSPC, EDQUOT:
                return HelperError("The disk is full, so the helper cannot save its tunnel files. Free disk space and connect again.")
            case ENOENT:
                return HelperError("A file required by Teleport's helper is missing. Reinstall Teleport, then connect again to restore the helper files.")
            case EADDRINUSE:
                return HelperError("A local proxy port is already in use. Close the app using it, or change Teleport's local proxy ports in Settings → Nerd Shit.")
            case ENETUNREACH, EHOSTUNREACH, ENETDOWN:
                return HelperError("The helper cannot reach the physical network. Reconnect to Wi-Fi or Ethernet, then connect again.")
            case EIO:
                return HelperError("macOS reported an input/output error while the helper was preparing the tunnel. Restart your Mac, then connect again.")
            default:
                return HelperError("macOS refused a tunnel operation (system error \(systemError.code)). Restart your Mac and reconnect; if it repeats, report this error number.")
            }
        }
        if systemError.domain == NSCocoaErrorDomain {
            switch systemError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return HelperError("macOS denied access to Teleport's managed files. Reinstall Teleport's helper with administrator approval, then reconnect.")
            case NSFileWriteOutOfSpaceError:
                return HelperError("The disk is full, so the helper cannot save its tunnel files. Free disk space and connect again.")
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return HelperError("A file required by Teleport's helper is missing. Reinstall Teleport, then connect again to restore the helper files.")
            default:
                return HelperError("macOS could not access a file required by the tunnel (file error \(systemError.code)). Reinstall Teleport and reconnect; if it repeats, report this error number.")
            }
        }
        return nil
    }
}
