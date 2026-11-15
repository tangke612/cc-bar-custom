import AppKit
import SwiftUI

/// 主窗口与欢迎窗口管理（从 MenuBarStatusController 拆出）。
/// 冷启动保持 `.accessory`，只有打开窗口时临时切到 `.regular` 以显示 Dock 图标与菜单栏。
@MainActor
final class AppWindowManager {
    private weak var appState: AppState?
    private var mainWindow: NSWindow?
    private var mainWindowCloseObserver: NSObjectProtocol?
    private var onboardingWindow: NSWindow?
    private var onboardingWindowCloseObserver: NSObjectProtocol?

    func attach(appState: AppState) {
        self.appState = appState
    }

    func applyAppearance(_ mode: AppAppearanceMode) {
        let appearance = mode.nsAppearance
        mainWindow?.appearance = appearance
        mainWindow?.sheets.forEach { $0.appearance = appearance }
        onboardingWindow?.appearance = appearance
        onboardingWindow?.sheets.forEach { $0.appearance = appearance }
    }

    func openMainWindow(tab: MainTab) {
        guard let appState else { return }
        appState.mainTab = tab
        NSApp.setActivationPolicy(.regular)

        if let existing = mainWindow {
            existing.appearance = SettingsStore.shared.appAppearanceMode.nsAppearance
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

        mainWindow = window
        window.appearance = SettingsStore.shared.appAppearanceMode.nsAppearance
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func openOnboardingWindow() {
        guard let appState else { return }
        NSApp.setActivationPolicy(.regular)

        if let existing = onboardingWindow {
            existing.appearance = SettingsStore.shared.appAppearanceMode.nsAppearance
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

        onboardingWindow = window
        window.appearance = SettingsStore.shared.appAppearanceMode.nsAppearance
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
}
