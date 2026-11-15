import AppKit
import SwiftUI

// MARK: - CopyResumeCommandButton

/// 一键复制终端恢复命令按钮。
/// - 使用 AppKit `NSView` 点击层独立承接 `hitTest`，嵌套在可选中列表行或弹窗快捷行内时互不抢事件。
/// - 在菜单栏悬停弹窗中启用 `preventAppActivation = true`，通过 `acceptsFirstMouse` +
///   `shouldDelayWindowOrdering` + `NSApp.preventWindowOrdering()` 确保点击复制绝不抢占终端输入焦点。
/// - 点击后写入 `NSPasteboard.general` 并短暂展示“已复制”状态反馈。
struct CopyResumeCommandButton: View {
    let resumeCommand: SessionResumeCommand
    var compact: Bool = false
    var preventAppActivation: Bool = false
    var onHoverDesktopHintChange: ((Bool) -> Void)? = nil

    @State private var copied = false
    @State private var isHovered = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        buttonVisual
            .help(resumeCommand.helpText)
            .overlay {
                ResumeButtonClickOverlay(
                    toolTip: resumeCommand.helpText,
                    preventAppActivation: preventAppActivation,
                    isHovered: $isHovered,
                    onTap: performCopy
                )
            }
            .onChange(of: isHovered) { _, hovering in
                if resumeCommand.requiresDesktopResumeHint {
                    onHoverDesktopHintChange?(hovering)
                }
            }
    }

    private var buttonVisual: some View {
        HStack(spacing: compact ? 3.5 : 4.5) {
            Image(systemName: copied ? "checkmark" : "terminal")
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
            Text(copied ? tr("Copied", "已复制") : tr("Copy", "复制"))
                .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(
            copied
                ? PopoverPalette.barNormalFill
                : (isHovered ? PopoverPalette.primaryText : PopoverPalette.secondaryText)
        )
        .padding(.horizontal, compact ? 6.5 : 8)
        .padding(.vertical, compact ? 3 : 3.5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .fixedSize()
        .animation(.easeOut(duration: 0.14), value: copied)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var backgroundColor: Color {
        if copied {
            return Color.green.opacity(0.14)
        }
        if isHovered {
            return Color.primary.opacity(0.09)
        }
        return Color.primary.opacity(0.045)
    }

    private var borderColor: Color {
        if copied {
            return Color.green.opacity(0.35)
        }
        return Color.primary.opacity(isHovered ? 0.16 : 0.09)
    }

    private func performCopy() {
        SessionActions.copyResumeCommand(resumeCommand)

        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - AppKit Click Overlay

struct ResumeButtonClickOverlay: NSViewRepresentable {
    let toolTip: String
    let preventAppActivation: Bool
    @Binding var isHovered: Bool
    let onTap: () -> Void

    func makeNSView(context: Context) -> ResumeButtonClickNSView {
        let view = ResumeButtonClickNSView()
        view.toolTip = toolTip
        view.preventAppActivation = preventAppActivation
        view.onHoverChange = { hovering in
            isHovered = hovering
        }
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: ResumeButtonClickNSView, context: Context) {
        if nsView.toolTip != toolTip {
            nsView.toolTip = toolTip
        }
        nsView.preventAppActivation = preventAppActivation
        nsView.onHoverChange = { hovering in
            isHovered = hovering
        }
        nsView.onTap = onTap
    }
}

final class ResumeButtonClickNSView: NSView {
    var preventAppActivation: Bool = false
    var onHoverChange: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    private var isPressed = false
    private var trackingAreaRef: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        preventAppActivation
    }

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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if preventAppActivation {
            // 阻止点击按钮时激活 CCBar 进程或提升窗口层级，保护终端当前键盘输入焦点。
            NSApp.preventWindowOrdering()
        }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isPressed else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -2, dy: -2).contains(localPoint) {
            onTap?()
        }
    }
}

// MARK: - PopoverSearchField (Click-to-Activate Focus & Pause Auto-Dismiss)

/// 悬停弹窗专用搜索框：
/// 平时不抢焦点；仅当用户主动点击输入框准备检索时，触发 `onActivateFocus` 调用 `NSApp.activate`
/// 获取键盘焦点并暂停弹窗自动收起；按 `Esc` 触发 `onEscape` 恢复收起。
struct PopoverSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focusToken: Int = 0
    let onActivateFocus: () -> Void
    let onEscape: () -> Void
    var onMove: ((Int) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PopoverPalette.secondaryText)

            ActivatingTextFieldRepresentable(
                placeholder: placeholder,
                text: $text,
                focusToken: focusToken,
                onActivateFocus: onActivateFocus,
                onEscape: onEscape,
                onMove: onMove,
                onSubmit: onSubmit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PopoverPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(tr("Clear search", "清空搜索"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ActivatingTextFieldRepresentable: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let focusToken: Int
    let onActivateFocus: () -> Void
    let onEscape: () -> Void
    let onMove: ((Int) -> Void)?
    let onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> ActivatingSearchNSTextField {
        let field = ActivatingSearchNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.applyReadablePlaceholder(placeholder)
        field.delegate = context.coordinator
        field.onActivateFocus = onActivateFocus
        context.coordinator.lastFocusToken = focusToken
        return field
    }

    func updateNSView(_ nsView: ActivatingSearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEscape = onEscape
        context.coordinator.onMove = onMove
        context.coordinator.onSubmit = onSubmit
        nsView.onActivateFocus = onActivateFocus
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            if focusToken > 0 {
                // 全局快捷键唤出：面板已 makeKey，这里把输入焦点交给搜索框。
                DispatchQueue.main.async {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
        if nsView.currentPlaceholder != placeholder {
            nsView.applyReadablePlaceholder(placeholder)
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onEscape: () -> Void
        var onMove: ((Int) -> Void)?
        var onSubmit: (() -> Void)?
        var lastFocusToken = 0

        init(text: Binding<String>, onEscape: @escaping () -> Void) {
            self.text = text
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            MenuBarStatusController.shared.endSearchFocusIfUnpinned()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)), let onMove {
                onMove(1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)), let onMove {
                onMove(-1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit {
                onSubmit()
                return true
            }
            return false
        }
    }
}

final class ActivatingSearchNSTextField: NSTextField {
    var onActivateFocus: (() -> Void)?
    private(set) var currentPlaceholder: String = ""

    override var allowsVibrancy: Bool { false }

    func applyReadablePlaceholder(_ text: String) {
        currentPlaceholder = text
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // 用户主动点击搜索框：激活应用并将 Popover 置为 key window，使其可正常打字输入。
        onActivateFocus?()
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}


// MARK: - Search Highlight

/// 标题中命中搜索词的片段加粗并以强调色底纹标出（忽略大小写）。
struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = Color.accentColor.opacity(0.22)
                result[attrRange].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = range.upperBound
        }
        return result
    }
}

// MARK: - Session Actions (Copy / Terminal / Finder / Editor)

@MainActor
enum SessionActions {
    static func copyResumeCommand(_ command: SessionResumeCommand) {
        copy(command.command)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    nonisolated struct Editor: Identifiable, Sendable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    static let knownEditors: [Editor] = [
        Editor(name: "VS Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
        Editor(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
    ]

    static var installedEditors: [Editor] {
        knownEditors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static func open(_ path: String, with editor: Editor) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL, configuration: configuration)
    }

    static func isInstalled(_ terminal: ResumeTerminalApp) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) != nil
    }

    /// 在选定终端中新开窗口 / 标签执行恢复命令（会切换到该终端，属于用户主动操作）。
    static func runInTerminal(_ command: SessionResumeCommand, app requestedApp: ResumeTerminalApp? = nil) {
        runShellCommandInTerminal(command.command, app: requestedApp)
    }

    /// 在选定终端中新开窗口 / 标签执行任意 shell 命令。
    static func runShellCommandInTerminal(_ shellCommand: String, app requestedApp: ResumeTerminalApp? = nil) {
        let app = requestedApp ?? SettingsStore.shared.resumeTerminalApp
        switch app {
        case .terminal:
            runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(appleScriptEscaped(shellCommand))"
            end tell
            """)
        case .iTerm:
            runAppleScript("""
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(appleScriptEscaped(shellCommand))"
                end tell
            end tell
            """)
        case .ghostty:
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", "Ghostty", "--args", "-e", shell, "-lic", "\(shellCommand); exec \(shell) -l"]
            do {
                try process.run()
            } catch {
                AppLog.error(.app, "[resume] launch Ghostty failed: \(error.localizedDescription)")
                copy(shellCommand)
            }
        }
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            AppLog.error(.app, "[resume] AppleScript failed: \(error)")
            NSSound.beep()
        }
    }
}

// MARK: - Session Context Menu

/// 会话行右键菜单（弹窗快捷区与主窗口会话列表共用）。
struct SessionContextMenuItems: View {
    let record: SessionHistoryRecord
    var onDidPerform: () -> Void = {}

    var body: some View {
        let command = record.resumeCommand
        let terminal = SettingsStore.shared.resumeTerminalApp

        Button(tr("Copy Resume Command", "复制恢复命令")) {
            SessionActions.copyResumeCommand(command)
        }
        if SessionActions.isInstalled(terminal) {
            Button(tr("Resume in \(terminal.displayName)", "在 \(terminal.displayName) 中恢复")) {
                onDidPerform()
                SessionActions.runInTerminal(command, app: terminal)
            }
        }
        if let note = command.permissionNote {
            Text(note)
        }

        Divider()

        Button(tr("Copy Session ID", "复制会话 ID")) {
            SessionActions.copy(record.sessionID)
        }
        if let cwd = record.cwd, !cwd.isEmpty {
            Button(tr("Copy Working Directory", "复制工作目录")) {
                SessionActions.copy(cwd)
            }
            if record.cwdExists {
                Button(tr("Show in Finder", "在 Finder 中显示")) {
                    onDidPerform()
                    SessionActions.revealInFinder(cwd)
                }
                let editors = SessionActions.installedEditors
                if !editors.isEmpty {
                    Divider()
                    ForEach(editors) { editor in
                        Button(tr("Open Project in \(editor.name)", "用 \(editor.name) 打开项目")) {
                            onDidPerform()
                            SessionActions.open(cwd, with: editor)
                        }
                    }
                }
            } else {
                Text(tr("Directory no longer exists", "工作目录已不存在"))
            }
        }
    }
}

// MARK: - Privacy Helper

extension SessionHistoryRecord {
    /// 隐私模式下用于生成匿名标题的占位 `ConversationInfo`。
    @MainActor
    var privacyConversationInfo: ConversationInfo {
        ConversationInfo(
            key: key,
            conversationID: sessionID,
            app: origin.usageApp,
            title: primaryTitle,
            projectKey: cwd ?? "",
            projectName: projectName,
            projectPath: cwd ?? "",
            projectStatus: cwd == nil ? .unassigned : .available,
            projectSource: .cwd,
            gitBranch: nil,
            sourcePaths: [],
            firstAt: lastActiveAt,
            lastAt: lastActiveAt,
            includesSubtasks: false,
            cacheCreationAvailable: false
        )
    }
}

// MARK: - Google API Quick Launch

@MainActor
enum GoogleAPIQuickLaunch {
    static func resolveSession(appState: AppState) -> GoogleAPIAuthSession? {
        if let cached = appState.googleAPIAccount {
            return cached
        }
        return GoogleAPIAuth.load(
            preference: SettingsStore.shared.googleAPICredentialPreference,
            mode: SettingsStore.shared.googleAPIMode
        )
    }

    static func currentCommand(session: GoogleAPIAuthSession?) -> String {
        if let session {
            GoogleAPIAuth.syncLaunchEnvFile(session: session)
        }
        let settings = SettingsStore.shared
        return GoogleAPIAuth.buildQuickLaunchCommand(
            directory: settings.googleAPIDefaultDirectory,
            model: settings.googleAPIDefaultModel,
            yoloEnabled: settings.googleAPIYoloEnabled
        )
    }

    @discardableResult
    static func copyCommand(appState: AppState) -> Bool {
        guard let session = resolveSession(appState: appState) else { return false }
        let cmd = currentCommand(session: session)
        SessionActions.copy(cmd)
        return true
    }

    static func launchInTerminal(appState: AppState) {
        guard let session = resolveSession(appState: appState) else {
            appState.mainWindowSession.settingsCategory = .services
            appState.shouldPresentGoogleAPISheet = true
            MenuBarStatusController.shared.openMainWindow(tab: .settings)
            return
        }
        let cmd = currentCommand(session: session)
        if !MenuBarStatusController.shared.popoverState.isPinned {
            MenuBarStatusController.shared.closePopover()
        }
        SessionActions.runShellCommandInTerminal(cmd)
    }
}
