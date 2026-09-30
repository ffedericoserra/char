import AppKit
import QuartzCore

enum EditorMetrics {
    static let defaultFontSize: CGFloat = 14
    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 36
    static let columnWidth: CGFloat = 720
    static let minimumSideInset: CGFloat = 32
    static let verticalInset: CGFloat = 96
    static let edgeHeight: CGFloat = 28
    static let titlebarHeight: CGFloat = 48
    static let filenameMaxWidth: CGFloat = 200
    static let filenameLeadingInset: CGFloat = 180
    static let filenameButtonSpacing: CGFloat = 31
    static let filenameSidebarInset: CGFloat = 12
}

@MainActor
enum EditorSession {
    static let fontDidChange = Notification.Name("charNoteFontDidChange")
    static var fontSize: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: "noteFontSize")
            return value > 0 ? min(EditorMetrics.maximumFontSize, max(EditorMetrics.minimumFontSize, value)) : EditorMetrics.defaultFontSize
        }
        set {
            UserDefaults.standard.set(min(EditorMetrics.maximumFontSize, max(EditorMetrics.minimumFontSize, newValue)), forKey: "noteFontSize")
            updateEditors()
        }
    }
    static var fontFamily: String {
        get { UserDefaults.standard.string(forKey: "noteFontFamily") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "noteFontFamily"); updateEditors() }
    }
    static var systemMonospace: Bool {
        get { UserDefaults.standard.bool(forKey: "noteSystemMonospace") }
        set { UserDefaults.standard.set(newValue, forKey: "noteSystemMonospace"); updateEditors() }
    }
    static func font(ofSize size: CGFloat) -> NSFont {
        let family = fontFamily.isEmpty ? AppTheme.palette.editorFontFamily : fontFamily
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return systemMonospace && fontFamily.isEmpty
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size, weight: .regular)
    }
    static func toggleSystemMonospace() {
        guard fontFamily.isEmpty else { return }
        systemMonospace.toggle()
    }
    static func restoreDefaults() {
        for key in ["noteFontSize", "noteFontFamily", "noteSystemMonospace"] { UserDefaults.standard.removeObject(forKey: key) }
        updateEditors()
    }
    private static func updateEditors() {
        for window in NSApp.windows {
            (window.windowController as? EditorWindowController)?.editor.setFontSize(fontSize)
        }
        NotificationCenter.default.post(name: fontDidChange, object: nil)
    }
}

final class NoteTextView: NSTextView {
    weak var note: NoteDocument?
    private var pointerTrackingArea: NSTrackingArea?
    override var undoManager: UndoManager? { note?.undoManager }

