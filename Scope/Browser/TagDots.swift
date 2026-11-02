import AppKit

/// Finder's colour tags, in Finder's order.
enum ColorTags {
    static let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
}

/// An item's colour tags as small overlapping dots after its name, as Finder
/// shows them. Tags without a colour aren't drawn.
@MainActor
final class TagDotsView: NSView {
    private static let diameter: CGFloat = 10
    private static let step: CGFloat = 6
    private static let leadingGap: CGFloat = 5

    private var colors: [NSColor] = []

    func show(_ tags: [String]) {
        let colors = tags.compactMap { Palette.tagColor($0) }
        guard colors != self.colors else { return }
        self.colors = colors
        isHidden = colors.isEmpty
        invalidateIntrinsicContentSize()
        needsDisplay = true
        setAccessibilityElement(!tags.isEmpty)
        setAccessibilityLabel(tags.isEmpty ? nil : "Tags: " + tags.joined(separator: ", "))
    }

    override var intrinsicContentSize: NSSize {
        guard !colors.isEmpty else { return NSSize(width: 0, height: Self.diameter) }
        return NSSize(
            width: Self.leadingGap + Self.diameter + Self.step * CGFloat(colors.count - 1) + 1,
            height: Self.diameter + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - Self.diameter) / 2
        // Drawn right to left so the first tag sits on top, like Finder.
        for (index, color) in colors.enumerated().reversed() {
            let rect = NSRect(
                x: Self.leadingGap + Self.step * CGFloat(index), y: y, width: Self.diameter, height: Self.diameter)
            let dot = NSBezierPath(ovalIn: rect)
            color.setFill()
            dot.fill()
            // A thin ring in the background colour keeps overlapping dots apart.
            NSColor.controlBackgroundColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }
}

/// The row of colour dots at the bottom of the right-click menu: click one
/// to add that tag to the selection, click a ticked one to take it off.
@MainActor
final class TagMenuView: NSView {
    private var buttons: [TagButton] = []
    private let onToggle: (String, Bool) -> Void

    /// `onToggle` gets the tag and whether to add (true) or remove it.
    init(onToggle: @escaping (String, Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for name in ColorTags.names {
            let button = TagButton(tag: name, color: Palette.tagColor(name) ?? .gray)
            button.target = self
            button.action = #selector(clicked(_:))
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Ticks the tags every selected item already has.
    func showApplied(_ tags: Set<String>) {
        for button in buttons { button.isApplied = tags.contains(button.tagName) }
    }

    @objc private func clicked(_ sender: TagButton) {
        let add = !sender.isApplied
        enclosingMenuItem?.menu?.cancelTracking()
        onToggle(sender.tagName, add)
    }
}

/// One colour dot in the tag row: a filled circle, with a tick when applied
/// and a ring on hover.
@MainActor
final class TagButton: NSButton {
    let tagName: String
    private let color: NSColor
    var isApplied = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(tag: String, color: NSColor) {
        tagName = tag
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        toolTip = tag
        setAccessibilityLabel(tag)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: hovering ? 1 : 3, dy: hovering ? 1 : 3))
        color.setFill()
        circle.fill()
        guard isApplied else { return }
        let tick = NSBezierPath()
        let box = bounds.insetBy(dx: 6, dy: 6)
        tick.move(to: NSPoint(x: box.minX, y: box.midY))
        tick.line(to: NSPoint(x: box.minX + box.width * 0.4, y: box.minY + box.height * 0.15))
        tick.line(to: NSPoint(x: box.maxX, y: box.maxY - box.height * 0.1))
        tick.lineWidth = 2
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        NSColor.white.setStroke()
        tick.stroke()
    }

    override var isFlipped: Bool { false }
}
