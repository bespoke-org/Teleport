import Darwin
import Foundation

let controller = XrayTunController()
do { try controller.restoreLeakGuard() }
catch {
    fputs("Teleport could not restore persistent protection; status and explicit release remain available.\n", stderr)
}
let dispatcher = HelperCommandDispatcher(executor: controller)
let delegate = HelperXPCListenerDelegate(dispatcher: dispatcher)
let listener = NSXPCListener(machServiceName: TUNHelperProtocol.machServiceName)
listener.delegate = delegate
listener.resume()
withExtendedLifetime(delegate) {
    RunLoop.current.run()
}
fputs("\(helperLabel): XPC listener run loop exited unexpectedly\n", stderr)
exit(1)
