import Foundation

let dispatcher = HelperCommandDispatcher(executor: XrayTunController())
let delegate = HelperXPCListenerDelegate(dispatcher: dispatcher)
let listener = NSXPCListener(machServiceName: VPNHelperProtocol.machServiceName)
listener.delegate = delegate
listener.resume()
withExtendedLifetime(delegate) {
    RunLoop.current.run()
}
