import AppKit
import QuartzCore
import SwiftUI

// MARK: - QuotaHoverPanel
//
// 自绘的菜单栏悬停面板，替代 NSPopover：
// - `.nonactivatingPanel`：显示、点击按钮都不会激活 CCBar 进程，终端始终保持前台；
// - `becomesKeyOnlyIfNeeded`：只有点击搜索框等需要键盘的控件时才成为 key window（仍不激活进程）；
// - 窗口 frame / alpha 完全由我们控制，弹出与收起动画走公开 API，不依赖 NSPopover 的私有窗口。

final class QuotaHoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - QuotaPanelContentController

/// 圆角毛玻璃容器 + 悬停跟踪 + SwiftUI 内容。
/// 注意：此处严禁定义泛型 NSHostingView<T> 子类，必须固定为具体类型 NSHostingView<AnyView>，
/// 规避 Swift 6.2.4 Release(-O) 下 SILPerformanceInliner 的已知无限递归编译器崩溃（见 FloatingPanelController.swift）。
final class QuotaPanelContentController: NSViewController {
    static let cornerRadius: CGFloat = 12
    static let panelWidth: CGFloat = 340

    private let hostingView: PanelHostingView
    private let onHoverChanged: @MainActor (Bool) -> Void
    private let onFittingSizeChanged: @MainActor (NSSize) -> Void

    init(
        rootView: AnyView,
        onHoverChanged: @escaping @MainActor (Bool) -> Void,
        onFittingSizeChanged: @escaping @MainActor (NSSize) -> Void
    ) {
        self.hostingView = PanelHostingView(rootView: rootView)
        self.onHoverChanged = onHoverChanged
        self.onFittingSizeChanged = onFittingSizeChanged
        super.init(nibName: nil, bundle: nil)
        hostingView.onLayoutFittingSize = { [weak self] size in
            self?.onFittingSizeChanged(size)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let effect = PanelEffectView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        // 固定为激活态材质：不激活进程也不会退化成灰暗的非激活外观。
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.autoresizingMask = [.width, .height]

        let tracking = PanelTrackingView(onHoverChanged: onHoverChanged)
        tracking.frame = effect.bounds
        tracking.autoresizingMask = [.width, .height]
        effect.addSubview(tracking)

        // 不用 Auto Layout 钉边：否则 SwiftUI 的 intrinsic size 会反向驱动窗口尺寸（以左下角为原点变化，顶部会跳动）。
        hostingView.frame = tracking.bounds
        hostingView.autoresizingMask = [.width, .height]
        tracking.addSubview(hostingView)

        view = effect
        effect.updateBorderColor()
    }

    /// 以固定宽度测量 SwiftUI 内容所需高度。
    func measureFittingSize() -> NSSize {
        _ = view
        if hostingView.frame.width != Self.panelWidth {
            hostingView.frame.size.width = Self.panelWidth
        }
        hostingView.layoutSubtreeIfNeeded()
        let fit = hostingView.fittingSize
        return NSSize(width: Self.panelWidth, height: max(fit.height, 60))
    }
}

// MARK: - Tracking & Hosting Views

final class PanelEffectView: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.10)).cgColor
    }
}

final class PanelTrackingView: NSView {
    private let onHoverChanged: @MainActor (Bool) -> Void
    private var trackingAreaRef: NSTrackingArea?

    init(onHoverChanged: @escaping @MainActor (Bool) -> Void) {
        self.onHoverChanged = onHoverChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreaRef == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged(false)
    }
}

final class PanelHostingView: NSHostingView<AnyView> {
    var onLayoutFittingSize: (@MainActor (NSSize) -> Void)?
    private var lastReportedSize: NSSize = .zero

    override var allowsVibrancy: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        let fit = fittingSize
        guard fit.width > 10, fit.height > 10,
              abs(fit.height - lastReportedSize.height) > 0.5 || abs(fit.width - lastReportedSize.width) > 0.5
        else { return }
        lastReportedSize = fit
        onLayoutFittingSize?(fit)
    }
}
