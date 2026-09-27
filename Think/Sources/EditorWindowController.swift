import AppKit

private final class WhiteSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) { NSColor.white.setFill(); rect.fill() }
}

final class NoteWindow: NSWindow {
    var noteButtons: [NSButton] = []
    private var controlFrameObservers: [NSObjectProtocol] = []
    private var isAligningControls = false
    private var frameBeforeMaximize: NSRect?

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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2,
           !styleMask.contains(.fullScreen), event.locationInWindow.y >= frame.height - 48 {
            let controls = [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                standardWindowButton($0)
            } + noteButtons
            let overControl = controls.contains { button in
                button.convert(button.bounds, to: nil).contains(event.locationInWindow)
            }
            if !overControl {
                toggleMaximize()
                return
            }
        }
        super.sendEvent(event)
    }

    func toggleMaximize() {
        guard let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let fillsScreen = abs(frame.minX - visibleFrame.minX) < 2 && abs(frame.minY - visibleFrame.minY) < 2
            && abs(frame.width - visibleFrame.width) < 2 && abs(frame.height - visibleFrame.height) < 2
        if fillsScreen, let previousFrame = frameBeforeMaximize {
            frameBeforeMaximize = nil
            setFrame(previousFrame, display: true)
        } else {
            frameBeforeMaximize = frame
            setFrame(visibleFrame, display: true)
        }
        alignTitlebarControls()
    }

    func alignTitlebarControls() {
        guard !isAligningControls, !styleMask.contains(.fullScreen) else { return }
        isAligningControls = true
        defer { isAligningControls = false }
        let nativeButtons = [ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        for (button, x) in zip(nativeButtons + noteButtons, [23.0, 43.0, 63.0, 102.0, 136.0]) {
            guard let parent = button.superview else { continue }
            let center = parent.convert(NSPoint(x: x, y: frame.height - 24), from: nil)
            let origin = NSPoint(x: center.x - button.frame.width / 2, y: center.y - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let editor = EditorView()
    private let sidebar = FolderBrowser()
    private let splitView = WhiteSplitView()
    private var sidebarVisible = false
    private var sidebarWidth: CGFloat = 240
    private var pendingURL: URL?
    private var sidebarButton: NSButton!
    var folderURL: URL? { sidebar.folderURL }

    init() {
        let window = NoteWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Untitled"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(editor.textView)
    }

    func display(_ note: NoteDocument) {
        editor.display(note)
        synchronizeWindowTitleWithDocumentName()
        sidebar.selectFile(note.fileURL)
        window?.makeFirstResponder(editor.textView)
    }

    func documentLocationDidChange() {
        sidebar.reload()
        sidebar.selectFile((document as? NoteDocument)?.fileURL)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        if sidebarVisible { sidebarWidth = sidebar.frame.width }
        sidebarVisible.toggle()
        sidebar.isHidden = !sidebarVisible
        window?.minSize = NSSize(width: sidebarVisible ? 720 : 480, height: 360)
        if sidebarVisible, let window, window.frame.width < 720 {
            var frame = window.frame
            frame.size.width = 720
            window.setFrame(frame, display: true)
        }
        splitView.adjustSubviews()
        if sidebarVisible { splitView.setPosition(sidebarWidth, ofDividerAt: 0) }
        sidebarButton.state = sidebarVisible ? .on : .off
        sidebarButton.toolTip = sidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)"
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
        guard pendingURL == nil, window?.attachedSheet == nil,
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
            self.display(note)
            oldDocument.close()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebar.reload()
        (window as? NoteWindow)?.alignTitlebarControls()
    }

    func windowDidResize(_ notification: Notification) { (window as? NoteWindow)?.alignTitlebarControls() }
    func windowDidUpdate(_ notification: Notification) { (window as? NoteWindow)?.alignTitlebarControls() }

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
        toolbar.showsBaselineSeparator = false
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 48))
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)

        sidebarButton = titlebarButton("sidebar.left", label: "Toggle Sidebar", action: #selector(toggleSidebar(_:)))
        sidebarButton.frame = NSRect(x: 8, y: 11, width: 26, height: 26)
        sidebarButton.toolTip = "Show Sidebar (⌃⌘S)"
        let newButton = titlebarButton("square.and.pencil", label: "New Note", action: #selector(newNote(_:)))
        newButton.frame = NSRect(x: 42, y: 11, width: 26, height: 26)
        newButton.toolTip = "New Note (⌘N)"
        container.addSubview(sidebarButton)
        container.addSubview(newButton)
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
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func newNote(_ sender: Any?) { NSDocumentController.shared.newDocument(sender) }
}
