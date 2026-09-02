import Foundation

@main
struct VerifyConnectionProvider {
    static func main() async throws {
        testConnectionPresentationMapping()
        print("verify_connection_provider: all checks passed")
    }

    private static func testConnectionPresentationMapping() {
        precondition(
            ConnectionPresentation(state: .idle, hasConfiguration: false)
                == ConnectionPresentation(connectionPhase: .unconfigured, proxyPhase: .disabled)
        )
        precondition(
            ConnectionPresentation(state: .idle, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .stopped, proxyPhase: .disabled)
        )
        precondition(
            ConnectionPresentation(state: .preparing, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        precondition(
            ConnectionPresentation(state: .awaitingUserApproval, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        precondition(
            ConnectionPresentation(state: .connecting, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        precondition(
            ConnectionPresentation(
                state: .connected(.init(id: UUID(), mode: .vpn, connectedAt: Date())),
                hasConfiguration: true
            ) == ConnectionPresentation(connectionPhase: .running, proxyPhase: .enabled)
        )
        precondition(
            ConnectionPresentation(state: .disconnecting, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .stopping, proxyPhase: .disabling)
        )
        precondition(
            ConnectionPresentation(
                state: .failed(.init(summary: "failed", details: nil)),
                hasConfiguration: true
            ) == ConnectionPresentation(connectionPhase: .failed, proxyPhase: .failed)
        )
    }
}
