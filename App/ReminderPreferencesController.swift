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
    private let threshold = NSTextField(string: "")
    private let unit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let automaticChecks = NSButton(checkboxWithTitle: L10n.text("Automatically check for updates"), target: nil, action: nil)
    private let checkUpdates = NSButton(title: L10n.text("Check for updates"), target: nil, action: nil)
    private let unitOptions: [ReminderUnit] = [.days, .hours]
    private var validationMessage: String?
    private var preferredContentWidth: CGFloat = 370
    private var normalContentHeight: CGFloat = 110
    private let before = NSTextField(labelWithString: L10n.text("Notify with"))
    private let after = NSTextField(labelWithString: L10n.text("remaining"))
    private let separator = NSBox()
    private var notificationHeight: CGFloat = 24
    private var updatesHeight: CGFloat = 28
    private var unitWidth: CGFloat = 68

    init(preferences: ReminderPreferences, notifier: ReminderNotifier, updater: AppUpdater) {
        self.preferences = preferences
        self.notifier = notifier
        self.updater = updater
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
        automaticChecks.target = self
        automaticChecks.action = #selector(automaticChecksChanged(_:))
        checkUpdates.target = self
        checkUpdates.action = #selector(checkForUpdates(_:))
        checkUpdates.bezelStyle = .rounded
    }

    private func makeContentView() -> NSView {
        let controls: [NSControl] = [before, threshold, unit, after, automaticChecks, checkUpdates]
        controls.forEach { $0.sizeToFit() }
        threshold.setFrameSize(NSSize(width: 64, height: max(22, threshold.frame.height)))
        unitWidth = max(68, ceil(unit.frame.width))
        unit.setFrameSize(NSSize(width: unitWidth, height: max(24, unit.frame.height)))
        let notificationWidth = before.frame.width + 64 + unitWidth + after.frame.width + 24
        let updatesWidth = automaticChecks.frame.width + checkUpdates.frame.width + 12
        notificationHeight = max(24, threshold.frame.height, unit.frame.height)
        updatesHeight = max(28, automaticChecks.frame.height, checkUpdates.frame.height)
        preferredContentWidth = ceil(max(notificationWidth, updatesWidth) + 40)
        normalContentHeight = ceil(32 + notificationHeight + 12 + 1 + 12 + updatesHeight)
        separator.boxType = .separator
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byTruncatingTail
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
            let bounds = (message.stringValue as NSString).boundingRect(
                with: NSSize(width: preferredContentWidth - 40, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: message.font ?? NSFont.systemFont(ofSize: 11)])
            textHeight = min(51, max(17, ceil(bounds.height)))
        }
        let height = normalContentHeight + (textHeight > 0 ? textHeight + 10 : 0)
        window?.setContentSize(NSSize(width: preferredContentWidth, height: height))
        let topRowY = height - 16 - notificationHeight
        var x: CGFloat = 20
        for control in [before, threshold, unit, after] {
            control.setFrameOrigin(NSPoint(x: x, y: topRowY + (notificationHeight - control.frame.height) / 2))
            x += control.frame.width + 8
        }
        separator.frame = NSRect(x: 20, y: topRowY - 13, width: preferredContentWidth - 40, height: 1)
        let updatesY = topRowY - 25 - updatesHeight
        automaticChecks.setFrameOrigin(NSPoint(x: 20, y: updatesY + (updatesHeight - automaticChecks.frame.height) / 2))
        checkUpdates.setFrameOrigin(NSPoint(x: 32 + automaticChecks.frame.width,
            y: updatesY + (updatesHeight - checkUpdates.frame.height) / 2))
        message.frame = NSRect(x: 20, y: updatesY - 10 - textHeight, width: preferredContentWidth - 40, height: textHeight)
        content.needsDisplay = true
    }

    private func observeChanges() {
        withObservationTracking {
            _ = notifier.notice
            _ = updater.startupFailure
            automaticChecks.state = updater.automaticallyChecksForUpdates ? .on : .off
            automaticChecks.isEnabled = updater.isAvailable
            checkUpdates.isEnabled = updater.canCheckForUpdates
            updateMessage()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChanges() }
        }
    }

    private func updateMessage() {
        message.stringValue = validationMessage ?? updater.startupFailure ?? notifier.notice ?? ""
        message.isHidden = message.stringValue.isEmpty
        resizeToContent()
    }

    @objc private func automaticChecksChanged(_ sender: NSButton) {
        updater.setAutomaticallyChecksForUpdates(sender.state == .on)
    }

    @objc private func checkForUpdates(_ sender: NSButton) { updater.checkForUpdates() }

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
