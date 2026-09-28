import AppKit

struct FolderEntry: Sendable {
    let url: URL
    let isDirectory: Bool

    static func contents(of url: URL) throws -> [FolderEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ).compactMap { child in
            let values = try child.resourceValues(forKeys: keys)
            // Don't traverse packages or directory symlinks (which may form cycles).
            if values.isDirectory == true {
                guard values.isPackage != true, values.isSymbolicLink != true else { return nil }
                return FolderEntry(url: child, isDirectory: true)
            }
            guard child.pathExtension.lowercased() == "txt" else { return nil }
            return FolderEntry(url: child, isDirectory: false)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

@MainActor
private final class FolderNode {
    let entry: FolderEntry
    var children: [FolderNode]?
    var loading = false
    init(_ entry: FolderEntry) { self.entry = entry }
}

final class FolderBrowser: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1)
    var onSelectFile: ((URL) -> Void)?
    var onOpenFolder: (() -> Void)?
    private(set) var folderURL: URL?
    private let outline = NSOutlineView()
    private let scroll = SmoothScrollView()
    private let title = NSTextField(labelWithString: "Folder")
    private let message = NSTextField(wrappingLabelWithString: "Open a folder to browse your notes.")
    private let openButton = NSButton(title: "Open Folder…", target: nil, action: nil)
    private var root: FolderNode?
    private var generation = UUID()
    private var expandedURLs = Set<URL>()
    private var selectedURL: URL?
    private var updatingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor

        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityIdentifier("Folder name")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(chooseFolder)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 28
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.backgroundColor = backgroundColor
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Notes in folder")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .dark
        scroll.borderType = .noBorder
        scroll.backgroundColor = backgroundColor
        scroll.drawsBackground = true
        scroll.automaticallyAdjustsContentInsets = false
        [scroll, title, message, openButton].forEach(addSubview)
        updateEmptyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 20, y: bounds.height - 72, width: bounds.width - 40, height: 18)
        scroll.frame = NSRect(x: 8, y: 46, width: bounds.width - 16, height: max(0, bounds.height - 128))
        message.frame = NSRect(x: 24, y: bounds.height - 145, width: bounds.width - 48, height: 50)
        openButton.sizeToFit()
        openButton.setFrameOrigin(NSPoint(x: (bounds.width - openButton.frame.width) / 2,
                                          y: message.frame.minY - openButton.frame.height - 8))
    }

    @objc private func chooseFolder() { onOpenFolder?() }

    func setFolder(_ url: URL) {
        folderURL = url
        title.stringValue = url.lastPathComponent
        title.toolTip = url.path
        expandedURLs.removeAll()
        generation = UUID()
        root = FolderNode(FolderEntry(url: url, isDirectory: true))
        updatingSelection = true
        outline.reloadData()
        updatingSelection = false
        reload()
        updateEmptyState()
    }

    func reload() {
        guard let root else { return }
        // Keep the visible tree alive while reading disk. Emptying it first
        // collapses the document height and forces the clip view to the top.
        load(root, refresh: true)
    }

    func selectFile(_ url: URL?) {
        selectedURL = url?.standardizedFileURL
        restoreSelection()
    }

    func focusSelection() {
        window?.makeFirstResponder(outline)
    }

    func resignFocusIfClickedOutsideRows(at point: NSPoint) {
        guard window?.firstResponder === outline,
              outline.row(at: outline.convert(point, from: nil)) < 0 else { return }
        window?.makeFirstResponder(nil)
    }

    private func restoreSelection() {
        updatingSelection = true
        defer { updatingSelection = false }
        let row = (0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? FolderNode)?.entry.url.standardizedFileURL == selectedURL
        }
        if let row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outline.deselectAll(nil) }
    }

    private func load(_ node: FolderNode, refresh: Bool = false) {
        guard node.entry.isDirectory, (refresh || node.children == nil), !node.loading else { return }
        node.loading = true
        let currentGeneration = generation
        let url = node.entry.url
        Task { [weak self, weak node] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FolderEntry.contents(of: url) }
            }.value
            guard let self, let node, self.generation == currentGeneration else { return }
            node.loading = false
            switch result {
            case .success(let entries):
                let existing = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.entry.url, $0) })
                node.children = entries.map { entry in
                    if let child = existing[entry.url], child.entry.isDirectory == entry.isDirectory {
                        return child
                    }
                    return FolderNode(entry)
                }
            case .failure(let error):
                node.children = []
                NSApp.presentError(error)
            }
            let scrollOrigin = self.scroll.contentView.bounds.origin
            self.updatingSelection = true
            if node === self.root { self.outline.reloadData() }
            else { self.outline.reloadItem(node, reloadChildren: true) }
            for child in node.children ?? [] where self.expandedURLs.contains(child.entry.url) {
                self.outline.expandItem(child)
                if refresh { self.load(child, refresh: true) }
            }
            self.updatingSelection = false
            self.restoreSelection()
            self.outline.layoutSubtreeIfNeeded()
            self.scroll.contentView.scroll(to: scrollOrigin)
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
            self.updateEmptyState()
        }
    }

    private func updateEmptyState() {
        message.isHidden = !(root?.children?.isEmpty ?? true)
        openButton.isHidden = folderURL != nil
        if folderURL == nil { message.stringValue = "Open a folder to browse your notes." }
        else if root?.children == nil { message.stringValue = "Opening folder…" }
        else { message.stringValue = "No text files in this folder yet." }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FolderNode) ?? root else { return 0 }
        load(node)
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FolderNode) ?? root!).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderNode)?.entry.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: node.entry.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(labelWithString: node.entry.url.lastPathComponent)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = node.entry.url.path
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection,
              let node = outline.item(atRow: outline.selectedRow) as? FolderNode,
              !node.entry.isDirectory else { return }
        onSelectFile?(node.entry.url)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
        expandedURLs.insert(node.entry.url)
        // Collapsed folders retain their nodes during a refresh; check disk
        // again when opened so their cached children do not become stale.
        load(node, refresh: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updatingSelection, let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
        expandedURLs.remove(node.entry.url)
    }
}
