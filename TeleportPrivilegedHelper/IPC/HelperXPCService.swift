import Foundation

protocol HelperCommandDispatching: Sendable {
    func dispatch(command: TUNHelperCommand, requestData: Data) async -> Data
}

extension HelperCommandDispatcher: HelperCommandDispatching {}

nonisolated final class HelperXPCService: NSObject, TUNHelperXPCProtocol {
    static let errorDomain = "dev.x.teleport.helper.xpc"

    private let dispatcher: any HelperCommandDispatching

    init(dispatcher: any HelperCommandDispatching) {
        self.dispatcher = dispatcher
        super.init()
    }

    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        dispatch(.status, request: request, reply: reply)
    }

    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        dispatch(.startSession, request: request, reply: reply)
    }

    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        dispatch(.stopSession, request: request, reply: reply)
    }

    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        dispatch(.readDiagnostics, request: request, reply: reply)
    }

    func engageLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        dispatch(.engageLeakGuard, request: request, reply: reply)
    }

    func releaseLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        dispatch(.releaseLeakGuard, request: request, reply: reply)
    }

    private func dispatch(
        _ command: TUNHelperCommand,
        request: Data,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        Task { [dispatcher] in
            let response = await dispatcher.dispatch(command: command, requestData: request)
            guard response.count <= TUNHelperProtocol.maximumResponseBytes else {
                reply(
                    nil,
                    NSError(
                        domain: Self.errorDomain,
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "The privileged helper response exceeds the protocol limit"
                        ]
                    )
                )
                return
            }
            reply(response, nil)
        }
    }
}
