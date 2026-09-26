import Foundation

struct ReferenceModeSafetyPolicy: Equatable {
    let bootGracePeriod: TimeInterval
    let coldLaunchDelay: TimeInterval
    let postSwitchCooldown: TimeInterval
    let displayStableDelay: TimeInterval
    let systemEventGracePeriod: TimeInterval
    let verificationFallbackDelay: TimeInterval
    let displayReconfigurationTimeout: TimeInterval

    static let standard = ReferenceModeSafetyPolicy(
        bootGracePeriod: 120,
        coldLaunchDelay: 10,
        postSwitchCooldown: 3,
        displayStableDelay: 1,
        systemEventGracePeriod: 5,
        verificationFallbackDelay: 2,
        displayReconfigurationTimeout: 15
    )

    func requiredDelay(
        debounce: TimeInterval,
        systemUptime: TimeInterval,
        launchUptime: TimeInterval?,
        lastSwitchUptime: TimeInterval?,
        lastDisplayChangeUptime: TimeInterval?,
        systemEventUptime: TimeInterval?
    ) -> TimeInterval {
        var delays = [
            max(0, debounce),
            max(0, bootGracePeriod - systemUptime)
        ]

        if let launchUptime {
            delays.append(max(0, coldLaunchDelay - (systemUptime - launchUptime)))
        }
        if let lastSwitchUptime {
            delays.append(max(0, postSwitchCooldown - (systemUptime - lastSwitchUptime)))
        }
        if let lastDisplayChangeUptime {
            delays.append(max(0, displayStableDelay - (systemUptime - lastDisplayChangeUptime)))
        }
        if let systemEventUptime {
            delays.append(max(0, systemEventGracePeriod - (systemUptime - systemEventUptime)))
        }

        return delays.max() ?? 0
    }

    func bootGraceRemainingSeconds(systemUptime: TimeInterval) -> Int {
        Int(ceil(max(0, bootGracePeriod - systemUptime)))
    }
}

enum ReferenceModeAutomationStatus: String, Equatable {
    case waitingForSystemStartup = "Waiting for system startup"
    case waitingForApplicationInitialization = "Waiting for application initialization"
    case waitingForDisplayStabilization = "Waiting for display stabilization"
    case coolingDown = "Cooling down after display switch"
    case ready = "Ready"
    case switching = "Switching"
    case paused = "Paused"
}
