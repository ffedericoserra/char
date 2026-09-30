import AppKit

private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class FontSettingsController: NSWindowController {
    private let family = NSPopUpButton()
    private let size = NSPopUpButton()
    private let mono = NSButton(checkboxWithTitle: "Use system monospace (⌘⇧M)", target: nil, action: nil)

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        family.addItem(withTitle: "System default")
        for name in NSFontManager.shared.availableFontFamilies.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            family.addItem(withTitle: name)
            family.lastItem?.representedObject = name
        }
        family.widthAnchor.constraint(equalToConstant: 260).isActive = true
        family.target = self
        family.action = #selector(changeFamily)
        family.setAccessibilityLabel("Note font family")
        for value in Int(EditorMetrics.minimumFontSize)...Int(EditorMetrics.maximumFontSize) {
            size.addItem(withTitle: "\(value) pt")
            size.lastItem?.tag = value
        }
        size.target = self
        size.action = #selector(changeSize)
        size.setAccessibilityLabel("Note font size")
        mono.target = self
        mono.action = #selector(changeMonospace)
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        let rows = NSStackView(views: [
            row("Font family", family), row("Font size", size), mono, restore
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
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 12
        return row
    }

    @objc private func refresh() {
        family.selectItem(at: family.itemArray.firstIndex { ($0.representedObject as? String ?? "") == EditorSession.fontFamily } ?? 0)
        size.selectItem(withTag: Int(EditorSession.fontSize))
        mono.isEnabled = EditorSession.fontFamily.isEmpty
        mono.state = EditorSession.systemMonospace ? .on : .off
    }

    @objc private func changeFamily() {
        EditorSession.fontFamily = family.selectedItem?.representedObject as? String ?? ""
    }
    @objc private func changeSize() { EditorSession.fontSize = CGFloat(size.selectedItem?.tag ?? 14) }
    @objc private func changeMonospace() { EditorSession.toggleSystemMonospace() }
    @objc private func restoreDefaults() { EditorSession.restoreDefaults() }
}
