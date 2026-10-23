import AppKit
import Observation
import os
import Sparkle

/// Sparkle owns the persisted preference and update schedule. Menu presentation
/// observes this small state without starting an update check.
@Observable @MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var automaticallyChecksForUpdates = false
    private(set) var canCheckForUpdates = false
    private(set) var updateAvailable = false
    private(set) var startupFailure: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.iwashiya.IwashiCalibReminder", category: "Updater")

    override init() {
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.synchronizeSettings() }
            },
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.synchronizeSettings() }
            }
        ]
        synchronizeSettings()
    }

    var isAvailable: Bool { controller != nil && startupFailure == nil }

    func start() {
        guard !started, let controller else { return }
        do {
            try controller.updater.start()
            started = true
        } catch {
            startupFailure = String(localized: "Unable to start the updater")
            logger.error("Updater startup failed: \(error.localizedDescription, privacy: .public)")
        }
        synchronizeSettings()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let controller else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        synchronizeSettings()
    }

    func checkForUpdates() {
        start()
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    private func synchronizeSettings() {
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
        canCheckForUpdates = isAvailable && (!started || (controller?.updater.canCheckForUpdates ?? false))
    }

    // Sparkle's standard user driver delivers these callbacks on the main thread.
    // Its Objective-C delegate protocol does not yet carry an actor annotation.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        updateAvailable = true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        logger.info("Update available: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        updateAvailable = false
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .dismiss: updateAvailable = true
        case .install, .skip: updateAvailable = false
        @unknown default: break
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) {
            updateAvailable = false
        } else {
            // A transient network failure must not erase a known update reminder.
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
