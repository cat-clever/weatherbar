import AppKit
import SwiftUI

/// 悬停实况区时贴在主面板左侧出现的独立浮窗。
/// 它不属于主面板，主面板宽度和内容都不变。
@MainActor
final class LeftPanelController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show<Content: View>(beside parent: NSWindow, anchorRect: NSRect, anchorTop: CGFloat, content: Content) {
        let size = NSSize(width: Theme.leftPanelWidth, height: Theme.panelHeight)

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.level = parent.level
            self.panel = panel
        }

        guard let panel else { return }

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        Self.hideScrollers(in: hosting)

        let origin = Self.origin(beside: anchorRect, anchorTop: anchorTop, size: size,
                                 screen: parent.screen ?? NSScreen.main)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    /// 悬停不同横条时只挪位置，不重建内容
    func reposition(beside parent: NSWindow, anchorRect: NSRect, anchorTop: CGFloat) {
        guard let panel, panel.isVisible else { return }
        let origin = Self.origin(beside: anchorRect, anchorTop: anchorTop, size: panel.frame.size,
                                 screen: parent.screen ?? NSScreen.main)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    /// 浮窗贴在主面板可见区域的左边缘（用内容视图的真实矩形，避免被 popover 窗口的透明边距撑开）
    private static func origin(beside anchorRect: NSRect, anchorTop: CGFloat, size: NSSize,
                               screen: NSScreen?) -> NSPoint {
        var origin = NSPoint(
            x: anchorRect.minX - size.width - Theme.leftPanelGap,
            y: anchorRect.maxY - anchorTop - size.height
        )
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 4, origin.x)
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height))
        }
        return origin
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// SwiftUI 的 scrollIndicators(.never) 在部分系统版本上不彻底，这里再从 AppKit 层关掉滚动条
    private static func hideScrollers(in view: NSView) {
        disableScrollIndicators(in: view)
    }
}

/// 递归关掉所有 NSScrollView 的滚动条（不影响滚动本身）
func disableScrollIndicators(in view: NSView) {
    if let scrollView = view as? NSScrollView {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }
    for subview in view.subviews {
        disableScrollIndicators(in: subview)
    }
}
