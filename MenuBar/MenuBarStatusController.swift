import AppKit
import Carbon.HIToolbox
import Observation
import QuartzCore
import SwiftUI

// MARK: - Observable Panel Interaction State

@Observable
@MainActor
final class MenuBarPopoverState {
    var isShown: Bool = false
    var isPinned: Bool = false
    var isSearchFocused: Bool = false
    var desktopResumeHintVisible: Bool = false
    var searchText: String = ""
    /// 键盘 ↑↓ 选中的快捷会话行（nil 表示未选中）。
    var keyboardSelection: Int?
    /// 每次按回车复制时递增，快捷区据此复制选中行。
    var copySelectionToken: Int = 0
    /// 每次请求聚焦搜索框时递增（全局快捷键打开）。
    var focusSearchToken: Int = 0
}

// MARK: - MenuBarStatusController

/// 菜单栏状态项 + 自绘悬停面板（`QuotaHoverPanel`）控制器：
/// - 悬停图标满「弹出延迟」（默认 150ms）后弹出面板，全程不激活 CCBar，终端保持键盘焦点；
/// - 鼠标离开「图标 + 衔接带 + 面板」满「收起延迟」（默认 250ms）自动收起——不论面板是悬停还是点击打开的；
/// - 只有点面板右上角的图钉（或设置里开启「点击图标即固定」）才会固定面板，固定后不随鼠标离开收起；
/// - 点击图标切换显示 / 收起，`Esc` 收起，未固定时点击面板外任意位置也会收起；
/// - 全局快捷键 ⌃⌥K 打开面板并聚焦会话搜索。
@MainActor
final class MenuBarStatusController: NSObject {
    static let shared = MenuBarStatusController()

    nonisolated static let hoverPollIntervalNanoseconds: UInt64 = 40_000_000
    /// 搜索框聚焦时的最短收起延迟，避免打字过程中鼠标轻微移出就收起。
    static let searchFocusedMinimumCloseDelayMs = 1200

    let popoverState = MenuBarPopoverState()
    let windows = AppWindowManager()

    private var statusItem: NSStatusItem?
    private var buttonTrackingResponder: StatusButtonTrackingResponder?
    private var panel: QuotaHoverPanel?
    private var contentController: QuotaPanelContentController?
    private weak var appState: AppState?
    private var settingsObserversConfigured = false

    private var suppressHoverOpenUntilExit = false
    private var openedByHoverAt: Date?
    private var isClosing = false
    private var transitionGeneration: UInt64 = 0
    private var targetFrame: NSRect?

    private var hoverOpenTask: Task<Void, Never>?
    private var hoverWatchTask: Task<Void, Never>?
    private var badgeRefreshScheduled = false
    private var localKeyMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var hotKey: GlobalHotKey?

    private override init() {
        super.init()
    }

    func attach(appState: AppState) {
        guard !AppRuntime.isRunningUnitTests else { return }
        self.appState = appState
        windows.attach(appState: appState)
        setupStatusItemIfNeeded()
        setupPanelIfNeeded(appState: appState)
        observeBadgeInputs()
        observeOnboardingAndNotificationSettingsIfNeeded()
        observeHotKeySetting()
        updateStatusButtonBadge()
    }

    // MARK: - Setup