    // NSTextView sizes its document with twice the vertical inset. Keep the
    // writing origin fixed while reserving a larger, asymmetric bottom margin.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: EditorMetrics.verticalInset)
    }

    var writingLineHeight: CGFloat {
        let font = self.font ?? EditorSession.font(ofSize: EditorMetrics.defaultFontSize)
        return (layoutManager?.defaultLineHeight(for: font) ?? font.pointSize)
            + (defaultParagraphStyle?.lineSpacing ?? 0)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertNewline(sender)
            return
        }
        let text = string as NSString
        let selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return }
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var indentationEnd = lineStart
        // Only copy leading tabs before the insertion point. When splitting
        // within indentation, the remaining tabs already follow the new line.
        while indentationEnd < selection.location, text.character(at: indentationEnd) == 9 {
            indentationEnd += 1
        }
        guard indentationEnd > lineStart else {
            super.insertNewline(sender)
            return
        }
        let tabs = text.substring(with: NSRange(location: lineStart, length: indentationEnd - lineStart))
        insertText("\n" + tabs, replacementRange: selection)
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .arrow)
        for rect in textCursorRects(in: visibleRect) { addCursorRect(rect, cursor: .iBeam) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updatePointer(with: event) }

    override func mouseMoved(with event: NSEvent) {
        // NSTextView's implementation sets an I-beam independently of its
        // cursor rectangles, including mouse events outside the text itself.
        updatePointer(with: event)
    }

    private func updatePointer(with event: NSEvent) {
        guard let window, window.contentLayoutRect.contains(event.locationInWindow),
              let contentView = window.contentView else { return }
        let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        // AppKit can hit the clip view in the text container's side margins.
        // Other views (especially the split divider) keep their native cursor.
        guard hit === self || hit === enclosingScrollView?.contentView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let overText = textCursorRects(in: visibleRect).contains { $0.contains(point) }
        (overText ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    func textCursorRects(in visibleRect: NSRect) -> [NSRect] {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return [] }
        // Full-size content extends behind the titlebar; scrolled text there
        // must not give the window controls an I-beam pointer.
        let visibleRect = window.map { visibleRect.intersection(convert($0.contentLayoutRect, from: nil)) } ?? visibleRect
        guard !visibleRect.isEmpty else { return [] }
        let origin = textContainerOrigin
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer
        )
        var rects: [NSRect] = []
        var index = visibleGlyphs.location
        while index < NSMaxRange(visibleGlyphs) {
            var lineRange = NSRange()
            var line = layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &lineRange)
            line.origin.x += origin.x
            line.origin.y += origin.y
            let rect = line.intersection(visibleRect)
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                rects.append(rect)
            }
            index = max(index + 1, NSMaxRange(lineRange))
        }
        return rects
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard flag else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: false)
            return
        }
        // The line fragment includes paragraph spacing (and a taller empty-line
        // fragment). The caret should only use the regular font's height.
        let font = self.font ?? NSFont.systemFont(ofSize: EditorMetrics.defaultFontSize, weight: .regular)
        var caret = rect
        caret.size = NSSize(width: 1, height: ceil(font.ascender - font.descender))
        caret.origin.x = round(caret.origin.x * (window?.backingScaleFactor ?? 2)) / (window?.backingScaleFactor ?? 2)
        // AppKit only invalidates the original rectangle when the caret moves.
        // Font-height rounding and pixel alignment must never draw beyond it,
        // or the uncovered pixels can remain as a dot after typing.
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        super.drawInsertionPoint(in: caret.intersection(rect), color: color, turnedOn: true)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class EditorView: NSView, NSTextViewDelegate {
    private(set) var fontSize = EditorSession.fontSize
    let scrollView = SmoothScrollView()
    // TextKit 1 exposes AppKit's custom caret drawing while retaining native
    // selection, input methods, undo, and plain-text layout.
    let textView = NoteTextView(usingTextLayoutManager: false)
    private let topEdge = EdgeSofteningView(top: true)
    private let bottomEdge = EdgeSofteningView(top: false)
    private let titlebarBackdrop = TitlebarBackdropView()
    private let filenameLabel = InlineFilenameField(labelWithString: "")
    private let filenameDivider = NSView()
    private let fileStatus = NSStackView()
    private let revealFileButton = NSButton()
    private let unsavedLabel = NSTextField(labelWithString: "Unsaved")
    var onRenameFile: ((URL, String) -> Bool)?
    var sidebarVisible = false {
        didSet { needsLayout = true }
    }
    private var boundsObserver: NSObjectProtocol?
    private var textObserver: NSObjectProtocol?
    private var lastWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.palette.editorBackground.cgColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.palette.editorBackground
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = AppTheme.isDark ? .light : .dark
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = EditorSession.font(ofSize: fontSize)
        textView.textColor = AppTheme.palette.text
        textView.insertionPointColor = AppTheme.palette.text
        textView.backgroundColor = AppTheme.palette.editorBackground
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: EditorSession.font(ofSize: fontSize), .paragraphStyle: paragraph,
                                     .foregroundColor: AppTheme.palette.text]
        textView.delegate = self
        textObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                // Text storage also reports undo/redo edits, before NSTextView's
                // deferred change notification. Keep saving in sync immediately.
                self.textView.note?.text = storage.string
                self.updateFileStatus()
                self.textView.window?.invalidateCursorRects(for: self.textView)
            }
        }
        textView.setAccessibilityLabel("Note text")
        scrollView.documentView = textView
        scrollView.documentCursor = .arrow
        scrollView.onFindBarVisibilityChanged = { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        addSubview(scrollView)
        addSubview(topEdge)
        addSubview(bottomEdge)
        addSubview(titlebarBackdrop)
        filenameLabel.font = AppTheme.palette.titleFont
        filenameLabel.textColor = AppTheme.palette.text
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.cell?.usesSingleLineMode = true
        filenameLabel.isHidden = true
        filenameLabel.renameOnClick = true
        filenameLabel.onEditingBegan = { [weak self] in self?.layoutFilename() }
        filenameLabel.onEditingEnded = { [weak self] in self?.layoutFilename() }
        addSubview(filenameLabel)
        filenameDivider.wantsLayer = true
        filenameDivider.layer?.backgroundColor = AppTheme.palette.divider.cgColor
        filenameDivider.isHidden = true
        addSubview(filenameDivider)

        revealFileButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal in Finder")
        revealFileButton.isBordered = false
        revealFileButton.imagePosition = .imageOnly
        revealFileButton.contentTintColor = AppTheme.palette.icons
        revealFileButton.toolTip = "Reveal in Finder"
        revealFileButton.target = self
        revealFileButton.action = #selector(revealCurrentFile)
        revealFileButton.setAccessibilityLabel("Reveal in Finder")
        unsavedLabel.font = AppTheme.palette.statusFont
        unsavedLabel.textColor = AppTheme.palette.secondaryText
        fileStatus.orientation = .horizontal
        fileStatus.alignment = .centerY
        fileStatus.spacing = 8
        fileStatus.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        fileStatus.wantsLayer = true
        fileStatus.layer?.backgroundColor = AppTheme.palette.editorBackground.cgColor
        fileStatus.addArrangedSubview(revealFileButton)
        fileStatus.addArrangedSubview(unsavedLabel)
        fileStatus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fileStatus)
        NSLayoutConstraint.activate([
            fileStatus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            fileStatus.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        updateFileStatus()

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateEdges()
                if let textView = self?.textView { textView.window?.invalidateCursorRects(for: textView) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
    }

    func applyTheme() {
        let palette = AppTheme.palette
        layer?.backgroundColor = palette.editorBackground.cgColor
        scrollView.backgroundColor = palette.editorBackground
        scrollView.scrollerKnobStyle = AppTheme.isDark ? .light : .dark
        textView.backgroundColor = palette.editorBackground
        textView.textColor = palette.text
        textView.insertionPointColor = palette.text
        var attributes = textView.typingAttributes
        attributes[.foregroundColor] = palette.text
        textView.typingAttributes = attributes
        filenameLabel.textColor = palette.text
        filenameLabel.font = palette.titleFont
        filenameDivider.layer?.backgroundColor = palette.divider.cgColor
        revealFileButton.contentTintColor = palette.icons
        unsavedLabel.textColor = palette.secondaryText
        unsavedLabel.font = palette.statusFont
        fileStatus.layer?.backgroundColor = palette.editorBackground.cgColor
        titlebarBackdrop.needsDisplay = true
        topEdge.applyTheme()
        bottomEdge.applyTheme()
        applyFontSize()
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        applyFontSize()
    }

    func restoreScrollPosition(_ position: NSPoint) {
        layoutSubtreeIfNeeded()
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
        scrollView.contentView.scroll(to: position)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateEdges()
    }

    private func applyFontSize() {
        let font = EditorSession.font(ofSize: fontSize)
        textView.font = font
        var attributes = textView.typingAttributes
        attributes[.font] = font
        textView.typingAttributes = attributes
        textView.sizeToFit()
        needsLayout = true
        updateEdges()
        textView.window?.invalidateCursorRects(for: textView)
    }

    override func layout() {
        super.layout()
        // The native find bar belongs to the scroll view. Keep its entire
        // viewport below the custom titlebar while searching.
        var scrollFrame = bounds
        if scrollView.isFindBarVisible {
            scrollFrame.size.height = max(0, scrollFrame.height - EditorMetrics.titlebarHeight)
        }
        scrollView.frame = scrollFrame
        let viewport = scrollView.contentSize
        let bottomInset = max(viewport.height / 2, 6 * textView.writingLineHeight + EditorMetrics.edgeHeight)
        let inset = max(EditorMetrics.minimumSideInset, (viewport.width - EditorMetrics.columnWidth) / 2)
        let textInset = NSSize(width: inset, height: (EditorMetrics.verticalInset + bottomInset) / 2)
        if textView.textContainerInset != textInset {
            textView.textContainerInset = textInset
        }
        if lastWidth != viewport.width {
            lastWidth = viewport.width
            textView.setFrameSize(NSSize(width: viewport.width, height: max(textView.frame.height, viewport.height)))
            textView.textContainer?.containerSize = NSSize(
                width: max(1, viewport.width - inset * 2), height: .greatestFiniteMagnitude)
        }
        textView.minSize = NSSize(width: 0, height: viewport.height)
        textView.sizeToFit()
        let contentFrame = scrollView.contentView.frame
        topEdge.frame = NSRect(x: contentFrame.minX, y: contentFrame.maxY - EditorMetrics.edgeHeight,
                               width: contentFrame.width, height: EditorMetrics.edgeHeight)
        bottomEdge.frame = NSRect(x: contentFrame.minX, y: contentFrame.minY,
                                  width: contentFrame.width, height: EditorMetrics.edgeHeight)
        titlebarBackdrop.frame = NSRect(x: bounds.minX, y: bounds.maxY - EditorMetrics.titlebarHeight,
                                        width: bounds.width, height: EditorMetrics.titlebarHeight)
        layoutFilename()
        let filenameX = filenameLeadingInset
        // Reserve the maximum title width even for short names or unsaved notes,
        // keeping this breakpoint stable when switching or saving documents.
        titlebarBackdrop.isHidden = !scrollView.isFindBarVisible
            && textView.textContainerInset.width > filenameX + EditorMetrics.filenameMaxWidth
        updateEdges()
    }

    func installFilename(in titlebar: NSView) {
        // Keep text above the native titlebar material, which blurs content
        // drawn behind it in the full-size editor view.
        titlebar.addSubview(filenameLabel)
        titlebar.addSubview(filenameDivider)
        layoutFilename()
    }

    private var filenameLeadingInset: CGFloat {
        if sidebarVisible { return EditorMetrics.filenameSidebarInset }
        guard let button = (window as? NoteWindow)?.noteButtons.last else {
            return EditorMetrics.filenameLeadingInset
        }
        return convert(button.bounds, from: button).maxX + EditorMetrics.filenameButtonSpacing
    }

    func layoutFilename() {
        guard let parent = filenameLabel.superview else { return }
        let filenameX = filenameLeadingInset
        let labelHeight = ceil(filenameLabel.intrinsicContentSize.height)
        let frame = convert(NSRect(x: filenameX,
                                   y: bounds.maxY - EditorMetrics.titlebarHeight / 2 - labelHeight / 2,
                                   width: EditorMetrics.filenameMaxWidth, height: labelHeight), to: parent)
        filenameLabel.frame = parent.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        filenameDivider.frame = convert(NSRect(x: filenameX - 14, y: bounds.maxY - 31,
                                               width: 1, height: 14), to: parent)
        filenameDivider.isHidden = sidebarVisible || filenameLabel.isHidden
    }

    func updateFilename(_ url: URL?) {
        filenameLabel.cancelRename()
        filenameLabel.setFilename(url?.lastPathComponent ?? "")
        filenameLabel.onCommit = { [weak self] name in
            guard let url else { return false }
            return self?.onRenameFile?(url, name) ?? false
        }
        filenameLabel.toolTip = url?.lastPathComponent
        filenameLabel.isHidden = url == nil
        needsLayout = true
        updateFileStatus()
    }

    func updateFileStatus() {
        let note = textView.note
        let exists = note?.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        revealFileButton.isHidden = !exists
        let isEmptyNewNote = note?.fileURL == nil && note?.text.isEmpty == true
        unsavedLabel.isHidden = note == nil || isEmptyNewNote || (exists && note?.isDocumentEdited == false)
        fileStatus.isHidden = revealFileButton.isHidden && unsavedLabel.isHidden
        needsLayout = true
    }

    @objc private func revealCurrentFile() {
        guard let url = textView.note?.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            updateFileStatus()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func filenameContains(_ point: NSPoint) -> Bool {
        !filenameLabel.isHidden && filenameLabel.convert(filenameLabel.bounds, to: nil).contains(point)
    }

    func display(_ note: NoteDocument) {
        updateFilename(note.fileURL)
        scrollView.stopWheelAnimation()
        textView.breakUndoCoalescing()
        textView.note = nil
        textView.string = note.text
        textView.note = note
        updateFileStatus()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        applyFontSize()
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Replacing a note can shrink and scroll the text view in the same
        // update. Repaint the entire viewport, including the now-empty area,
        // instead of retaining pixels from the previous note's backing store.
        textView.needsDisplay = true
        scrollView.contentView.needsDisplay = true
        scrollView.needsDisplay = true
        needsDisplay = true
        updateEdges()
        textView.window?.invalidateCursorRects(for: textView)
    }

    func textDidChange(_ notification: Notification) {
        textView.note?.text = textView.string
        // NSDocument observes its undo manager and tracks edited state itself.
        updateEdges()
    }

    private func updateEdges() {
        let viewport = scrollView.contentView.bounds
        let hideTop = viewport.minY < 1
        let hideBottom = textView.bounds.height <= viewport.maxY + 1
        if topEdge.isHidden != hideTop { topEdge.isHidden = hideTop }
        if bottomEdge.isHidden != hideBottom { bottomEdge.isHidden = hideBottom }
    }
}

final class InlineFilenameField: NSTextField, NSTextFieldDelegate {
    var renameOnClick = false
    var selectsFilenameStem = true
    private var fullFilename: String?
    var onCommit: ((String) -> Bool)?
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?
    private(set) var isRenaming = false
    private var originalName = ""

    func setFilename(_ name: String) {
        fullFilename = name
        stringValue = name
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if isRenaming { super.mouseDown(with: event) }
        else if renameOnClick { beginRename() }
        else { super.mouseDown(with: event) }
    }

    func beginRename() {
        guard !isRenaming, !isHidden, window?.attachedSheet == nil else { return }
        originalName = fullFilename ?? stringValue
        stringValue = originalName
        isRenaming = true
        delegate = self
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        lineBreakMode = .byClipping
        // A bordered editing field is taller than the label. Lay it out before
        // AppKit creates the field editor, so the text is not clipped or offset.
        invalidateIntrinsicContentSize()
        onEditingBegan?()
        selectText(nil)
        let stem = selectsFilenameStem ? (originalName as NSString).deletingPathExtension : originalName
        (currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
    }

    func cancelRename() {
        guard isRenaming else { return }
        finishRename(commit: false)
    }

    private func finishRename(commit: Bool) {
        guard isRenaming else { return }
        let proposed = currentEditor()?.string ?? stringValue
        isRenaming = false
        // End field editing before a successful rename refreshes sidebar rows.
        abortEditing()
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
        invalidateIntrinsicContentSize()
        setFilename(originalName)
        if commit, proposed != originalName, onCommit?(proposed) == true {
            setFilename(proposed)
        }
        onEditingEnded?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(commit: true)
            return true
        }
        return false
    }
}

final class TitlebarBackdropView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.palette.editorBackground.setFill()
        bounds.fill()
        AppTheme.palette.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Trackpads already supply precise deltas and momentum. Only coarse mouse
/// wheel events need interpolation between their otherwise abrupt jumps.
final class SmoothScrollView: NSScrollView {
    var onFindBarVisibilityChanged: (() -> Void)?

    override var isFindBarVisible: Bool {
        didSet {
            if isFindBarVisible != oldValue { onFindBarVisibilityChanged?() }
        }
    }

    // Keep the thumb over the content, even when macOS prefers legacy
    // scrollers for a connected mouse. No reserved track or right-hand gutter.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    static let wheelDistanceMultiplier: CGFloat = 4
    private var wheelDisplayLink: CADisplayLink?
    private lazy var animationDriver = WheelAnimationDriver(scrollView: self)
    private var wheelTarget: CGFloat = 0
    private var wheelPosition: CGFloat = 0
    private var lastFrameTime: TimeInterval = 0
    private var previousPosition: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas,
              event.scrollingDeltaY != 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopWheelAnimation()
            super.scrollWheel(with: event)
            return
        }
        // AppKit normally resolves pending text layout in its wheel handler.
        // Do the same before clamping our destination, otherwise a freshly
        // opened note may still have only a viewport-sized document frame.
        if let textView = documentView as? NSTextView, let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
            textView.sizeToFit()
        }
        let current = contentView.bounds.minY
        if wheelDisplayLink == nil {
            wheelTarget = current
            wheelPosition = current
            previousPosition = current
        }
        // NSScrollView interprets a coarse delta in line units, not pixels.
        let distance = -event.scrollingDeltaY * verticalLineScroll * Self.wheelDistanceMultiplier
        if (wheelTarget - current) * distance < 0 {
            wheelTarget = current
            wheelPosition = current
        }
        wheelTarget = constrainedY(wheelTarget + distance)
        guard abs(wheelTarget - current) > 0.1 else { return }
        flashScrollers()
        guard wheelDisplayLink == nil else { return }
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        let link = displayLink(target: animationDriver, selector: #selector(WheelAnimationDriver.tick(_:)))
        wheelDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stopWheelAnimation() {
        wheelDisplayLink?.invalidate()
        wheelDisplayLink = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopWheelAnimation() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func constrainedY(_ y: CGFloat) -> CGFloat {
        var proposed = contentView.bounds
        proposed.origin.y = y
        return contentView.constrainBoundsRect(proposed).minY
    }

    fileprivate func advanceWheelAnimation() {
        let current = contentView.bounds.minY
        // Scrollbar dragging, keyboard navigation, and selection must take over
        // immediately, rather than fighting a remaining wheel animation.
        guard abs(current - previousPosition) < 1 else { stopWheelAnimation(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(now - lastFrameTime, 0.05)
        lastFrameTime = now
        wheelTarget = constrainedY(wheelTarget)
        let remaining = wheelTarget - wheelPosition
        // Keep the continuous position separate from NSClipView's pixel-rounded
        // bounds so that the animation cannot stall a fraction before its end.
        wheelPosition = abs(remaining) < 0.3 ? wheelTarget : wheelPosition + remaining * (1 - exp(-elapsed / 0.045))
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: wheelPosition))
        reflectScrolledClipView(contentView)
        previousPosition = contentView.bounds.minY
        if abs(wheelTarget - wheelPosition) < 0.3 {
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: wheelTarget))
            reflectScrolledClipView(contentView)
            stopWheelAnimation()
        }
    }
}

