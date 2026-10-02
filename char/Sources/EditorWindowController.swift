import AppKit
import UniformTypeIdentifiers

private final class SidebarSplitView: NSSplitView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle these shortcuts before the text view consumes them.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "m" {
            AppTheme.toggle()
            return true
        }
        if event.type == .keyDown, modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "e",
           let window, window.attachedSheet == nil,
           let controller = window.windowController as? EditorWindowController {
            controller.toggleSidebar(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func drawDivider(in rect: NSRect) {
        AppTheme.palette.divider.setFill()
        rect.fill()
    }
}

final class NoteWindow: NSWindow {
    var noteButtons: [NSButton] = []
    private var controlFrameObservers: [NSObjectProtocol] = []
    private var isAligningControls = false
    private var frameBeforeMaximize: NSRect?
    private var revealWindowControlsAfterLayout = false

    func hideWindowControlsForFullScreenExit() {
        revealWindowControlsAfterLayout = false
        setWindowControlsAlpha(0)
    }

    func revealWindowControlsOnNextDisplay() {
        revealWindowControlsAfterLayout = true
        contentView?.needsDisplay = true
    }

    func cancelWindowControlsTransition() {
        revealWindowControlsAfterLayout = false
        setWindowControlsAlpha(1)
    }

    private func setWindowControlsAlpha(_ alpha: CGFloat) {
        for type in [ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.alphaValue = alpha
        }
    }

    func observeTitlebarLayout() {
        for type in [ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            controlFrameObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.alignTitlebarControls() }
            })
        }
    }

    deinit {
        controlFrameObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func displayIfNeeded() {
        // Switching documents updates native titlebar state. Finish that
        // layout before positioning controls, otherwise AppKit can overwrite
        // the zoom button's frame until the next mouse or keyboard event.
        contentView?.superview?.layoutSubtreeIfNeeded()
        alignTitlebarControls()
        // The exit notification restores the toolbar, but AppKit still has
        // layout to finish. Reveal the traffic lights only after that layout
        // and our custom control alignment, in the same display pass.
        if revealWindowControlsAfterLayout, !styleMask.contains(.fullScreen),
           (windowController as? EditorWindowController)?.usesFullScreenChrome != true {
            cancelWindowControlsTransition()
        }
        super.displayIfNeeded()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2,
           !styleMask.contains(.fullScreen), event.locationInWindow.y >= frame.height - 48 {
            let controls = [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                standardWindowButton($0)
            } + noteButtons
            let overControl = controls.contains { button in
                button.convert(button.bounds, to: nil).contains(event.locationInWindow)
            }
            let overFilename = (windowController as? EditorWindowController)?.editor.filenameContains(event.locationInWindow) ?? false
            if !overControl && !overFilename {
                (windowController as? EditorWindowController)?
                    .resignSidebarFocusIfClickedOutsideRows(at: event.locationInWindow)
                toggleMaximize()
                return
            }
        }
        super.sendEvent(event)
        if event.type == .leftMouseDown {
            (windowController as? EditorWindowController)?
                .resignSidebarFocusIfClickedOutsideRows(at: event.locationInWindow)
        }
    }

    func toggleMaximize() {
        guard let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let fillsScreen = abs(frame.minX - visibleFrame.minX) < 2 && abs(frame.minY - visibleFrame.minY) < 2
            && abs(frame.width - visibleFrame.width) < 2 && abs(frame.height - visibleFrame.height) < 2
        if fillsScreen, let previousFrame = frameBeforeMaximize {
            frameBeforeMaximize = nil
            setFrame(previousFrame, display: true, animate: true)
        } else {
            frameBeforeMaximize = frame
            setFrame(visibleFrame, display: true, animate: true)
        }
        alignTitlebarControls()
    }

    func alignTitlebarControls() {
        guard !isAligningControls, !styleMask.contains(.fullScreen),
              (windowController as? EditorWindowController)?.usesFullScreenChrome != true else { return }
        isAligningControls = true
        defer { isAligningControls = false }
        let nativeButtons = [ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        for (index, (button, x)) in zip(nativeButtons + noteButtons, [23.0, 43.0, 63.0, 102.0, 136.0]).enumerated() {
            guard let parent = button.superview else { continue }
            // Fixed window-space centers: preserve the traffic lights and sidebar,
            // with the new-note symbol optically aligned one point higher.
            // Reapply after AppKit layout; never derive these from native frames.
            let distanceFromTop: CGFloat = index == 4 ? 23 : 24
            let center = parent.convert(NSPoint(x: x, y: frame.height - distanceFromTop), from: nil)
            let origin = NSPoint(x: center.x - button.frame.width / 2, y: center.y - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        (windowController as? EditorWindowController)?.editor.layoutFilename()
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let editor = EditorView()
    private let sidebar = FolderBrowser()
    private let splitView = SidebarSplitView()
    private var sidebarVisible = false
    private var sidebarWidth: CGFloat = 240
    private var pendingURL: URL?
    private var creatingNewNote = false
    private var sidebarButton: NSButton!
    private var noteToolbar: NSToolbar?
    private var noteAccessory: NSTitlebarAccessoryViewController?
    private let fullScreenControls = NSView()
    fileprivate var usesFullScreenChrome = false
    var folderURL: URL? { sidebar.folderURL }

    init() {
        let window = NoteWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Untitled"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.palette.editorBackground
        window.isOpaque = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.setFrameAutosaveName("NoteWindow")
        window.center()

        splitView.isVertical = true
        splitView.arrangesAllSubviews = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(editor)
        sidebar.isHidden = true
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        window.contentView = splitView
        addTitlebarButtons(to: window)

        sidebar.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        sidebar.onSelectFile = { [weak self] in self?.openInCurrentWindow($0) }
        sidebar.onRenameFile = { [weak self] url, name in self?.renameFile(url, to: name) ?? false }
        sidebar.onTrashFile = { [weak self] in self?.trashFile($0) }
        sidebar.onMoveFile = { [weak self] in self?.moveFile($0) }
        sidebar.onFilesChanged = { [weak self] in self?.refreshFileBrowsers() }
        sidebar.onNewFile = { [weak self] in self?.createFile() }
        editor.onRenameFile = { [weak self] url, name in self?.renameFile(url, to: name) ?? false }
    }

    func applyTheme() {
        window?.backgroundColor = AppTheme.palette.editorBackground
        editor.applyTheme()
        sidebar.applyTheme()
        splitView.needsDisplay = true
        for button in (window as? NoteWindow)?.noteButtons ?? [] {
            button.contentTintColor = AppTheme.palette.icons
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(editor.textView)
    }

    func display(_ note: NoteDocument, focusEditor: Bool = true) {
        editor.display(note)
        synchronizeWindowTitleWithDocumentName()
        sidebar.selectFile(note.fileURL)
        if focusEditor { window?.makeFirstResponder(editor.textView) }
    }

    func documentLocationDidChange() {
        editor.updateFilename((document as? NoteDocument)?.fileURL)
        sidebar.reload()
        sidebar.selectFile((document as? NoteDocument)?.fileURL)
    }

    func didSaveNewFile(at url: URL) {
        let parent = url.deletingLastPathComponent()
        let rootComponents = folderURL?.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parentComponents = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if rootComponents == nil || !parentComponents.starts(with: rootComponents!) {
            sidebar.setFolder(parent)
        }
        sidebar.revealFile(url)
        if !sidebarVisible { toggleSidebar(nil) }
    }

    private func renameFile(_ url: URL, to name: String) -> Bool {
        guard window?.attachedSheet == nil, pendingURL == nil, !creatingNewNote else { return false }
        do {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let destination = try NoteFileOperations.rename(url, to: name)
            if isDirectory {
                for window in NSApp.windows {
                    (window.windowController as? EditorWindowController)?.sidebar.relocateFolder(from: url, to: destination)
                }
            }
            sidebar.selectFile(destination)
            refreshFileBrowsers()
            return true
        } catch {
            DispatchQueue.main.async { NSApp.presentError(error) }
            return false
        }
    }

    private func trashFile(_ url: URL) {
        guard let window, window.attachedSheet == nil, pendingURL == nil, !creatingNewNote else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(url.lastPathComponent)” to Trash?"
        let hasUnsavedChanges = NSDocumentController.shared.document(for: url)?.isDocumentEdited ?? false
        alert.informativeText = hasUnsavedChanges
            ? "The file will be moved to Trash and its unsaved changes will be discarded."
            : "You can restore the file from Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try NoteFileOperations.trash(url)
                self?.refreshFileBrowsers()
            } catch { NSApp.presentError(error) }
        }
    }

    private func moveFile(_ url: URL) {
        guard let window, window.attachedSheet == nil, pendingURL == nil, !creatingNewNote else { return }
        let panel = NSSavePanel()
        panel.title = "Move File"
        panel.prompt = "Move"
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do {
                let moved = try NoteFileOperations.move(url, to: destination)
                self.sidebar.setFolder(moved.deletingLastPathComponent())
                self.sidebar.revealFile(moved)
                if !self.sidebarVisible { self.toggleSidebar(nil) }
                self.refreshFileBrowsers()
            } catch { NSApp.presentError(error) }
        }
    }

    private func createFile() {
        guard let window, window.attachedSheet == nil, pendingURL == nil, !creatingNewNote else { return }
        let panel = NSSavePanel()
        panel.title = "New File"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled.txt"
        panel.directoryURL = folderURL
        panel.allowedContentTypes = [UTType(filenameExtension: "txt")!]
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                self.didSaveNewFile(at: url)
                self.refreshFileBrowsers()
                self.openInCurrentWindow(url)
            } catch { NSApp.presentError(error) }
        }
    }

    private func refreshFileBrowsers() {
        for window in NSApp.windows {
            (window.windowController as? EditorWindowController)?.sidebar.reload()
        }
    }

    func resignSidebarFocusIfClickedOutsideRows(at point: NSPoint) {
        sidebar.resignFocusIfClickedOutsideRows(at: point)
    }

    @objc func increaseFontSize(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontSize(by: -1) }

    private func changeFontSize(by step: CGFloat) {
        let size = min(EditorMetrics.maximumFontSize,
                       max(EditorMetrics.minimumFontSize, EditorSession.fontSize + step))
        guard size != EditorSession.fontSize else { return }
        EditorSession.fontSize = size
    }

    @objc func toggleSidebar(_ sender: Any?) {
        editor.scrollView.stopWheelAnimation()
        let scrollPosition = editor.scrollView.contentView.bounds.origin
        defer {
            // Resizing the split view lets AppKit scroll the text view while
            // changing its insets. Restore only after layout and focus settle.
            window?.contentView?.superview?.layoutSubtreeIfNeeded()
            editor.restoreScrollPosition(scrollPosition)
        }
        if sidebarVisible { sidebarWidth = sidebar.frame.width }
        sidebarVisible.toggle()
        editor.sidebarVisible = sidebarVisible
        window?.minSize = NSSize(width: sidebarVisible ? 720 : 480, height: 360)
        if sidebarVisible, let window, window.frame.width < 720 {
            var frame = window.frame
            frame.size.width = 720
            window.setFrame(frame, display: true, animate: false)
        }
        if sidebarVisible {
            sidebar.isHidden = false
            splitView.adjustSubviews()
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        } else {
            sidebar.isHidden = true
            splitView.adjustSubviews()
        }
        sidebarButton.state = sidebarVisible ? .on : .off
        sidebarButton.toolTip = sidebarVisible ? "Hide Sidebar (⌘⇧E)" : "Show Sidebar (⌘⇧E)"
        window?.makeFirstResponder(editor.textView)
    }

    @objc func openFolder(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.sidebar.setFolder(url)
            if !self.sidebarVisible { self.toggleSidebar(nil) }
        }
    }

    private func openInCurrentWindow(_ url: URL) {
        guard pendingURL == nil, !creatingNewNote, window?.attachedSheet == nil,
              let note = document as? NoteDocument else { return }
        if note.fileURL?.standardizedFileURL == url.standardizedFileURL { return }
        if let existing = NSDocumentController.shared.document(for: url) {
            existing.showWindows()
            sidebar.selectFile(note.fileURL)
            return
        }
        pendingURL = url
        editor.textView.breakUndoCoalescing()
        note.canClose(withDelegate: self,
                      shouldClose: #selector(finishSwitch(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func finishSwitch(_ oldDocument: NSDocument, shouldClose: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        guard let url = pendingURL else { return }
        guard shouldClose else {
            pendingURL = nil
            sidebar.selectFile(oldDocument.fileURL)
            return
        }
        // Read successfully before detaching the current document. A failed open
        // must leave its window and unsaved text intact, even after Don't Save.
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] document, alreadyOpen, error in
            guard let self else { return }
            self.pendingURL = nil
            guard let note = document as? NoteDocument else {
                if let error { NSApp.presentError(error) }
                self.sidebar.selectFile(oldDocument.fileURL)
                return
            }
            if alreadyOpen {
                note.showWindows()
                self.sidebar.selectFile(oldDocument.fileURL)
                return
            }
            oldDocument.removeWindowController(self)
            // display:false normally creates no controllers; remove any unused
            // ones so that this window remains the sole owner of the new note.
            for controller in note.windowControllers {
                note.removeWindowController(controller)
                controller.close()
            }
            note.addWindowController(self)
            self.display(note, focusEditor: false)
            self.sidebar.focusSelection()
            oldDocument.close()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebar.reload()
        editor.updateFileStatus()
        (window as? NoteWindow)?.alignTitlebarControls()
    }

    func windowDidResize(_ notification: Notification) { (window as? NoteWindow)?.alignTitlebarControls() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        setFullScreenChrome(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setFullScreenChrome(false)
        (window as? NoteWindow)?.revealWindowControlsOnNextDisplay()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        (window as? NoteWindow)?.hideWindowControlsForFullScreenExit()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        (window as? NoteWindow)?.cancelWindowControlsTransition()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        setFullScreenChrome(false)
    }

    private func setFullScreenChrome(_ fullScreen: Bool) {
        guard usesFullScreenChrome != fullScreen,
              let window = window as? NoteWindow, let accessory = noteAccessory else { return }
        usesFullScreenChrome = fullScreen
        if fullScreen {
            // AppKit puts the native toolbar in an opaque full-screen overlay.
            // Keep our controls on the full-size content so the editor's fade
            // remains visible beneath them, just as it is in a normal window.
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            window.toolbar = nil
            fullScreenControls.frame = NSRect(x: 0,
                                             y: splitView.isFlipped ? splitView.bounds.minY : splitView.bounds.maxY - 48,
                                             width: 80, height: 48)
            fullScreenControls.autoresizingMask = splitView.isFlipped ? [.maxYMargin] : [.minYMargin]
            splitView.addSubview(fullScreenControls)
            for (index, button) in window.noteButtons.enumerated() {
                fullScreenControls.addSubview(button)
                button.frame = NSRect(x: 8 + CGFloat(index) * 34, y: index == 1 ? 12 : 11,
                                      width: 26, height: 26)
            }
            editor.installFilename(in: editor)
        } else {
            for button in window.noteButtons { accessory.view.addSubview(button) }
            fullScreenControls.removeFromSuperview()
            window.toolbar = noteToolbar
            window.addTitlebarAccessoryViewController(accessory)
            if let titlebar = window.standardWindowButton(.closeButton)?.superview {
                editor.installFilename(in: titlebar)
            }
            window.alignTitlebarControls()
        }
        editor.needsLayout = true
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { min(360, splitView.bounds.width - 400) }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === editor }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        sidebarVisible ? drawnRect.insetBy(dx: -3, dy: 0) : .zero
    }

    private func addTitlebarButtons(to window: NSWindow) {
        let toolbar = NSToolbar(identifier: "NoteToolbar")
        noteToolbar = toolbar
        toolbar.showsBaselineSeparator = false
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        let accessory = NSTitlebarAccessoryViewController()
        noteAccessory = accessory
        accessory.layoutAttribute = .left
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 48))
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)

        sidebarButton = titlebarButton("sidebar.left", label: "Toggle Sidebar", action: #selector(toggleSidebar(_:)))
        sidebarButton.frame = NSRect(x: 8, y: 11, width: 26, height: 26)
        sidebarButton.toolTip = "Show Sidebar (⌘⇧E)"
        let newButton = titlebarButton("square.and.pencil", label: "New Note", action: #selector(newNote(_:)))
        newButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        newButton.frame = NSRect(x: 42, y: 11, width: 26, height: 26)
        newButton.toolTip = "New Note (⌘N)"
        container.addSubview(sidebarButton)
        container.addSubview(newButton)
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            editor.installFilename(in: titlebar)
        }
        (window as? NoteWindow)?.noteButtons = [sidebarButton, newButton]
        (window as? NoteWindow)?.observeTitlebarLayout()
        (window as? NoteWindow)?.alignTitlebarControls()
    }

    private func titlebarButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.contentTintColor = AppTheme.palette.icons
        button.setAccessibilityLabel(label)
        return button
    }

    @objc func newNote(_ sender: Any?) {
        guard pendingURL == nil, !creatingNewNote, window?.attachedSheet == nil,
              let note = document as? NoteDocument else { return }
        window?.makeFirstResponder(editor.textView)
        editor.textView.breakUndoCoalescing()
        creatingNewNote = true
        note.canClose(withDelegate: self,
                      shouldClose: #selector(finishNewNote(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func finishNewNote(_ oldDocument: NSDocument, shouldClose: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        guard creatingNewNote else { return }
        creatingNewNote = false
        guard shouldClose else { return }
        do {
            let note = try NSDocumentController.shared.makeUntitledDocument(ofType: "public.plain-text")
            guard let note = note as? NoteDocument else { return }
            NSDocumentController.shared.addDocument(note)
            oldDocument.removeWindowController(self)
            note.addWindowController(self)
            display(note)
            oldDocument.close()
        } catch { NSApp.presentError(error) }
    }
}
