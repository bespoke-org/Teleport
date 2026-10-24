import Darwin
import Foundation

let controller = XrayTunController()
// Before the listener accepts anything: a guard this process did not engage was
// engaged by a helper that is gone, and nothing left is going to renew it.
controller.releaseStaleLeakGuard()
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