@MainActor
private final class WheelAnimationDriver: NSObject {
    weak var scrollView: SmoothScrollView?
    init(scrollView: SmoothScrollView) { self.scrollView = scrollView }
    @objc func tick(_ link: CADisplayLink) {
        guard let scrollView else { link.invalidate(); return }
        scrollView.advanceWheelAnimation()
    }
}

/// Public AppKit backdrop blur with a graduated mask and a soft white edge.
/// The compositor handles scrolling; no text snapshots or per-frame filters.
final class EdgeSofteningView: NSView {
    private let effect = NSVisualEffectView()
    private let effectMask = CAGradientLayer()
    private let whiteFade = CAGradientLayer()

    init(top: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        let start = CGPoint(x: 0.5, y: top ? 1 : 0)
        let end = CGPoint(x: 0.5, y: top ? 0 : 1)
        effectMask.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
        effectMask.startPoint = start
        effectMask.endPoint = end
        effect.layer?.mask = effectMask
        addSubview(effect)
        whiteFade.colors = [AppTheme.palette.editorBackground.cgColor, AppTheme.palette.editorBackground.withAlphaComponent(0).cgColor]
        whiteFade.startPoint = start
        whiteFade.endPoint = end
        layer?.addSublayer(whiteFade)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        whiteFade.colors = [AppTheme.palette.editorBackground.cgColor,
                            AppTheme.palette.editorBackground.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.frame = bounds
        effectMask.frame = bounds
        whiteFade.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
