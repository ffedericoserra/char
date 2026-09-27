import AppKit
import QuartzCore

enum EditorMetrics {
    static let columnWidth: CGFloat = 720
    static let minimumSideInset: CGFloat = 32
    static let verticalInset: CGFloat = 96
    static let edgeHeight: CGFloat = 28
}

final class NoteTextView: NSTextView {
    weak var note: NoteDocument?
    override var undoManager: UndoManager? { note?.undoManager }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // The line fragment includes paragraph spacing (and a taller empty-line
        // fragment). The caret should only use the regular font's height.
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        var caret = rect
        caret.size = NSSize(width: 1, height: ceil(font.ascender - font.descender))
        caret.origin.x = round(caret.origin.x * (window?.backingScaleFactor ?? 2)) / (window?.backingScaleFactor ?? 2)
        super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
    }
}

final class EditorView: NSView, NSTextViewDelegate {
    let scrollView = NoteScrollView()
    // TextKit 1 exposes AppKit's custom caret drawing while retaining native
    // selection, input methods, undo, and plain-text layout.
    let textView = NoteTextView(usingTextLayoutManager: false)
    private let topEdge = EdgeSofteningView(top: true)
    private let bottomEdge = EdgeSofteningView(top: false)
    private var boundsObserver: NSObjectProtocol?
    private var textObserver: NSObjectProtocol?
    private var lastWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .dark
        scrollView.documentCursor = .iBeam
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
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor(white: 0.22, alpha: 1)
        textView.insertionPointColor = .textColor
        textView.backgroundColor = .white
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
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph,
                                     .foregroundColor: NSColor(white: 0.22, alpha: 1)]
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
            }
        }
        textView.setAccessibilityLabel("Note text")
        scrollView.documentView = textView
        addSubview(scrollView)
        addSubview(topEdge)
        addSubview(bottomEdge)

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEdges() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let viewport = scrollView.contentSize
        if lastWidth != viewport.width {
            lastWidth = viewport.width
            let inset = max(EditorMetrics.minimumSideInset, (viewport.width - EditorMetrics.columnWidth) / 2)
            textView.textContainerInset = NSSize(width: inset, height: EditorMetrics.verticalInset)
            textView.setFrameSize(NSSize(width: viewport.width, height: max(textView.frame.height, viewport.height)))
            textView.textContainer?.containerSize = NSSize(
                width: max(1, viewport.width - inset * 2), height: .greatestFiniteMagnitude)
        }
        textView.minSize = NSSize(width: 0, height: viewport.height)
        let contentFrame = scrollView.contentView.frame
        topEdge.frame = NSRect(x: contentFrame.minX, y: contentFrame.maxY - EditorMetrics.edgeHeight,
                               width: contentFrame.width, height: EditorMetrics.edgeHeight)
        bottomEdge.frame = NSRect(x: contentFrame.minX, y: contentFrame.minY,
                                  width: contentFrame.width, height: EditorMetrics.edgeHeight)
        updateEdges()
    }

    func display(_ note: NoteDocument) {
        scrollView.stopWheelAnimation()
        textView.breakUndoCoalescing()
        textView.note = nil
        textView.string = note.text
        textView.note = note
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsLayout = true
        updateEdges()
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

/// Trackpads already supply precise deltas and momentum. Only coarse mouse
/// wheel events need interpolation between their otherwise abrupt jumps.
final class NoteScrollView: NSScrollView {
    // Keep the thumb over the white page, even when macOS prefers legacy
    // scrollers for a connected mouse. No reserved track or right-hand gutter.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

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
        let distance = -event.scrollingDeltaY * verticalLineScroll
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
    weak var scrollView: NoteScrollView?
    init(scrollView: NoteScrollView) { self.scrollView = scrollView }
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
        whiteFade.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        whiteFade.startPoint = start
        whiteFade.endPoint = end
        layer?.addSublayer(whiteFade)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
