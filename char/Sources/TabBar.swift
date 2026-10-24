import AppKit

/// Titlebar tabs: click to select, drag to reorder, and close with the round x.
final class TabBarView: NSView {
    struct Item: Equatable {
        let id: ObjectIdentifier
        let title: String
        let toolTip: String?
        let isEdited: Bool
        let isActive: Bool
    }

    var items: [Item] = [] {
        didSet { if items != oldValue { rebuild() } }
    }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    private var itemViews: [TabItemView] = []
    private var draggedView: TabItemView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme() { itemViews.forEach { $0.applyTheme() } }

    func tabContains(_ windowPoint: NSPoint) -> Bool {
        !isHidden && itemViews.contains { $0.convert($0.bounds, to: nil).contains(windowPoint) }
    }

    private func rebuild() {
        // Reuse views by tab identity, so hover state and drags survive updates.
        var existing = Dictionary(itemViews.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let views = items.map { item -> TabItemView in
            let view = existing.removeValue(forKey: item.id) ?? TabItemView(item: item, bar: self)
            view.item = item
            return view
        }
        existing.values.forEach { $0.removeFromSuperview() }
        for view in views where view.superview !== self { addSubview(view) }
        itemViews = views
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard draggedView == nil else { return }
        for (view, frame) in zip(itemViews, slotFrames()) where view.frame != frame { view.frame = frame }
    }

    private func slotFrames() -> [NSRect] {
        let spacing = EditorMetrics.tabSpacing
        let widths = itemViews.map(\.preferredWidth)
        let available = bounds.width - spacing * CGFloat(max(0, widths.count - 1))
        var limit = EditorMetrics.tabMaxWidth
        if widths.reduce(0, +) > available {
            // Shrink the widest tabs first, leaving short names untouched.
            var remaining = available
            var count = CGFloat(widths.count)
            limit = remaining / count
            for width in widths.sorted() {
                guard width <= remaining / count else { limit = remaining / count; break }
                remaining -= width
                count -= 1
            }
            limit = max(EditorMetrics.tabMinWidth, limit)
        }
        let height = EditorMetrics.tabHeight
        var x: CGFloat = 0
        return widths.map { width in
            let frame = NSRect(x: x, y: round((bounds.height - height) / 2), width: round(min(width, limit)), height: height)
            x = frame.maxX + spacing
            return frame
        }
    }

    private func animateToSlots(except excluded: TabItemView? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            for (view, frame) in zip(itemViews, slotFrames()) where view !== excluded {
                view.animator().frame = frame
            }
        }
    }

    fileprivate func select(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        onSelect?(index)
    }

    fileprivate func close(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        onClose?(index)
    }

    fileprivate func track(_ view: TabItemView, with event: NSEvent) {
        guard let start = itemViews.firstIndex(of: view) else { return }
        onSelect?(start)
        guard let window, itemViews.count > 1 else { return }
        let startX = convert(event.locationInWindow, from: nil).x
        let originX = view.frame.minX
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              next.type == .leftMouseDragged {
            let x = convert(next.locationInWindow, from: nil).x
            if !dragging {
                guard abs(x - startX) >= 4 else { continue }
                dragging = true
                draggedView = view
                addSubview(view, positioned: .above, relativeTo: nil)
            }
            view.frame.origin.x = min(max(0, originX + x - startX), max(0, bounds.width - view.frame.width))
            reorder(view)
        }
        guard dragging else { return }
        draggedView = nil
        animateToSlots()
        if let end = itemViews.firstIndex(of: view), end != start { onMove?(start, end) }
    }

    private func reorder(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        // A neighbor swaps once the dragged tab's center crosses its center.
        let frames = slotFrames()
        let target = itemViews.indices.filter { $0 != index && frames[$0].midX < view.frame.midX }.count
        guard target != index else { return }
        itemViews.remove(at: index)
        itemViews.insert(view, at: target)
        animateToSlots(except: view)
    }
}

private final class TabItemView: NSView {
    var item: TabBarView.Item {
        didSet { if item != oldValue { update() } }
    }
    private weak var bar: TabBarView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { update() } }
    }

    init(item: TabBarView.Item, bar: TabBarView) {
        self.item = item
        self.bar = bar
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close Tab (⌘W)"
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    var preferredWidth: CGFloat {
        let text = ceil(label.intrinsicContentSize.width)
        let width = EditorMetrics.tabLeadingPadding + text + EditorMetrics.tabCloseSpacing
            + EditorMetrics.tabCloseSize + EditorMetrics.tabTrailingPadding
        return min(EditorMetrics.tabMaxWidth, max(EditorMetrics.tabMinWidth, width))
    }

    func applyTheme() { update() }

    private func update() {
        let palette = AppTheme.palette
        let font = palette.tabFont
        label.font = item.isEdited
            ? NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
            : font
        label.textColor = palette.text
        label.stringValue = item.title
        toolTip = item.toolTip ?? item.title
        closeButton.contentTintColor = palette.secondaryText
        closeButton.isHidden = !(item.isActive || isHovered)
        setAccessibilityLabel(item.isEdited ? "\(item.title), edited" : item.title)
        setAccessibilityValue(item.isActive)
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The bar sets frames directly, which doesn't schedule a layout pass.
        layoutContents()
    }

    override func layout() {
        super.layout()
        layoutContents()
    }

    private func layoutContents() {
        let size = EditorMetrics.tabCloseSize
        closeButton.frame = NSRect(x: bounds.maxX - EditorMetrics.tabTrailingPadding - size,
                                   y: round((bounds.height - size) / 2), width: size, height: size)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        // The label draws its text inset from its frame; extend into the padding
        // so a title exactly as wide as its measured size isn't truncated.
        let inset: CGFloat = 2
        label.frame = NSRect(x: EditorMetrics.tabLeadingPadding - inset, y: round((bounds.height - labelHeight) / 2),
                             width: max(0, closeButton.frame.minX - EditorMetrics.tabCloseSpacing
                                        - EditorMetrics.tabLeadingPadding + inset * 2),
                             height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor? = item.isActive ? AppTheme.palette.activeTab : isHovered ? AppTheme.palette.hoveredTab : nil
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: EditorMetrics.tabCornerRadius,
                     yRadius: EditorMetrics.tabCornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { bar?.track(self, with: event) }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { closeTab() } else { super.otherMouseDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        bar?.select(self)
        return true
    }

    @objc private func closeTab() { bar?.close(self) }
}
