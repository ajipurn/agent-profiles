import AppKit
import SwiftUI

/// Hosts SwiftUI content as an NSMenuItem's view at a fixed width.
///
/// NSMenu gives custom views no highlight or click behavior of their own, so
/// this draws the native selection background while the item is highlighted
/// and turns a mouse-up into `onClick`. Views without `onClick` ignore the
/// mouse entirely (use them on disabled items).
@MainActor
public final class MenuItemHostView: NSView {
    public let highlight = MenuHighlight()
    private let hosting: NSHostingView<AnyView>
    private let width: CGFloat
    private let highlightsOnHover: Bool
    private let onClick: ((NSPoint) -> Void)?

    /// `onClick` gets the click location in this view's coordinates.
    /// `highlightsOnHover: false` suits rows with their own controls (tabs).
    public init<Content: View>(width: CGFloat, highlightsOnHover: Bool = true,
                               onClick: ((NSPoint) -> Void)? = nil,
                               @ViewBuilder content: (MenuHighlight) -> Content) {
        self.width = width
        self.highlightsOnHover = highlightsOnHover
        self.onClick = onClick
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        hosting.rootView = AnyView(content(highlight).frame(width: width, alignment: .leading))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setFrameSize(NSSize(width: width, height: contentHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var contentHeight: CGFloat {
        max(1, ceil(hosting.fittingSize.height))
    }

    // NSMenu lays custom rows out from the intrinsic size.
    override public var intrinsicContentSize: NSSize {
        NSSize(width: width, height: contentHeight)
    }

    override public func layout() {
        super.layout()
        // Follow SwiftUI content that grew or shrank while the menu is open.
        let height = contentHeight
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
            invalidateIntrinsicContentSize()
        }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, frame.contains(point) else { return nil }
        return self // the hosted SwiftUI view never sees the mouse
    }

    override public func mouseUp(with event: NSEvent) {
        guard let onClick, enclosingMenuItem?.isEnabled ?? true else { return }
        onClick(convert(event.locationInWindow, from: nil))
    }

    override public func viewWillDraw() {
        let lit = onClick != nil && highlightsOnHover && (enclosingMenuItem?.isHighlighted ?? false)
            && (enclosingMenuItem?.isEnabled ?? false)
        if highlight.isHighlighted != lit { highlight.isHighlighted = lit }
        super.viewWillDraw()
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard highlight.isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}
