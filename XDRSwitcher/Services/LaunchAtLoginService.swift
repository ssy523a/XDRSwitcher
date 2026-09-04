import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    init(serviceStatus: SMAppService.Status) {
        switch serviceStatus {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .notFound
        }
    }

    var isToggleOn: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .notRegistered:
            return "Not Registered"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires Approval"
        case .notFound:
            return "Not Found"
        }
    }

    var approvalMessage: String? {
        guard self == .requiresApproval else {
            return nil
        }

        return "Launch at Login is registered, but macOS requires approval in System Settings > General > Login Items."
    }
}

protocol LaunchAtLoginServicing {
    func currentStatus() -> LaunchAtLoginStatus
    func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginStatus
    func openSystemSettingsLoginItems()
}

struct LaunchAtLoginService: LaunchAtLoginServicing {
    func currentStatus() -> LaunchAtLoginStatus {
        LaunchAtLoginStatus(serviceStatus: SMAppService.mainApp.status)
    }

    func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginStatus {
        let currentStatus = currentStatus()

        if isEnabled {
            if currentStatus == .enabled || currentStatus == .requiresApproval {
                return currentStatus
            }

            try SMAppService.mainApp.register()
        } else {
            if currentStatus == .notRegistered {
                return currentStatus
            }

            try SMAppService.mainApp.unregister()
        }

        return self.currentStatus()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
