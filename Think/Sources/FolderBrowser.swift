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
            if values.isSymbolicLink == true,
               (try? child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return nil
            }
            // Don't traverse packages or directory symlinks (which may form cycles).
            if values.isDirectory == true {
                guard values.isPackage != true, values.isSymbolicLink != true else { return nil }
                return FolderEntry(url: child, isDirectory: true)
            }
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

private final class FolderOutlineView: NSOutlineView, NSMenuItemValidation {
    var contextMenu: ((NSEvent) -> NSMenu?)?
    var copySelection: (() -> Void)?
    var pasteFiles: (() -> Void)?
    var canCopy: (() -> Bool)?
    var canPaste: (() -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(event) }
    @objc func copy(_ sender: Any?) { copySelection?() }
    @objc func paste(_ sender: Any?) { pasteFiles?() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return canCopy?() ?? false }
        if item.action == #selector(paste(_:)) { return canPaste?() ?? false }
        return true
    }
    var renameSelection: (() -> Void)?
    var trashSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            renameSelection?()
        } else if modifiers == .command, event.keyCode == 51 {
            trashSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.keyCode == 51 {
            trashSelection?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class FolderBrowser: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1)
    var onSelectFile: ((URL) -> Void)?
    var onOpenFolder: (() -> Void)?
    var onRenameFile: ((URL, String) -> Bool)?
    var onTrashFile: ((URL) -> Void)?
    var onMoveFile: ((URL) -> Void)?
    var onFilesChanged: (() -> Void)?
    var onNewFile: (() -> Void)?
    private(set) var folderURL: URL?
    private let outline = FolderOutlineView()
    private let scroll = SmoothScrollView()
    private let title = NSTextField(labelWithString: "Folder")
    private let message = NSTextField(wrappingLabelWithString: "Open a folder to browse your notes.")
    private let openButton = NSButton(title: "Open Folder…", target: nil, action: nil)
    private var root: FolderNode?
    private var generation = UUID()
    private var expandedURLs = Set<URL>()
    private var selectedURL: URL?
    private var updatingSelection = false
    private var renamingField: InlineFilenameField?
    private var reloadAfterRename = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor

        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityIdentifier("Folder name")
        let changeFolder = NSClickGestureRecognizer(target: self, action: #selector(chooseFolder))
        changeFolder.numberOfClicksRequired = 2
        title.addGestureRecognizer(changeFolder)
        title.setAccessibilityHelp("Double-click to open a different folder.")
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
        outline.target = self
        outline.doubleAction = #selector(renameClickedFile)
        outline.renameSelection = { [weak self] in self?.renameSelectedFile() }
        outline.trashSelection = { [weak self] in
            guard let self, let url = self.fileURL(at: self.outline.selectedRow) else { return }
            self.onTrashFile?(url)
        }
        outline.contextMenu = { [weak self] in self?.makeContextMenu(for: $0) }
        outline.copySelection = { [weak self] in
            guard let self, let url = self.fileURL(at: self.outline.selectedRow) else { return }
            self.copyFile(url)
        }
        outline.pasteFiles = { [weak self] in self?.pasteFiles() }
        outline.canCopy = { [weak self] in
            guard let self else { return false }
            return self.fileURL(at: self.outline.selectedRow) != nil
        }
        outline.canPaste = { [weak self] in self?.pasteDirectory != nil && !(self?.clipboardFiles.isEmpty ?? true) }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu(for: event)
    }

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

    private func fileURL(at row: Int) -> URL? {
        guard row >= 0, let node = outline.item(atRow: row) as? FolderNode,
              !node.entry.isDirectory else { return nil }
        return node.entry.url
    }

    @objc private func renameClickedFile() {
        beginRename(at: outline.clickedRow)
    }

    private func renameSelectedFile() {
        beginRename(at: outline.selectedRow)
    }

    private var pasteDirectory: URL? {
        if let node = outline.item(atRow: outline.selectedRow) as? FolderNode {
            return node.entry.isDirectory ? node.entry.url : node.entry.url.deletingLastPathComponent()
        }
        return folderURL
    }

    private var clipboardFiles: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    @objc private func pasteFiles() {
        guard let directory = pasteDirectory, window?.attachedSheet == nil else { return }
        do {
            for url in clipboardFiles {
                let destination = try NoteFileOperations.copy(url, into: directory)
                revealFile(destination)
            }
        } catch { NSApp.presentError(error) }
        reload()
        onFilesChanged?()
    }

    private func makeContextMenu(for event: NSEvent) -> NSMenu? {
        guard window?.attachedSheet == nil else { return nil }
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        renamingField?.cancelRename()
        updatingSelection = true
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedURL = (outline.item(atRow: row) as? FolderNode)?.entry.url.standardizedFileURL
        } else {
            outline.deselectAll(nil)
            selectedURL = nil
        }
        updatingSelection = false
        window?.makeFirstResponder(outline)
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let url = fileURL(at: row) else {
            if row < 0 {
                let newFile = NSMenuItem(title: "New File…", action: #selector(createNewFile), keyEquivalent: "")
                newFile.target = self
                menu.addItem(newFile)
            }
            if row >= 0, let node = outline.item(atRow: row) as? FolderNode, node.entry.isDirectory {
                let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = node.entry.url
                menu.addItem(reveal)
                menu.addItem(.separator())
            }
            let paste = NSMenuItem(title: "Paste", action: #selector(pasteFiles), keyEquivalent: "v")
            paste.target = self
            paste.isEnabled = pasteDirectory != nil && !clipboardFiles.isEmpty
            menu.addItem(paste)
            return menu
        }
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        menu.addItem(.separator())
        add("Copy Path", #selector(copyPath(_:)))
        add("Copy Relative Path", #selector(copyRelativePath(_:)))
        menu.addItem(.separator())
        add("Copy", #selector(copyContextFile(_:)), key: "c")
        add("Move to…", #selector(moveContextFile(_:)))
        menu.addItem(.separator())
        add("Rename…", #selector(renameContextFile(_:)))
        add("Delete", #selector(deleteContextFile(_:)), key: "\u{8}")
        return menu
    }

    @objc private func revealInFinder(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func createNewFile() { onNewFile?() }

    private func copyString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copyPath(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        copyString(url.path)
    }

    @objc private func copyRelativePath(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL, let folderURL else { return }
        let root = folderURL.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        copyString(path.starts(with: root) ? path.dropFirst(root.count).joined(separator: "/") : url.path)
    }

    @objc private func copyContextFile(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        copyFile(url)
    }

    @objc private func moveContextFile(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        onMoveFile?(url)
    }

    @objc private func renameContextFile(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        if let row = (0..<outline.numberOfRows).first(where: { fileURL(at: $0) == url }) {
            beginRename(at: row)
        }
    }

    @objc private func deleteContextFile(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        onTrashFile?(url)
    }

    private func beginRename(at row: Int) {
        guard fileURL(at: row) != nil,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField as? InlineFilenameField else { return }
        renamingField?.cancelRename()
        renamingField = field
        field.onEditingEnded = { [weak self] in
            guard let self else { return }
            self.renamingField = nil
            if self.reloadAfterRename {
                self.reloadAfterRename = false
                self.reload()
            }
        }
        field.beginRename()
    }

    func setFolder(_ url: URL) {
        renamingField?.cancelRename()
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
        guard renamingField == nil else { reloadAfterRename = true; return }
        guard let root else { return }
        // Keep the visible tree alive while reading disk. Emptying it first
        // collapses the document height and forces the clip view to the top.
        load(root, refresh: true)
    }

    func selectFile(_ url: URL?) {
        selectedURL = url?.standardizedFileURL
        restoreSelection()
    }

    func revealFile(_ url: URL) {
        guard let folderURL else { return }
        let root = folderURL.standardizedFileURL
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while parent != root, parent.pathComponents.starts(with: root.pathComponents) {
            expandedURLs.insert(parent)
            parent.deleteLastPathComponent()
        }
        selectFile(url)
        reload()
    }

    func focusSelection() {
        guard renamingField == nil else { return }
        window?.makeFirstResponder(outline)
    }

    func resignFocusIfClickedOutsideRows(at point: NSPoint) {
        guard window?.firstResponder === outline,
              !scroll.bounds.contains(scroll.convert(point, from: nil)) else { return }
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
            guard self.renamingField == nil else {
                self.reloadAfterRename = true
                return
            }
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
        else { message.stringValue = "No files in this folder yet." }
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
        let label = InlineFilenameField(labelWithString: node.entry.url.lastPathComponent)
        label.onCommit = { [weak self] name in
            self?.onRenameFile?(node.entry.url, name) ?? false
        }
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
        // Reloading an expanded item emits expansion notifications too.
        // Only user expansion should start another disk refresh; otherwise
        // each completed load starts the next and restarts the row animation.
        guard !updatingSelection,
              let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
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
