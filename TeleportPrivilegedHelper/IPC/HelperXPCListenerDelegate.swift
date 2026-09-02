import Foundation

nonisolated final class HelperXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let authenticator: ClientAuthenticator
    private let service: HelperXPCService

    init(
        dispatcher: any HelperCommandDispatching,
        authenticator: ClientAuthenticator = ClientAuthenticator()
    ) {
        self.authenticator = authenticator
        service = HelperXPCService(dispatcher: dispatcher)
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard authenticator.configureAndAuthorize(connection) else {
            return false
        }

        let interface = NSXPCInterface(with: VPNHelperXPCProtocol.self)
        Self.configureAllowedClasses(on: interface)
        connection.exportedInterface = interface
        connection.exportedObject = service
        connection.activate()
        return true
    }

    private static func configureAllowedClasses(on interface: NSXPCInterface) {
        let dataClasses = NSSet(object: NSData.self) as! Set<AnyHashable>
        let errorClasses = NSSet(object: NSError.self) as! Set<AnyHashable>
        let methods = [
            #selector(VPNHelperXPCProtocol.getStatus(_:withReply:)),
            #selector(VPNHelperXPCProtocol.startSession(_:withReply:)),
            #selector(VPNHelperXPCProtocol.stopSession(_:withReply:)),
            #selector(VPNHelperXPCProtocol.readDiagnostics(_:withReply:))
        ]

        for method in methods {
            interface.setClasses(dataClasses, for: method, argumentIndex: 0, ofReply: false)
            interface.setClasses(dataClasses, for: method, argumentIndex: 0, ofReply: true)
            interface.setClasses(errorClasses, for: method, argumentIndex: 1, ofReply: true)
        }
    }
}
