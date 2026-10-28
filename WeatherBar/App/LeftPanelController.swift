import AppKit
import SwiftUI

/// 悬停实况区时贴在主面板左侧出现的独立浮窗。
/// 它不属于主面板，主面板宽度和内容都不变。
@MainActor
final class LeftPanelController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show<Content: View>(beside parent: NSWindow, anchorTop: CGFloat, content: Content) {
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

        let parentFrame = parent.frame
        var origin = NSPoint(
            x: parentFrame.minX - size.width - Theme.leftPanelGap,
            y: parentFrame.maxY - anchorTop - size.height
        )

        // 避免浮窗跑出屏幕
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(visible.minX + 4, origin.x)
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height))
        }

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
    func reposition(beside parent: NSWindow, anchorTop: CGFloat) {
        guard let panel, panel.isVisible else { return }
        let size = panel.frame.size
        var origin = NSPoint(
            x: parent.frame.minX - size.width - Theme.leftPanelGap,
            y: parent.frame.maxY - anchorTop - size.height
        )
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(visible.minX + 4, origin.x)
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height))
        }
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
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
