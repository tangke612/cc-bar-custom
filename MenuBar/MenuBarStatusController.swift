import AppKit
import Observation
import QuartzCore
import SwiftUI

// MARK: - Observable Popover Interaction State

@Observable
@MainActor
final class MenuBarPopoverState {
    var isShown: Bool = false
    var isPinned: Bool = false
    var isSearchFocused: Bool = false
    var desktopResumeHintVisible: Bool = false
    var searchText: String = ""
}

// MARK: - MenuBarStatusController

/// AppKit 状态栏控制器（`NSStatusItem` + `NSPopover`）及主窗口/欢迎窗管理：
/// - 悬停状态栏图标满 150ms 自动弹出面板，严禁调用 `NSApp.activate`，保护终端输入焦点；
/// - 移出状态栏图标且未停留在 Popover 区域满 250ms 自动收起面板；
/// - 左键点击状态栏图标切换“固定面板”状态，或点击搜索框检索时调用 `NSApp.activate` 获取输入焦点并暂停自动收起；
/// - 再次点击状态栏图标或按 `Esc` 取消固定并收起面板。
@MainActor
final class MenuBarStatusController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarStatusController()

    nonisolated static let hoverOpenDelayNanoseconds: UInt64 = 150_000_000
    nonisolated static let hoverCloseDelayNanoseconds: UInt64 = 250_000_000
    nonisolated static let hoverPollIntervalNanoseconds: UInt64 = 50_000_000

    let popoverState = MenuBarPopoverState()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var popoverViewController: PopoverContainerViewController?
    private var buttonTrackingResponder: StatusButtonTrackingResponder?
    private var buttonTrackingArea: NSTrackingArea?

    private weak var appState: AppState?
    private var mainWindow: NSWindow?
    private var mainWindowCloseObserver: NSObjectProtocol?
    private var onboardingWindow: NSWindow?
    private var onboardingWindowCloseObserver: NSObjectProtocol?
    private var appResignActiveObserver: NSObjectProtocol?
    private var settingsObserversConfigured = false

    private var isHoveringStatusButton = false
    private var isHoveringPopover = false
    private var suppressHoverOpenUntilExit = false

    private var transitionGeneration: UInt64 = 0
    private var isAnimatingOpen = false
    private var isClosingAnimated = false
    private var targetPopoverFrame: NSRect?
    private var pendingContentSize: NSSize?

    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var hoverWatchTask: Task<Void, Never>?
    private var badgeRefreshScheduled = false
    private var localKeyMonitor: Any?
    private var globalMouseDownMonitor: Any?

    private override init() {
        super.init()
    }

    func attach(appState: AppState) {
        guard !AppRuntime.isRunningUnitTests else { return }
        self.appState = appState
        setupStatusItemIfNeeded()
        setupPopoverIfNeeded(appState: appState)
        observeBadgeInputs()
        observeOnboardingAndNotificationSettingsIfNeeded()
        updateStatusButtonBadge()
    }

    // MARK: - Setup NSStatusItem & NSTrackingArea

    private func setupStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])

            // 在 statusItem.button 上挂载 NSTrackingArea（启用 mouseEnteredAndExited、activeAlways、inVisibleRect）
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
            self.buttonTrackingResponder = responder
            self.buttonTrackingArea = area
        }

        self.statusItem = item
    }

    private func setupPopoverIfNeeded(appState: AppState) {
        guard popoverViewController == nil else { return }

        let rootView = AnyView(
            PopoverRootView()
                .environment(appState)
                .environment(popoverState)
                .environment(\.controlActiveState, .key)
        )
        let controller = PopoverContainerViewController(
            rootView: rootView,
            shouldPreventActivation: { [weak self] in
                guard let self else { return true }
                return !self.popoverState.isPinned && !self.popoverState.isSearchFocused
            },
            onHoverChanged: { [weak self] hovering in
                self?.handlePopoverHoverChanged(hovering)
            },
            onSizeChanged: { [weak self] newSize in
                self?.applyPopoverContentSize(newSize)
            },
            onCancelOperation: { [weak self] in
                self?.handleEscapeKey()
            }
        )

        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        // 关闭系统默认生硬回弹与非激活态 0ms 硬切关闭，改由 GPU 窗口 alpha + 位移缓动曲线接管
        popover.animates = false
        popover.delegate = self
        self.popoverViewController = controller
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
                guard let self else { return }
                self.scheduleBadgeRefresh()
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
        let image = MenuBarBadgeImage.make(
            providers: visibleProviders,
            snapshots: snapshots,
            window: settings.menuBarWindow
        )
        button.image = image
        button.setAccessibilityLabel(MenuBarBadgeImage.accessibilityLabel(
            providers: visibleProviders,
            snapshots: snapshots,
            window: settings.menuBarWindow
        ))
    }

    // MARK: - Hover Debounce (150ms Open / 250ms Auto-Close)

    private func handleStatusButtonMouseEntered() {
        isHoveringStatusButton = true
        suppressHoverOpenUntilExit = false
        hoverCloseTask?.cancel()
        hoverCloseTask = nil

        if popover.isShown && isClosingAnimated {
            cancelAnimatedCloseAndRestore()
            return
        }

        guard !popover.isShown else { return }
        hoverOpenTask?.cancel()
        hoverOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hoverOpenDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard (!self.popover.isShown || self.isClosingAnimated),
                  !self.suppressHoverOpenUntilExit,
                  self.isCursorInsideStatusButton()
            else { return }
            self.showPopover(pinned: false, activateApp: false)
        }
    }

    private func handleStatusButtonMouseExited() {
        isHoveringStatusButton = false
        suppressHoverOpenUntilExit = false
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        scheduleHoverAutoCloseIfNeeded()
    }

    private func handlePopoverHoverChanged(_ hovering: Bool) {
        isHoveringPopover = hovering
        if hovering {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
            if popover.isShown && isClosingAnimated && !suppressHoverOpenUntilExit {
                cancelAnimatedCloseAndRestore()
            }
        } else {
            scheduleHoverAutoCloseIfNeeded()
        }
    }

    private func scheduleHoverAutoCloseIfNeeded(delayNanoseconds: UInt64 = hoverCloseDelayNanoseconds) {
        guard popover.isShown,
              !isClosingAnimated,
              !popoverState.isPinned,
              !popoverState.isSearchFocused
        else { return }

        hoverCloseTask?.cancel()
        hoverCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.popover.isShown,
                  !self.isClosingAnimated,
                  !self.popoverState.isPinned,
                  !self.popoverState.isSearchFocused
            else { return }

            if self.isCursorInActiveHoverZone() {
                return
            }

            self.closePopover(animated: true)
        }
    }

    /// 仅在 Popover 显示期间运行的轻量屏幕光标守卫（50ms 采样，面板关闭后立即取消，后台零 CPU 开销）。
    /// 彻底规避非激活 `.accessory` 状态下 `NSStatusBarWindow` / `NSHostingView` 偶发漏发 `mouseExited` 导致面板不自动消失的问题：
    /// 只要未处于固定态或搜索聚焦态，且光标连续离开「状态栏图标 + 衔接区 + Popover 窗口」满 250ms，即确定性自动收起。
    private func startHoverWatchLoop() {
        hoverWatchTask?.cancel()
        hoverWatchTask = Task { @MainActor [weak self] in
            var outsideSince: ContinuousClock.Instant?
            let closeThreshold = Duration.nanoseconds(Int64(Self.hoverCloseDelayNanoseconds))

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.hoverPollIntervalNanoseconds)
                guard !Task.isCancelled, let self, self.popover.isShown, !self.isClosingAnimated else { return }

                if self.popoverState.isPinned || self.popoverState.isSearchFocused {
                    outsideSince = nil
                    continue
                }

                if self.isCursorInActiveHoverZone() {
                    outsideSince = nil
                    self.hoverCloseTask?.cancel()
                    self.hoverCloseTask = nil
                } else {
                    let now = ContinuousClock.now
                    if let since = outsideSince {
                        if now - since >= closeThreshold {
                            self.closePopover(animated: true)
                            return
                        }
                    } else {
                        outsideSince = now
                    }
                }
            }
        }
    }

    private func stopHoverWatchLoop() {
        hoverWatchTask?.cancel()
        hoverWatchTask = nil
    }

    // MARK: - Click Pinning, Search Focus & Escape Handling

    @objc private func handleStatusItemClick(_ sender: Any?) {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        hoverCloseTask?.cancel()
        hoverCloseTask = nil

        if popover.isShown && !isClosingAnimated {
            if popoverState.isPinned || popoverState.isSearchFocused {
                // 再次左键点击图标：取消固定并丝滑收起面板
                suppressHoverOpenUntilExit = true
                closePopover(animated: true)
            } else {
                // 悬停态下左键点击图标：切换为“固定面板”态，调用 NSApp.activate 获取输入焦点并暂停自动收起
                popoverState.isPinned = true
                syncStatusButtonHighlight()
                activateAppAndFocusPopoverWindow()
            }
        } else {
            suppressHoverOpenUntilExit = false
            showPopover(pinned: true, activateApp: true)
        }
    }

    /// 用户主动点击弹窗内的搜索输入框准备打字检索时调用：
    /// 调用 `NSApp.activate` 获取输入焦点，并在检索期间暂停自动收起（点击弹窗外部或按 Esc 即恢复/收起）。
    func activateForSearch() {
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
        if isClosingAnimated {
            cancelAnimatedCloseAndRestore()
        }
        popoverState.isSearchFocused = true
        syncStatusButtonHighlight()
        activateAppAndFocusPopoverWindow()
    }

    func endSearchFocusIfUnpinned() {
        guard popoverState.isSearchFocused else { return }
        popoverState.isSearchFocused = false
        if popover.isShown, !popoverState.isPinned, !isCursorInActiveHoverZone() {
            scheduleHoverAutoCloseIfNeeded()
        }
    }

    /// 按 Esc 或点击取消固定时恢复收起。
    func handleEscapeKey() {
        guard popover.isShown else { return }
        popoverState.isPinned = false
        popoverState.isSearchFocused = false
        popoverState.searchText = ""
        syncStatusButtonHighlight()
        popoverWindow?.makeFirstResponder(nil)
        closePopover(animated: true)
    }

    func togglePinFromHeader() {
        if popoverState.isPinned || popoverState.isSearchFocused {
            popoverState.isPinned = false
            popoverState.isSearchFocused = false
            syncStatusButtonHighlight()
            popoverWindow?.makeFirstResponder(nil)
            if !isCursorInActiveHoverZone() {
                scheduleHoverAutoCloseIfNeeded()
            }
        } else {
            popoverState.isPinned = true
            syncStatusButtonHighlight()
            activateAppAndFocusPopoverWindow()
        }
    }

    // MARK: - Show / Close Popover (GPU Window Alpha + Glide Choreography)

    private func applyPopoverContentSize(_ newSize: NSSize) {
        guard newSize.width > 10, newSize.height > 10 else { return }

        if !popover.isShown {
            if popover.contentSize != newSize {
                popover.contentSize = newSize
            }
            return
        }

        guard !isClosingAnimated else { return }

        if isAnimatingOpen {
            pendingContentSize = newSize
            return
        }

        let deltaH = abs(popover.contentSize.height - newSize.height)
        let deltaW = abs(popover.contentSize.width - newSize.width)
        guard deltaH > 0.5 || deltaW > 0.5 else { return }

        targetPopoverFrame = nil
        popover.animates = deltaH > 2
        popover.contentSize = newSize
        popover.animates = false
    }

    private func showPopover(pinned: Bool, activateApp: Bool) {
        guard let button = statusItem?.button else { return }

        appState?.sessionHistory.refreshInBackground(minAge: 2.0)

        popoverState.isPinned = pinned
        if !pinned {
            popoverState.isSearchFocused = false
        }
        popoverState.isShown = true

        if popover.isShown {
            if isClosingAnimated {
                cancelAnimatedCloseAndRestore()
            }
            syncStatusButtonHighlight()
            if activateApp {
                activateAppAndFocusPopoverWindow()
            }
            return
        }

        transitionGeneration &+= 1
        let gen = transitionGeneration
        isClosingAnimated = false
        pendingContentSize = nil
        popover.animates = false

        if let fit = popoverViewController?.measureFittingSize() {
            popover.contentSize = fit
        }

        // 悬停触发 show 时严禁调用 NSApp.activate！
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverViewController?.forceActiveVisualEffectState()
        installPopoverLifecycleMonitorsIfNeeded()
        startHoverWatchLoop()
        syncStatusButtonHighlight()

        if let window = popoverWindow {
            let finalFrame = window.frame
            targetPopoverFrame = finalFrame
            // 纯窗口原点平移（尺寸不变，不触发 AutoLayout / SwiftUI 重排，由 WindowServer 120Hz GPU 合成）
            let startFrame = finalFrame.offsetBy(dx: 0, dy: 7)
            window.alphaValue = 0
            window.setFrame(startFrame, display: false)
            isAnimatingOpen = true

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                window.animator().alphaValue = 1.0
                window.animator().setFrame(finalFrame, display: false)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transitionGeneration == gen else { return }
                    self.isAnimatingOpen = false
                    self.targetPopoverFrame = window.frame
                    if let pending = self.pendingContentSize {
                        self.pendingContentSize = nil
                        self.applyPopoverContentSize(pending)
                    }
                }
            }
        }

        if activateApp {
            activateAppAndFocusPopoverWindow()
        }
    }

    private func cancelAnimatedCloseAndRestore() {
        guard popover.isShown else { return }
        transitionGeneration &+= 1
        let gen = transitionGeneration
        isClosingAnimated = false
        isAnimatingOpen = true
        popoverState.isShown = true
        installPopoverLifecycleMonitorsIfNeeded()
        startHoverWatchLoop()

        guard let window = popoverWindow else {
            isAnimatingOpen = false
            return
        }

        let restFrame = targetPopoverFrame ?? window.frame.offsetBy(dx: 0, dy: -4)
        targetPopoverFrame = restFrame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            window.animator().alphaValue = 1.0
            window.animator().setFrame(restFrame, display: false)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == gen else { return }
                self.isAnimatingOpen = false
                self.targetPopoverFrame = window.frame
            }
        }
    }

    func closePopover(animated: Bool = true) {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
        stopHoverWatchLoop()

        guard popover.isShown else {
            finishCloseImmediately()
            return
        }

        guard animated, let window = popoverWindow else {
            finishCloseImmediately()
            return
        }

        guard !isClosingAnimated else { return }

        transitionGeneration &+= 1
        let gen = transitionGeneration
        isAnimatingOpen = false
        isClosingAnimated = true
        pendingContentSize = nil
        statusItem?.button?.highlight(false)

        let baseFrame = targetPopoverFrame ?? window.frame
        targetPopoverFrame = baseFrame
        let exitFrame = baseFrame.offsetBy(dx: 0, dy: 5)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.155
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            window.animator().alphaValue = 0.0
            window.animator().setFrame(exitFrame, display: false)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == gen else { return }
                self.finishCloseImmediately()
            }
        }
    }

    private func finishCloseImmediately() {
        isAnimatingOpen = false
        isClosingAnimated = false
        pendingContentSize = nil
        targetPopoverFrame = nil
        stopHoverWatchLoop()
        removePopoverLifecycleMonitors()

        let win = popoverWindow
        popover.animates = false
        if popover.isShown {
            popover.performClose(nil)
        }
        win?.alphaValue = 1.0

        popoverState.isPinned = false
        popoverState.isSearchFocused = false
        popoverState.isShown = false
        popoverState.desktopResumeHintVisible = false
        isHoveringPopover = false
        syncStatusButtonHighlight()
    }

    // MARK: - Main Window & Onboarding Window Management (Silent Cold Launch)

    func openMainWindow(tab: MainTab) {
        guard let appState else { return }
        closePopover(animated: false)
        appState.mainTab = tab
        NSApp.setActivationPolicy(.regular)

        if let existing = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: AnyView(
                MainWindowRootView()
                    .environment(appState)
            )
        )
        hosting.sceneBridgingOptions = .all

        let window = NSWindow(contentViewController: hosting)
        window.title = "CCBar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.minSize = NSSize(width: 1040, height: 520)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("CCBarMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("CCBarMainWindow")

        if let obs = mainWindowCloseObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mainWindow = nil
                if self.onboardingWindow == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func openOnboardingWindow() {
        guard let appState else { return }
        closePopover(animated: false)
        NSApp.setActivationPolicy(.regular)

        if let existing = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: AnyView(
                OnboardingView()
                    .environment(appState)
            )
        )
        hosting.sceneBridgingOptions = .all

        let window = NSWindow(contentViewController: hosting)
        window.title = tr("Welcome", "欢迎")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 620, height: 520))
        window.center()
        window.isReleasedWhenClosed = false

        if let obs = onboardingWindowCloseObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        onboardingWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onboardingWindow = nil
                if self.mainWindow == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
        if mainWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func activateAppAndFocusPopoverWindow() {
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow?.makeKeyAndOrderFront(nil)
    }

    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    private func syncStatusButtonHighlight() {
        statusItem?.button?.highlight(popover.isShown && popoverState.isPinned)
    }

    private func installPopoverLifecycleMonitorsIfNeeded() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53, let self, self.popover.isShown {
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
                    guard let self, self.popover.isShown else { return }
                    guard !self.popoverState.isPinned else { return }
                    if !self.isCursorInsidePopoverWindow() && !self.isCursorInsideStatusButton() {
                        self.closePopover()
                    }
                }
            }
        }

        if appResignActiveObserver == nil {
            appResignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.popover.isShown else { return }
                    if !self.popoverState.isPinned {
                        self.popoverState.isSearchFocused = false
                        if !self.isCursorInActiveHoverZone() {
                            self.closePopover()
                        }
                    }
                }
            }
        }
    }

    private func removePopoverLifecycleMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let appResignActiveObserver {
            NotificationCenter.default.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        popoverViewController?.forceActiveVisualEffectState()
    }

    func popoverDidClose(_ notification: Notification) {
        isAnimatingOpen = false
        isClosingAnimated = false
        pendingContentSize = nil
        targetPopoverFrame = nil
        stopHoverWatchLoop()
        removePopoverLifecycleMonitors()
        popoverState.isShown = false
        popoverState.isPinned = false
        popoverState.isSearchFocused = false
        popoverState.desktopResumeHintVisible = false
        isHoveringPopover = false
        syncStatusButtonHighlight()
    }

    // MARK: - Screen Geometry Helpers

    private func statusButtonScreenRect() -> NSRect? {
        guard let button = statusItem?.button,
              let btnWindow = button.window
        else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return btnWindow.convertToScreen(rectInWindow)
    }

    private func isCursorInsideStatusButton() -> Bool {
        guard let rect = statusButtonScreenRect() else { return false }
        return rect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    private func isCursorInsidePopoverWindow() -> Bool {
        guard popover.isShown, let window = popoverWindow else { return false }
        let effectiveRect = targetPopoverFrame.map { $0.union(window.frame) } ?? window.frame
        return effectiveRect.insetBy(dx: -4, dy: -6).contains(NSEvent.mouseLocation)
    }

    /// 判断鼠标当前是否位于「状态栏图标 + 图标至弹窗顶部箭头衔接带 + Popover 窗口」联合热区内。
    private func isCursorInActiveHoverZone() -> Bool {
        let cursor = NSEvent.mouseLocation

        if let buttonRect = statusButtonScreenRect() {
            if buttonRect.insetBy(dx: -4, dy: -4).contains(cursor) {
                return true
            }
            if popover.isShown, let window = popoverWindow {
                let popRect = targetPopoverFrame.map { $0.union(window.frame) } ?? window.frame
                if popRect.insetBy(dx: -4, dy: -6).contains(cursor) {
                    return true
                }
                // 衔接带：允许光标从顶部菜单栏图标平滑下移穿过箭头进入 Popover，不会在缝隙处误判为移出
                if popRect.maxY <= buttonRect.maxY + 10 {
                    let minX = min(buttonRect.minX - 10, popRect.midX - 28)
                    let maxX = max(buttonRect.maxX + 10, popRect.midX + 28)
                    let minY = popRect.maxY - 8
                    let maxY = buttonRect.maxY + 2
                    if maxY > minY {
                        let bridgeRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                        if bridgeRect.contains(cursor) {
                            return true
                        }
                    }
                }
                return false
            }
        }

        return isCursorInsidePopoverWindow()
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
        MainActor.assumeIsolated {
            onMouseEntered()
        }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated {
            onMouseExited()
        }
    }
}

