import Darwin
import Foundation

// A client may time out and close its socket while a root command is still running.
// Ignoring SIGPIPE turns the later response write into EPIPE instead of terminating
// the long-lived helper process.
signal(SIGPIPE, SIG_IGN)
do {
    try HelperServer().run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("\(helperLabel): \(message)\n", stderr)
    exit(1)
}
