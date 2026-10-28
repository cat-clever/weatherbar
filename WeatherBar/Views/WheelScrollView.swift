import AppKit
import SwiftUI

/// 横向滚动容器：鼠标滚轮（纵向增量）也能横向滚动，且不显示任何滚动条。
/// SwiftUI 的 ScrollView(.horizontal) 嵌在竖向 ScrollView 里时收不到鼠标滚轮，这里用 NSScrollView 兜住。
struct HorizontalWheelScroll<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    var onHover: ((Bool) -> Void)?
    let content: Content

    init(contentWidth: CGFloat, onHover: ((Bool) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.contentWidth = contentWidth
        self.onHover = onHover
        self.content = content()
    }

    func makeNSView(context: Context) -> WheelScrollView {
        let scroll = WheelScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.onHoverChange = onHover

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 80)
        scroll.documentView = hosting
        return scroll
    }

    func updateNSView(_ scroll: WheelScrollView, context: Context) {
        scroll.onHoverChange = onHover
        guard let hosting = scroll.documentView as? NSHostingView<Content> else { return }
        hosting.rootView = content
        var frame = hosting.frame
        frame.size.width = contentWidth
        hosting.frame = frame
    }
}

final class WheelScrollView: NSScrollView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    // SwiftUI 的 onHover 套在 NSViewRepresentable 上不触发，这里自己用 tracking area 处理
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func layout() {
        super.layout()
        guard let document = documentView else { return }
        if document.frame.height != contentView.bounds.height {
            var frame = document.frame
            frame.size.height = contentView.bounds.height
            document.frame = frame
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        guard dy > dx, let document = documentView else {
            super.scrollWheel(with: event)
            return
        }

        let maxX = max(0, document.frame.width - contentView.bounds.width)
        guard maxX > 0 else {
            super.scrollWheel(with: event)
            return
        }

        // 纵向滚轮换算成横向位移
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        var origin = contentView.bounds.origin
        origin.x = min(maxX, max(0, origin.x - step))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}
