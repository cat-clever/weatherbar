import AppKit

/// 用 NSTrackingArea 判断鼠标是否真的进入/离开了某个视图所在的窗口区域。
/// 比 SwiftUI 的 onHover 可靠：鼠标划过 NSScrollView 之类的原生子视图时不会误判为离开。
@MainActor
final class MouseHoverWatcher: NSObject {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private weak var trackedView: NSView?

    func attach(to view: NSView) {
        if let trackingArea, let trackedView {
            trackedView.removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
        trackedView = view
    }

    @objc func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    @objc func mouseExited(with event: NSEvent) {
        onExit?()
    }
}
