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
    private let automaticChecks = NSButton(checkboxWithTitle: "アップデートを自動的に確認", target: nil, action: nil)
    private let checkUpdates = NSButton(title: "アップデートを確認…", target: nil, action: nil)
    private var validationMessage: String?

    init(preferences: ReminderPreferences, notifier: ReminderNotifier, updater: AppUpdater) {
        self.preferences = preferences
        self.notifier = notifier
        self.updater = updater
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "環境設定 — IwashiCalibReminder"
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureControls()
        window.contentView = makeContentView()
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
        threshold.setAccessibilityLabel("通知する残り時間")
        unit.addItems(withTitles: ReminderUnit.allCases.map(\.title))
        unit.selectItem(at: preferences.unit == .hours ? 0 : 1)
        unit.target = self
        unit.action = #selector(unitChanged(_:))
        unit.setAccessibilityLabel("単位")
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        automaticChecks.target = self
        automaticChecks.action = #selector(automaticChecksChanged(_:))
        checkUpdates.target = self
        checkUpdates.action = #selector(checkForUpdates(_:))
        checkUpdates.bezelStyle = .rounded
    }

    private func makeContentView() -> NSView {
        let input = NSStackView(views: [threshold, NSTextField(labelWithString: ":"), unit])
        input.orientation = .horizontal
        input.alignment = .centerY
        input.spacing = 6
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "以下で通知する："), input]
        ])
        grid.xPlacement = .leading
        grid.yPlacement = .center
        grid.rowSpacing = 16
        grid.columnSpacing = 12
        let separator = NSBox()
        separator.boxType = .separator
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 210))
        for view in [grid, separator, automaticChecks, checkUpdates, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            threshold.widthAnchor.constraint(equalToConstant: 76),
            unit.widthAnchor.constraint(equalToConstant: 68),
            separator.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            automaticChecks.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            automaticChecks.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            checkUpdates.topAnchor.constraint(equalTo: automaticChecks.bottomAnchor, constant: 10),
            checkUpdates.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            message.topAnchor.constraint(equalTo: checkUpdates.bottomAnchor, constant: 12),
            message.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        ])
        return content
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

    private func updateMessage() { message.stringValue = validationMessage ?? updater.startupFailure ?? notifier.notice ?? "" }

    @objc private func automaticChecksChanged(_ sender: NSButton) {
        updater.setAutomaticallyChecksForUpdates(sender.state == .on)
    }

    @objc private func checkForUpdates(_ sender: NSButton) { updater.checkForUpdates() }

    func controlTextDidChange(_ notification: Notification) { saveThreshold() }
    @objc private func unitChanged(_ sender: NSPopUpButton) { saveThreshold() }

    private func saveThreshold() {
        let text = threshold.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedUnit: ReminderUnit = unit.indexOfSelectedItem == 0 ? .hours : .days
        if let value = Double(text), preferences.setThreshold(value: value, unit: selectedUnit) {
            validationMessage = nil
        } else {
            validationMessage = text.isEmpty ? nil : "0以上の数値を入力してください。"
            unit.selectItem(at: preferences.unit == .hours ? 0 : 1)
        }
        updateMessage()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
