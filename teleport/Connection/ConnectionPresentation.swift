import Foundation

/// Compatibility projection for existing views while lifecycle ownership moves to
/// one provider state. No view may independently mutate these phase values.
struct ConnectionPresentation: Equatable {
    let connectionPhase: ConnectionPhase
    let proxyPhase: ProxyPhase

    init(connectionPhase: ConnectionPhase, proxyPhase: ProxyPhase) {
        self.connectionPhase = connectionPhase
        self.proxyPhase = proxyPhase
    }

    init(state: ConnectionState, hasConfiguration: Bool) {
        switch state {
        case .idle:
            connectionPhase = hasConfiguration ? .stopped : .unconfigured
            proxyPhase = .disabled
        case .preparing, .awaitingUserApproval, .connecting:
            connectionPhase = .starting
            proxyPhase = .enabling
        case .connected:
            connectionPhase = .running
            proxyPhase = .enabled
        case .disconnecting:
            connectionPhase = .stopping
            proxyPhase = .disabling
        case .failed:
            connectionPhase = .failed
            proxyPhase = .failed
        }
    }

    var canConnect: Bool {
        switch connectionPhase {
        case .unconfigured, .starting, .running, .stopping:
            return false
        case .ready, .stopped, .failed:
            return true
        }
    }

    var canDisconnect: Bool {
        switch connectionPhase {
        case .starting, .running, .stopping, .failed:
            return true
        case .unconfigured, .ready, .stopped:
            return proxyPhase != .disabled
        }
    }

    var canChangeSelection: Bool {
        switch connectionPhase {
        case .starting, .running, .stopping, .failed:
            return false
        case .unconfigured, .ready, .stopped:
            return proxyPhase == .disabled
        }
    }

    var hasActiveConnectionSession: Bool {
        switch connectionPhase {
        case .starting, .running, .stopping, .failed:
            return true
        case .unconfigured, .ready, .stopped:
            return proxyPhase != .disabled
        }
    }

    var isConnected: Bool {
        connectionPhase == .running && proxyPhase == .enabled
    }
}
