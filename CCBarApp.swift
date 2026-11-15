import SwiftUI

@main
struct CCBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        appDelegate.bind(appState: state)
    }

    var body: some Scene {
        // 状态栏图标与悬停/固定弹窗由 AppKit `MenuBarStatusController`（NSStatusItem + NSPopover）接管；
        // 主窗口与欢迎窗按需由 `MenuBarStatusController` 创建，冷启动绝不自动弹出任何窗口。
        Settings {
            EmptyView()
        }
        .commands {
            AppCommands(appState: appState)
        }
    }
}

/// 运行环境判定。测试宿主同样是 CCBar.app，必须显式区分，否则单元测试会启动真实采集。
nonisolated enum AppRuntime {
    /// 测试宿主进程里必须为 true。判定取多重信号：不同 Xcode 版本注入的环境变量与
    /// 加载进来的 xctest bundle 名称并不一致，任一命中即认定处于测试环境。
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCTestSessionIdentifierKey"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        if Bundle.allFrameworks.contains(where: { $0.bundlePath.contains("XCTest.framework") }) { return true }
        return false
    }
}

/// 主窗口 / 刷新 / 设置 的全局快捷键。
/// ⌘Q 由 SwiftUI 默认提供；Esc 关闭或恢复收起弹窗由 `MenuBarStatusController` 统一处理。
private struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(tr("Check for Updates…", "检查更新…")) {
                AppUpdater.shared.checkForUpdates()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(tr("Preferences…", "设置")) {
                MenuBarStatusController.shared.openMainWindow(tab: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .windowList) {
            Button(tr("Statistics", "统计")) {
                MenuBarStatusController.shared.openMainWindow(tab: .stats)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(tr("Refresh now", "立即刷新")) {
                Task { await appState.refreshNow() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
