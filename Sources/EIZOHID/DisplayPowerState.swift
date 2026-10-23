import CoreGraphics

/// Reads WindowServer's existing state. This never opens a display or sends HID.
public enum DisplayPowerState: String, Sendable {
    case awake, asleep, unavailable

    public static func current() -> Self {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return .unavailable }
        // An empty list during reconnection is not proof of display sleep.
        guard count > 0, count <= 128 else { return .unavailable }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let capacity = count
        let result = displays.withUnsafeMutableBufferPointer {
            CGGetOnlineDisplayList(capacity, $0.baseAddress, &count)
        }
        guard result == .success, count > 0, Int(count) <= displays.count else { return .unavailable }
        return displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 } ? .awake : .asleep
    }

    public var denial: AcquisitionFailure? {
        switch self {
        case .awake: nil
        case .asleep:
            AcquisitionFailure(.displayAsleep, detail: "Displays are asleep; monitor reading is suspended.", operation: "checkDisplayPower")
        case .unavailable:
            AcquisitionFailure(.displayStateUnknown, detail: "The display power state is unavailable; monitor reading was not started.", operation: "checkDisplayPower")
        }
    }
}