// MARK: - PopoverContainerViewController & Non-Activating Hosting View
//
// 注意：此处严禁定义泛型 NSHostingView<T> 子类，必须固定为具体类型 NSHostingView<AnyView>，
// 规避 Swift 6.2.4 Release(-O) 下 SILPerformanceInliner 的已知无限递归编译器崩溃（见 FloatingPanelController.swift）。

private final class PopoverContainerViewController: NSViewController {
    private let hostingView: NonActivatingPopoverHostingView
    private let onHoverChanged: @MainActor (Bool) -> Void
    private let onSizeChanged: @MainActor (NSSize) -> Void
    private let onCancelOperation: @MainActor () -> Void

    init(
        rootView: AnyView,
        shouldPreventActivation: @escaping @MainActor () -> Bool,
        onHoverChanged: @escaping @MainActor (Bool) -> Void,
        onSizeChanged: @escaping @MainActor (NSSize) -> Void,
        onCancelOperation: @escaping @MainActor () -> Void
    ) {
        self.hostingView = NonActivatingPopoverHostingView(rootView: rootView)
        self.onHoverChanged = onHoverChanged
        self.onSizeChanged = onSizeChanged
        self.onCancelOperation = onCancelOperation
        super.init(nibName: nil, bundle: nil)

        self.hostingView.shouldPreventActivation = shouldPreventActivation
        self.hostingView.onLayoutFittingSize = { [weak self] size in
            self?.onSizeChanged(size)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let trackingView = PopoverContentTrackingView(onHoverChanged: onHoverChanged)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        trackingView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: trackingView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor),
        ])
        self.view = trackingView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        forceActiveVisualEffectState()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelOperation()
    }

    /// 悬停模式下不调用 `NSApp.activate`，`NSPopover` 底层 `NSVisualEffectView` 默认跟随窗口激活态而退化为灰暗非激活材质。
    /// 这里递归将其固定为 `.active`，保证不抢终端焦点的同时依然保持清晰通透的原生材质对比度。
    func forceActiveVisualEffectState() {
        guard let root = view.window?.contentView?.superview ?? view.window?.contentView else { return }
        Self.activateVisualEffectViews(in: root)
    }

    private static func activateVisualEffectViews(in view: NSView) {
        if let effectView = view as? NSVisualEffectView, effectView.state != .active {
            effectView.state = .active
        }
        for subview in view.subviews {
            activateVisualEffectViews(in: subview)
        }
    }

    func measureFittingSize() -> NSSize? {
        _ = view
        if view.frame.width != 340 {
            view.frame.size.width = 340
        }
        hostingView.layoutSubtreeIfNeeded()
        let fit = hostingView.fittingSize
        guard fit.width > 10, fit.height > 10 else { return nil }
        preferredContentSize = fit
        return fit
    }
}

private final class PopoverContentTrackingView: NSView {
    private let onHoverChanged: @MainActor (Bool) -> Void
    private var trackingAreaRef: NSTrackingArea?

    init(onHoverChanged: @escaping @MainActor (Bool) -> Void) {
        self.onHoverChanged = onHoverChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
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
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated {
            onHoverChanged(true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated {
            onHoverChanged(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated {
            onHoverChanged(false)
        }
    }
}

private final class NonActivatingPopoverHostingView: NSHostingView<AnyView> {
    var shouldPreventActivation: (@MainActor () -> Bool)?
    var onLayoutFittingSize: (@MainActor (NSSize) -> Void)?
    private var lastReportedSize: NSSize = .zero

    override var allowsVibrancy: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        MainActor.assumeIsolated {
            shouldPreventActivation?() ?? false
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            if shouldPreventActivation?() == true {
                NSApp.preventWindowOrdering()
            }
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        let fit = fittingSize
        guard fit.width > 10, fit.height > 10, fit != lastReportedSize else { return }
        lastReportedSize = fit
        MainActor.assumeIsolated {
            onLayoutFittingSize?(fit)
        }
    }
}
