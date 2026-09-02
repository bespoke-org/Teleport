import Darwin
import Foundation

let dispatcher = HelperCommandDispatcher(executor: XrayTunController())
let delegate = HelperXPCListenerDelegate(dispatcher: dispatcher)
let listener = NSXPCListener(machServiceName: VPNHelperProtocol.machServiceName)
listener.delegate = delegate
listener.resume()
withExtendedLifetime(delegate) {
    RunLoop.current.run()
}
fputs("\(helperLabel): XPC listener run loop exited unexpectedly\n", stderr)
exit(1)
