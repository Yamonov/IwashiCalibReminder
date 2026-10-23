import AppKit
import Observation
import ReminderSupport

/// Native controls are created only while this window is in use. Closing
/// it releases the controller and its views; only the saved preferences survive.
@MainActor
final class ReminderPreferencesController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    private let preferences: ReminderPreferences
    private let notifier: ReminderNotifier
    private let updater: AppUpdater
    private let loginItem: LoginItemController
    private let threshold = NSTextField(string: "")
    private let unit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionAction = NSButton(title: "", target: nil, action: nil)
    private let automaticChecks = NSButton(checkboxWithTitle: L10n.text("Automatically check for updates"), target: nil, action: nil)
    private let checkUpdates = NSButton(title: L10n.text("Check for updates"), target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: L10n.text("Launch at login"), target: nil, action: nil)
    private let loginSettings = NSButton(title: L10n.text("Open System Settings…"), target: nil, action: nil)
    private let unitOptions: [ReminderUnit] = [.days, .hours]
    private var validationMessage: String?
    private var preferredContentWidth: CGFloat = 370
    private var normalContentHeight: CGFloat = 110
    private let before = NSTextField(labelWithString: L10n.text("Notify with"))
    private let after = NSTextField(labelWithString: L10n.text("remaining"))
    private let separator = NSBox()
    private var notificationHeight: CGFloat = 24
    private var permissionHeight: CGFloat = 28
    private var permissionLabelWidth: CGFloat = 0
    private var updatesHeight: CGFloat = 28
    private var loginHeight: CGFloat = 24
    private var unitWidth: CGFloat = 68

    init(preferences: ReminderPreferences, notifier: ReminderNotifier, updater: AppUpdater,
         loginItem: LoginItemController) {
        self.preferences = preferences
        self.notifier = notifier
        self.updater = updater
        self.loginItem = loginItem
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.text("Settings — IwashiCalibReminder")
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureControls()
        window.contentView = makeContentView()
        resizeToContent()
        window.center()
        observeChanges()
    }

    required init?(coder: NSCoder) { nil }

    private func configureControls() {
        threshold.stringValue = preferences.thresholdValue.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never))
        threshold.placeholderString = "24"
        threshold.bezelStyle = .roundedBezel
        threshold.delegate = self
        threshold.setAccessibilityLabel(L10n.text("Remaining time before notification"))
        unit.addItems(withTitles: unitOptions.map(\.title))
        unit.selectItem(at: preferences.unit == .days ? 0 : 1)
        unit.target = self
        unit.action = #selector(unitChanged(_:))
        unit.setAccessibilityLabel(L10n.text("Unit"))
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        permissionAction.target = self
        permissionAction.action = #selector(notificationPermissionAction(_:))
        permissionAction.bezelStyle = .rounded
        automaticChecks.target = self
        automaticChecks.action = #selector(automaticChecksChanged(_:))
        checkUpdates.target = self
        checkUpdates.action = #selector(checkForUpdates(_:))
        checkUpdates.bezelStyle = .rounded
        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged(_:))
        loginSettings.target = self
        loginSettings.action = #selector(openLoginSettings(_:))
        loginSettings.bezelStyle = .rounded
    }

    private func makeContentView() -> NSView {
        let controls: [NSControl] = [before, threshold, unit, after, permissionStatus, permissionAction,
            launchAtLogin, loginSettings, automaticChecks, checkUpdates]
        for title in ["Notifications: Checking…", "Notifications: Not requested", "Notifications: Not allowed",
                      "Notifications: Allowed", "Notifications: Delivered quietly", "Notifications: Unavailable"] {
            permissionStatus.stringValue = L10n.text(title)
            permissionStatus.sizeToFit()
            permissionLabelWidth = max(permissionLabelWidth, permissionStatus.frame.width)
        }
        var permissionButtonWidth: CGFloat = 0
        for title in ["Allow notifications…", "Notification settings…", "Check again"] {
            permissionAction.title = L10n.text(title)
            permissionAction.sizeToFit()
            permissionButtonWidth = max(permissionButtonWidth, permissionAction.frame.width)
        }
        permissionStatus.stringValue = notifier.permissionStatusText
        permissionAction.title = notifier.permissionActionTitle
        controls.forEach { $0.sizeToFit() }
        threshold.setFrameSize(NSSize(width: 64, height: max(22, threshold.frame.height)))
        unitWidth = max(68, ceil(unit.frame.width))
        unit.setFrameSize(NSSize(width: unitWidth, height: max(24, unit.frame.height)))
        let notificationWidth = before.frame.width + 64 + unitWidth + after.frame.width + 24
        let updatesWidth = automaticChecks.frame.width + checkUpdates.frame.width + 12
        notificationHeight = max(24, threshold.frame.height, unit.frame.height)
        permissionHeight = max(28, permissionStatus.frame.height, permissionAction.frame.height)
        updatesHeight = max(28, automaticChecks.frame.height, checkUpdates.frame.height)
        loginHeight = max(24, launchAtLogin.frame.height, loginSettings.frame.height)
        let loginWidth = launchAtLogin.frame.width + loginSettings.frame.width + 12
        let permissionWidth = permissionLabelWidth + 12 + permissionButtonWidth
        preferredContentWidth = ceil(max(notificationWidth, permissionWidth, updatesWidth, loginWidth) + 40)
        normalContentHeight = ceil(32 + notificationHeight + 8 + permissionHeight + 12 + 1 + 12 + loginHeight + 8 + updatesHeight)
        separator.boxType = .separator
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        message.cell?.truncatesLastVisibleLine = true
        message.preferredMaxLayoutWidth = preferredContentWidth - 40
        message.isHidden = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: preferredContentWidth, height: normalContentHeight))
        content.autoresizesSubviews = false
        for view in controls + [message] { content.addSubview(view) }
        content.addSubview(separator)
        return content
    }

    private func resizeToContent() {
        guard let content = window?.contentView else { return }
        let textHeight: CGFloat
        if message.stringValue.isEmpty { textHeight = 0 }
        else {
            let measured = message.sizeThatFits(NSSize(width: preferredContentWidth - 40, height: .greatestFiniteMagnitude))
            textHeight = max(17, ceil(measured.height))
        }
        let height = normalContentHeight + (textHeight > 0 ? textHeight + 10 : 0)
        window?.setContentSize(NSSize(width: preferredContentWidth, height: height))
        let topRowY = height - 16 - notificationHeight
        var x: CGFloat = 20
        for control in [before, threshold, unit, after] {
            control.setFrameOrigin(NSPoint(x: x, y: topRowY + (notificationHeight - control.frame.height) / 2))
            x += control.frame.width + 8
        }
        let permissionY = topRowY - 8 - permissionHeight
        permissionStatus.frame = NSRect(x: 20, y: permissionY + (permissionHeight - permissionStatus.frame.height) / 2,
            width: permissionLabelWidth, height: permissionStatus.frame.height)
        permissionAction.setFrameOrigin(NSPoint(x: 32 + permissionLabelWidth,
            y: permissionY + (permissionHeight - permissionAction.frame.height) / 2))
        separator.frame = NSRect(x: 20, y: permissionY - 13, width: preferredContentWidth - 40, height: 1)
        let loginY = permissionY - 25 - loginHeight
        launchAtLogin.setFrameOrigin(NSPoint(x: 20, y: loginY + (loginHeight - launchAtLogin.frame.height) / 2))
        loginSettings.setFrameOrigin(NSPoint(x: 32 + launchAtLogin.frame.width,
            y: loginY + (loginHeight - loginSettings.frame.height) / 2))
        let updatesY = loginY - 8 - updatesHeight
        automaticChecks.setFrameOrigin(NSPoint(x: 20, y: updatesY + (updatesHeight - automaticChecks.frame.height) / 2))
        checkUpdates.setFrameOrigin(NSPoint(x: 32 + automaticChecks.frame.width,
            y: updatesY + (updatesHeight - checkUpdates.frame.height) / 2))
        message.frame = NSRect(x: 20, y: updatesY - 10 - textHeight, width: preferredContentWidth - 40, height: textHeight)
        content.needsDisplay = true
    }

    private func observeChanges() {
        withObservationTracking {
            _ = notifier.settingsNotice
            _ = updater.startupFailure
            permissionStatus.stringValue = notifier.permissionStatusText
            permissionAction.title = notifier.permissionActionTitle
            permissionAction.isEnabled = !notifier.isBusy
            permissionAction.sizeToFit()
            launchAtLogin.state = loginItem.isEnabled ? .on : .off
            loginSettings.isHidden = !loginItem.requiresApproval
            automaticChecks.state = updater.automaticallyChecksForUpdates ? .on : .off
            automaticChecks.isEnabled = updater.isAvailable
            checkUpdates.isEnabled = updater.canCheckForUpdates
            updateMessage()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChanges() }
        }
    }

    private func updateMessage() {
        message.stringValue = validationMessage ?? loginItem.notice ?? updater.startupFailure ?? notifier.settingsNotice ?? ""
        message.isHidden = message.stringValue.isEmpty
        resizeToContent()
    }

    @objc private func automaticChecksChanged(_ sender: NSButton) {
        updater.setAutomaticallyChecksForUpdates(sender.state == .on)
    }

    @objc private func checkForUpdates(_ sender: NSButton) { updater.checkForUpdates() }
    @objc private func notificationPermissionAction(_ sender: NSButton) { notifier.performPermissionAction() }
    @objc private func launchAtLoginChanged(_ sender: NSButton) { loginItem.setEnabled(sender.state == .on) }
    @objc private func openLoginSettings(_ sender: NSButton) { loginItem.openSettings() }

    func windowDidBecomeKey(_ notification: Notification) {
        loginItem.refresh()
        notifier.checkAuthorization()
    }

    func controlTextDidChange(_ notification: Notification) { saveThreshold() }
    @objc private func unitChanged(_ sender: NSPopUpButton) { saveThreshold() }

    private func saveThreshold() {
        let text = threshold.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedUnit: ReminderUnit = unit.indexOfSelectedItem == 0 ? .days : .hours
        if let value = Double(text), preferences.setThreshold(value: value, unit: selectedUnit) {
            validationMessage = nil
        } else {
            validationMessage = text.isEmpty ? nil : L10n.text("Enter a number greater than or equal to zero.")
            unit.selectItem(at: preferences.unit == .days ? 0 : 1)
        }
        updateMessage()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
