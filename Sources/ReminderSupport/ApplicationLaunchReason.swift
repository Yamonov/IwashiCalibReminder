import AppKit
import CoreServices

public enum ApplicationLaunchReason: String, Sendable {
    case regular, loginItem

    /// Call during applicationDidFinishLaunching, while the launch event is current.
    @MainActor public static func detect(_ event: NSAppleEventDescriptor?) -> Self {
        event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            ? .loginItem : .regular
    }
}

public struct RefreshTiming: Sendable {
    public var wake: Duration
    public var login: Duration
    public var retries: [Duration]

    public init(wake: Duration = .seconds(15), login: Duration = .seconds(30),
                retries: [Duration] = [.seconds(10), .seconds(30), .seconds(60)]) {
        self.wake = wake
        self.login = login
        self.retries = retries
    }
}
