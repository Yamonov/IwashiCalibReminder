import Darwin
import Foundation

// This phase runs once per app build, before ProcessInfoPlistFile and code signing.
// The counter lives outside DerivedData, so Clean does not reset it. Failed builds
// also consume a number. A shared file lock protects simultaneous build invocations.
do {
    let env = ProcessInfo.processInfo.environment
    guard let sourceRoot = env["SRCROOT"], let derivedDirectory = env["DERIVED_FILE_DIR"] else {
        throw NSError(domain: "BuildNumber", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing Xcode build paths"])
    }
    let root = URL(fileURLWithPath: sourceRoot)
    let metadata = root.appendingPathComponent("BuildMetadata")
    let descriptor = open(metadata.appendingPathComponent(".build-number.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { flock(descriptor, LOCK_UN) }
    let counter = metadata.appendingPathComponent("BuildNumber.xcconfig")
    let source = try String(contentsOf: counter, encoding: .utf8)
    guard let previous = Int(source.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
          previous >= 0, previous < Int.max else {
        throw NSError(domain: "BuildNumber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid persistent build number"])
    }
    let next = previous + 1
    let infoData = try Data(contentsOf: root.appendingPathComponent("Config/AppInfo.plist"))
    guard var info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
        throw NSError(domain: "BuildNumber", code: 3)
    }
    info["CFBundleVersion"] = String(next)
    let output = URL(fileURLWithPath: derivedDirectory).appendingPathComponent("IwashiCalibReminder-Info.plist")
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "CURRENT_PROJECT_VERSION = \(next)\n".write(to: counter, atomically: true, encoding: .utf8)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: output, options: .atomic)
    print("IwashiCalibReminder build number: \(previous) → \(next)")
} catch {
    FileHandle.standardError.write(Data("error: Build number update failed: \(error)\n".utf8))
    exit(1)
}