    private func setupStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])

            let responder = StatusButtonTrackingResponder(
                onMouseEntered: { [weak self] in self?.handleStatusButtonMouseEntered() },
                onMouseExited: { [weak self] in self?.handleStatusButtonMouseExited() }
            )
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: responder,
                userInfo: nil
            )
            button.addTrackingArea(area)
            buttonTrackingResponder = responder
        }

        statusItem = item
    }

    private func setupPanelIfNeeded(appState: AppState) {
        guard panel == nil else { return }

        let rootView = AnyView(
            PopoverRootView()
                .environment(appState)
                .environment(popoverState)
                .environment(\.controlActiveState, .key)
        )
        let controller = QuotaPanelContentController(
            rootView: rootView,
            onHoverChanged: { _ in },
            onFittingSizeChanged: { [weak self] size in
                self?.handleContentSizeChange(size)
            }
        )
        let panel = QuotaHoverPanel()
        panel.contentViewController = controller
        panel.onCancel = { [weak self] in self?.handleEscapeKey() }
        self.panel = panel
        self.contentController = controller
    }

    private func observeHotKeySetting() {
        withObservationTracking {
            _ = SettingsStore.shared.quickPanelHotKeyEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeHotKeySetting()
            }
        }
        if SettingsStore.shared.quickPanelHotKeyEnabled {
            if hotKey == nil {
                hotKey = GlobalHotKey(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey) { [weak self] in
                    self?.handleGlobalHotKey()
                }
            }
            hotKey?.register()
        } else {
            hotKey?.unregister()
        }
    }

    // MARK: - Reactive Menu Bar Badge & Settings Observation

    private func observeBadgeInputs() {
        withObservationTracking {
            guard let appState else { return }
            let settings = SettingsStore.shared
            _ = settings.menuBarWindow
            for provider in settings.orderedMenuBarProviders {
                _ = settings.effectiveMenuBarVisibility(for: provider.app)
            }
            for app in QuotaApp.allCases {
                _ = appState.quotaSnapshot(for: app)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleBadgeRefresh()
            }
        }
    }

    private func scheduleBadgeRefresh() {
        guard !badgeRefreshScheduled else { return }
        badgeRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.badgeRefreshScheduled = false
            self.updateStatusButtonBadge()
            self.observeBadgeInputs()
        }
    }

    private func observeOnboardingAndNotificationSettingsIfNeeded() {
        guard !settingsObserversConfigured else { return }
        settingsObserversConfigured = true
        observeOnboardingState()
        observeNotificationSettings()
    }

    private func observeOnboardingState() {
        withObservationTracking {
            _ = appState?.shouldShowOnboarding
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.appState?.shouldShowOnboarding == true {
                    self.appState?.shouldShowOnboarding = false
                    self.openOnboardingWindow()
                }
                self.observeOnboardingState()
            }
        }
    }

    private var lastObservedPrivacyMode = SettingsStore.shared.privacyMode
    private var lastObservedQuotaAlerts = SettingsStore.shared.quotaAlertsEnabled

    private func observeNotificationSettings() {
        withObservationTracking {
            _ = SettingsStore.shared.privacyMode
            _ = SettingsStore.shared.quotaAlertsEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                let privacy = SettingsStore.shared.privacyMode
                let alerts = SettingsStore.shared.quotaAlertsEnabled
                if privacy != self.lastObservedPrivacyMode {
                    self.lastObservedPrivacyMode = privacy
                    appState.quotaNotifications.settingsChanged(clearNotifications: privacy)
                } else if alerts != self.lastObservedQuotaAlerts {
                    self.lastObservedQuotaAlerts = alerts
                    appState.quotaNotifications.settingsChanged()
                }
                self.observeNotificationSettings()
            }
        }
    }

    private func updateStatusButtonBadge() {
        guard let appState, let button = statusItem?.button else { return }
        let settings = SettingsStore.shared
        let visibleProviders = settings.orderedMenuBarProviders.filter {
            settings.effectiveMenuBarVisibility(for: $0.app)
        }
        let snapshots = Dictionary(uniqueKeysWithValues: QuotaApp.allCases.compactMap { app in
            appState.quotaSnapshot(for: app).map { (app, $0) }
        })
        button.image = MenuBarBadgeImage.make(
            providers: visibleProviders,
            snapshots: snapshots,
            window: settings.menuBarWindow
        )
        button.setAccessibilityLabel(MenuBarBadgeImage.accessibilityLabel(
            providers: visibleProviders,
            snapshots: snapshots,
            window: settings.menuBarWindow
        ))
    }

    // MARK: - Hover Open

    private var isPanelVisible: Bool {
        panel?.isVisible == true && !isClosing
    }

    private func handleStatusButtonMouseEntered() {
        if isClosing {
            // 收起动画途中鼠标回到图标：直接拉回。
            restoreFromClosing()
            return
        }
        guard !isPanelVisible,
              !suppressHoverOpenUntilExit,
              SettingsStore.shared.popoverHoverOpenEnabled
        else { return }

        let delayMs = max(0, SettingsStore.shared.popoverHoverOpenDelayMs)
        hoverOpenTask?.cancel()
        hoverOpenTask = Task { @MainActor [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            guard !self.isPanelVisible,
                  !self.suppressHoverOpenUntilExit,
                  self.isCursorOverStatusButton()
            else { return }
            self.openedByHoverAt = Date()
            self.showPanel(pinned: false)
        }
    }

    private func handleStatusButtonMouseExited() {
        suppressHoverOpenUntilExit = false
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
    }

    // MARK: - Auto-Close Watcher

    /// 仅在面板显示期间运行（40ms 采样，收起后立即取消）。直接比较 `NSEvent.mouseLocation` 与几何热区，
    /// 不依赖 `mouseExited`——非激活状态下系统会漏发该事件，这是之前「移开不消失」的根因。
    private func startHoverWatchLoop() {
        hoverWatchTask?.cancel()
        hoverWatchTask = Task { @MainActor [weak self] in
            var outsideSince: ContinuousClock.Instant?
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.hoverPollIntervalNanoseconds)
                guard !Task.isCancelled, let self, self.isPanelVisible else { return }

                tick &+= 1
                if tick % 8 == 0 {
                    self.syncPanelSizeIfNeeded()
                }

                if self.popoverState.isPinned {
                    outsideSince = nil
                    continue
                }

                if self.isCursorInActiveZone() {
                    outsideSince = nil
                    continue
                }

                let now = ContinuousClock.now
                guard let since = outsideSince else {
                    outsideSince = now
                    continue
                }
                if now - since >= .milliseconds(self.effectiveCloseDelayMs) {
                    self.closePanel(animated: true)
                    return
                }
            }
        }
    }

    private var effectiveCloseDelayMs: Int {
        let base = max(100, SettingsStore.shared.popoverAutoCloseDelayMs)
        return popoverState.isSearchFocused ? max(base, Self.searchFocusedMinimumCloseDelayMs) : base
    }

    private func stopHoverWatchLoop() {
        hoverWatchTask?.cancel()
        hoverWatchTask = nil
    }

    // MARK: - Click, Pin, Search Focus, Escape, HotKey

    @objc private func handleStatusItemClick(_ sender: Any?) {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        let clickPins = SettingsStore.shared.popoverClickPins

        if isPanelVisible {
            // 悬停刚弹出时用户习惯性点一下图标：视为“我要打开”，不收起。
            if let openedAt = openedByHoverAt, Date().timeIntervalSince(openedAt) < 0.9, !popoverState.isPinned {
                openedByHoverAt = nil
                if clickPins { setPinned(true) }
                return
            }
            if clickPins && !popoverState.isPinned {
                setPinned(true)
                return
            }
            suppressHoverOpenUntilExit = true
            closePanel(animated: true)
        } else {
            suppressHoverOpenUntilExit = false
            openedByHoverAt = nil
            showPanel(pinned: clickPins)
        }
    }

    private func handleGlobalHotKey() {
        if isPanelVisible {
            closePanel(animated: true)
            return
        }
        // 键盘唤出时鼠标不在图标附近，先固定，避免立刻被自动收起。
        showPanel(pinned: true)
        focusSearchField()
    }

    private func focusSearchField() {
        guard let panel else { return }
        panel.makeKey()
        popoverState.isSearchFocused = true
        popoverState.focusSearchToken &+= 1
    }

    private func setPinned(_ pinned: Bool) {
        popoverState.isPinned = pinned
        syncStatusButtonHighlight()
    }

    /// 用户点击面板内搜索框：面板成为 key window 以接收键盘输入（`.nonactivatingPanel`，不激活进程、不抢终端前台）。
    func activateForSearch() {
        if isClosing { restoreFromClosing() }
        popoverState.isSearchFocused = true
        panel?.makeKey()
    }

    func endSearchFocusIfUnpinned() {
        popoverState.isSearchFocused = false
    }

    /// 按 Esc：清空搜索并收起面板（固定状态也收起）。
    func handleEscapeKey() {
        guard isPanelVisible else { return }
        popoverState.searchText = ""
        closePanel(animated: true)
    }

    func togglePinFromHeader() {
        setPinned(!popoverState.isPinned)
    }

    // MARK: - Show / Close

    private func showPanel(pinned: Bool) {
        guard let panel, let contentController, let anchor = statusButtonScreenRect() else { return }

        appState?.sessionHistory.refreshInBackground(minAge: 2.0)
        transitionGeneration &+= 1
        let gen = transitionGeneration
        isClosing = false

        popoverState.isPinned = pinned
        popoverState.isSearchFocused = false
        popoverState.keyboardSelection = nil
        popoverState.isShown = true

        let size = contentController.measureFittingSize()
        let visible = screenVisibleFrame(for: anchor)
        let finalFrame = HoverZoneGeometry.panelFrame(contentSize: size, anchor: anchor, screenVisibleFrame: visible)
        targetFrame = finalFrame

        let startFrame = finalFrame.offsetBy(dx: 0, dy: 6)
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        // orderFrontRegardless：显示面板但不激活 CCBar，终端保持前台与键盘焦点。
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == gen else { return }
                self.panel?.invalidateShadow()
            }
        }

        installMonitorsIfNeeded()
        startHoverWatchLoop()
        syncStatusButtonHighlight()
    }

    private func restoreFromClosing() {
        guard let panel, isClosing, let finalFrame = targetFrame else { return }
        transitionGeneration &+= 1
        isClosing = false
        popoverState.isShown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
        installMonitorsIfNeeded()
        startHoverWatchLoop()
    }

    func closePopover() {
        closePanel(animated: false)
    }

    func closePanel(animated: Bool) {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        stopHoverWatchLoop()
        removeMonitors()
        guard let panel, panel.isVisible else {
            finishClose()
            return
        }
        guard animated else {
            finishClose()
            return
        }
        guard !isClosing else { return }

        transitionGeneration &+= 1
        let gen = transitionGeneration
        isClosing = true
        statusItem?.button?.highlight(false)
        let base = targetFrame ?? panel.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(base.offsetBy(dx: 0, dy: 4), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == gen else { return }
                self.finishClose()
            }
        }
    }

    private func finishClose() {
        isClosing = false
        targetFrame = nil
        openedByHoverAt = nil
        stopHoverWatchLoop()
        removeMonitors()
        if let panel {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        popoverState.isPinned = false
        popoverState.isSearchFocused = false
        popoverState.isShown = false
        popoverState.desktopResumeHintVisible = false
        popoverState.keyboardSelection = nil
        syncStatusButtonHighlight()
    }

    // MARK: - Content Size Tracking (Keep Top Edge Fixed)

    private func handleContentSizeChange(_ size: NSSize) {
        guard isPanelVisible else { return }
        applyPanelHeight(size.height)
    }

    private func syncPanelSizeIfNeeded() {
        guard let contentController else { return }
        applyPanelHeight(contentController.measureFittingSize().height)
    }

    private func applyPanelHeight(_ height: CGFloat) {
        guard let panel, let anchor = statusButtonScreenRect(), !isClosing else { return }
        let current = targetFrame ?? panel.frame
        guard abs(current.height - height) > 0.5 else { return }
        let visible = screenVisibleFrame(for: anchor)
        let frame = HoverZoneGeometry.panelFrame(
            contentSize: NSSize(width: current.width, height: height),
            anchor: anchor,
            screenVisibleFrame: visible
        )
        targetFrame = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.invalidateShadow()
            }
        }
    }

    // MARK: - Monitors

    private func installMonitorsIfNeeded() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isPanelVisible else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    self.handleEscapeKey()
                    return nil
                }
                return event
            }
        }
        if globalMouseDownMonitor == nil {
            globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isPanelVisible, !self.popoverState.isPinned else { return }
                    if !self.isCursorInActiveZone() {
                        self.closePanel(animated: true)
                    }
                }
            }
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    // MARK: - Window Management (Delegated)

    func openMainWindow(tab: MainTab) {
        closePanel(animated: false)
        windows.openMainWindow(tab: tab)
    }

    func openOnboardingWindow() {
        closePanel(animated: false)
        windows.openOnboardingWindow()
    }

    func closeOnboardingWindow() {
        windows.closeOnboardingWindow()
    }

    // MARK: - Geometry Helpers

    private func syncStatusButtonHighlight() {
        statusItem?.button?.highlight(isPanelVisible && popoverState.isPinned)
    }

    private func statusButtonScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func screenVisibleFrame(for anchor: NSRect) -> NSRect {
        let screen = statusItem?.button?.window?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })
            ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func isCursorOverStatusButton() -> Bool {
        guard let rect = statusButtonScreenRect() else { return false }
        return rect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    private func isCursorInActiveZone() -> Bool {
        let panelRect: NSRect? = {
            guard let panel, panel.isVisible else { return nil }
            if let targetFrame { return targetFrame.union(panel.frame) }
            return panel.frame
        }()
        return HoverZoneGeometry.isInActiveZone(
            cursor: NSEvent.mouseLocation,
            anchor: statusButtonScreenRect(),
            panel: panelRect
        )
    }
}

// MARK: - StatusButtonTrackingResponder

private final class StatusButtonTrackingResponder: NSResponder {
    let onMouseEntered: @MainActor () -> Void
    let onMouseExited: @MainActor () -> Void

    init(
        onMouseEntered: @escaping @MainActor () -> Void,
        onMouseExited: @escaping @MainActor () -> Void
    ) {
        self.onMouseEntered = onMouseEntered
        self.onMouseExited = onMouseExited
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited()
    }
}
