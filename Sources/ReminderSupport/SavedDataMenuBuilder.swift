import AppKit
import EIZOHID

/// Owns the weak NSMenu delegates for one displayed snapshot. Large arrays are
/// populated one page at a time, using only the already decoded saved values.
@MainActor
final class SavedDataMenuBuilder {
    private var sources: [JSONMenuSource] = []

    func menu(entries: [(String, CNJSONValue)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let source = JSONMenuSource(entries: entries) { [weak self] children in
            self?.menu(entries: children) ?? NSMenu()
        }
        sources.append(source)
        menu.delegate = source
        // A placeholder gives the native parent row its disclosure arrow before opening.
        menu.addItem(ReadableMenuInformation.item("保存済みの情報を表示"))
        return menu
    }
}

@MainActor
private final class JSONMenuSource: NSObject, NSMenuDelegate {
    private static let pageSize = 64
    private let entries: [(String, CNJSONValue)]
    private let child: ([(String, CNJSONValue)]) -> NSMenu
    private var built = false
    init(entries: [(String, CNJSONValue)], child: @escaping ([(String, CNJSONValue)]) -> NSMenu) {
        self.entries = entries
        self.child = child
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !built else { return }
        built = true
        menu.removeAllItems()
        if entries.count > Self.pageSize {
            for first in stride(from: 0, to: entries.count, by: Self.pageSize) {
                let end = min(first + Self.pageSize, entries.count)
                let item = NSMenuItem(title: "項目 \(first + 1)–\(end)", action: nil, keyEquivalent: "")
                item.submenu = child(Array(entries[first..<end]))
                menu.addItem(item)
            }
            return
        }
        for (name, value) in entries {
            let item = NSMenuItem(title: "\(name)：\(ModeDetailText.scalar(value))", action: nil, keyEquivalent: "")
            if let object = value.object, !object.isEmpty {
                item.submenu = child(object.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            } else if let array = value.array, !array.isEmpty {
                item.submenu = child(array.enumerated().map { (String($0.offset), $0.element) })
            } else {
                menu.addItem(ReadableMenuInformation.item(item.title))
                continue
            }
            item.toolTip = item.title
            menu.addItem(item)
        }
    }
}
