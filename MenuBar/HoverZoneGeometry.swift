import AppKit

/// 悬停面板的纯几何计算（无 AppKit 状态依赖，便于单元测试）。
nonisolated enum HoverZoneGeometry {
    /// 面板与菜单栏图标之间的竖向间距。
    static let anchorGap: CGFloat = 5
    /// 面板距屏幕左右边缘的最小留白。
    static let screenMargin: CGFloat = 8

    /// 以状态栏图标为锚点，计算面板在屏幕上的目标 frame：水平居中于图标，顶部贴在菜单栏下方，左右夹紧到可见区域。
    static func panelFrame(contentSize: NSSize, anchor: NSRect, screenVisibleFrame visible: NSRect) -> NSRect {
        let width = contentSize.width
        let height = min(contentSize.height, max(120, visible.height - anchorGap - screenMargin))
        var x = anchor.midX - width / 2
        x = max(visible.minX + screenMargin, min(x, visible.maxX - screenMargin - width))
        let top = min(anchor.minY, visible.maxY) - anchorGap
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
    }

    /// 光标是否位于「图标 + 图标与面板之间的衔接带 + 面板」联合热区内。
    /// - Parameters:
    ///   - anchor: 状态栏图标的屏幕坐标矩形。
    ///   - panel: 面板当前（或动画目标）屏幕坐标矩形；面板未显示时传 nil。
    static func isInActiveZone(cursor: NSPoint, anchor: NSRect?, panel: NSRect?) -> Bool {
        if let anchor, anchor.insetBy(dx: -4, dy: -4).contains(cursor) {
            return true
        }
        guard let panel else { return false }
        if panel.insetBy(dx: -4, dy: -4).contains(cursor) {
            return true
        }
        guard let anchor else { return false }
        // 衔接带：从图标底部到面板顶部之间、横跨图标宽度（左右各放宽 12pt）的矩形，防止鼠标下移途中被判定为离开。
        let bridgeBottom = panel.maxY - 4
        let bridgeTop = anchor.minY + 4
        guard bridgeTop > bridgeBottom else { return false }
        let bridge = NSRect(
            x: anchor.minX - 12,
            y: bridgeBottom,
            width: anchor.width + 24,
            height: bridgeTop - bridgeBottom
        )
        return bridge.contains(cursor)
    }
}
