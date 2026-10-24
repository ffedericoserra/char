import AppKit

private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class FontSettingsController: NSWindowController {
    private let family = NSPopUpButton()
    private let secondaryFamily = NSPopUpButton()
    private let size = NSPopUpButton()

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let names = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for (popup, label) in [(family, "Primary note font family"), (secondaryFamily, "Secondary note font family")] {
            popup.addItem(withTitle: "System default")
            popup.lastItem?.representedObject = ""
            popup.addItem(withTitle: "System monospace")
            popup.lastItem?.representedObject = EditorSession.systemMonospaceFamily
            popup.menu?.addItem(.separator())
            for name in names {
                popup.addItem(withTitle: name)
                popup.lastItem?.representedObject = name
            }
            popup.widthAnchor.constraint(equalToConstant: 260).isActive = true
            popup.target = self
            popup.action = #selector(changeFamily)
            popup.setAccessibilityLabel(label)
        }
        for value in Int(EditorMetrics.minimumFontSize)...Int(EditorMetrics.maximumFontSize) {
            size.addItem(withTitle: "\(value) pt")
            size.lastItem?.tag = value
        }
        size.target = self
        size.action = #selector(changeSize)
        size.setAccessibilityLabel("Note font size")
        let hint = NSTextField(labelWithString: "Press ⌘⇧M to switch between the primary and secondary font.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        let rows = NSStackView(views: [
            row("Primary font", family), row("Secondary font", secondaryFamily), row("Font size", size), hint, restore
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 18
        rows.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            rows.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            rows.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: EditorSession.fontDidChange, object: nil)
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 12
        return row
    }

    @objc private func refresh() {
        for (popup, name) in [(family, EditorSession.fontFamily), (secondaryFamily, EditorSession.secondaryFontFamily)] {
            popup.selectItem(at: popup.itemArray.firstIndex { $0.representedObject as? String == name } ?? 0)
        }
        size.selectItem(withTag: Int(EditorSession.fontSize))
    }

    @objc private func changeFamily(_ sender: NSPopUpButton) {
        let name = sender.selectedItem?.representedObject as? String ?? ""
        if sender === secondaryFamily { EditorSession.secondaryFontFamily = name }
        else { EditorSession.fontFamily = name }
    }
    @objc private func changeSize() { EditorSession.fontSize = CGFloat(size.selectedItem?.tag ?? 14) }
    @objc private func restoreDefaults() { EditorSession.restoreDefaults() }
}
