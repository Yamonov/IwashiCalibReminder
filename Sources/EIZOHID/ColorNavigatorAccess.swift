import AppKit
import Foundation

public struct ColorNavigatorProcessState: Codable, Sendable {
    public let processID: Int32
    public let activationPolicy: Int
}

public struct ColorNavigatorAccessCheck: Codable, Sendable {
    public let state: String
    public let allowsMonitorAccess: Bool
    public let processes: [ColorNavigatorProcessState]
    public let message: String

    public var denial: AcquisitionFailure? {
        guard !allowsMonitorAccess else { return nil }
        return AcquisitionFailure(state == "interfaceRunning" ? .cnInUse : .cnStateUnknown,
                                  detail: message, operation: "checkCN")
    }
}

public enum ColorNavigatorAccess {
    /// CN's QtWebKitBridge switches to foreground application mode when a UI window is
    /// opened, and background application mode when all UI windows are closed.
    /// Checking this process state also catches UI windows hidden behind other apps.
    public static func check() -> ColorNavigatorAccessCheck {
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.eizo.ColorNavigator7")
            .filter { !$0.isTerminated }
            .map { ColorNavigatorProcessState(processID: $0.processIdentifier, activationPolicy: $0.activationPolicy.rawValue) }
        return evaluate(processes)
    }

    static func evaluate(_ processes: [ColorNavigatorProcessState]) -> ColorNavigatorAccessCheck {
        if processes.isEmpty {
            return ColorNavigatorAccessCheck(state: "notRunning", allowsMonitorAccess: true, processes: [],
                                             message: "ColorNavigator 7 is not running.")
        }
        if processes.contains(where: { $0.activationPolicy == NSApplication.ActivationPolicy.regular.rawValue }) {
            return ColorNavigatorAccessCheck(state: "interfaceRunning", allowsMonitorAccess: false, processes: processes,
                                             message: "ColorNavigator 7 is in application mode. Close its application windows before reading the monitor; its Agent may remain running.")
        }
        let agentPolicies = [NSApplication.ActivationPolicy.accessory.rawValue, NSApplication.ActivationPolicy.prohibited.rawValue]
        guard processes.allSatisfy({ agentPolicies.contains($0.activationPolicy) }) else {
            return ColorNavigatorAccessCheck(state: "unknown", allowsMonitorAccess: false, processes: processes,
                                             message: "Cannot determine whether ColorNavigator 7 is in application or Agent mode.")
        }
        return ColorNavigatorAccessCheck(state: "agentOnly", allowsMonitorAccess: true, processes: processes,
                                         message: "Only ColorNavigator 7's Agent/background mode is running. Monitor access is allowed.")
    }
}
