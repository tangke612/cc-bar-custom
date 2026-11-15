import Foundation

// MARK: - Shell Path Escaping

nonisolated enum ShellPathEscaper {
    /// 统一单引号转义：将路径中的 `'` 替换为 `'\''` 并整体使用单引号包裹，兼容空格与特殊字符。
    static func singleQuoted(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - User Preferences (Resume Permission / Terminal)

/// 恢复命令附加权限参数的策略。
nonisolated enum ResumePermissionMode: String, CaseIterable, Identifiable, Sendable {
    /// 继承原会话的启动权限（Codex 读 turn_context，agy 读启动日志，Claude 读 permissionMode）。
    case inherit
    /// 始终以完全放行（YOLO）恢复。
    case fullAccess
    /// 不附加任何权限参数，按各 CLI 当前默认配置恢复。
    case standard

    var id: String { rawValue }
}

/// 「在终端中恢复」使用的终端 App。
nonisolated enum ResumeTerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm
    case ghostty

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm"
        case .ghostty: return "Ghostty"
        }
    }
}

// MARK: - Session Launch Permission (Read-Only Detected)

/// 从本机会话记录中只读还原出的原会话启动权限。
nonisolated struct SessionLaunchPermission: Sendable, Codable, Equatable, Hashable {
    /// Codex `turn_context.approval_policy`（on-request / never / untrusted / on-failure）。
    var codexApproval: String?
    /// Codex `turn_context.sandbox_policy.type`（read-only / workspace-write / danger-full-access）。
    var codexSandbox: String?
    /// agy `--dangerously-skip-permissions` / Claude `bypassPermissions`。nil 表示未知。
    var skipsPermissions: Bool?
    /// Claude Code `permissionMode`（default / acceptEdits / plan / bypassPermissions）。
    var claudePermissionMode: String?
    /// true 表示原会话没有可查记录，按「最近一次 agy 启动方式」推断。
    var isInferred: Bool = false

    static let codexApprovalValues: Set<String> = ["on-request", "never", "untrusted", "on-failure"]
    static let codexSandboxValues: Set<String> = ["read-only", "workspace-write", "danger-full-access"]

    var isCodexFullAccess: Bool {
        codexApproval == "never" && codexSandbox == "danger-full-access"
    }
}

// MARK: - Session Origin & Resume Command

nonisolated enum SessionOrigin: String, Sendable, Codable, Equatable, Hashable {
    case codex
    case antigravityCLI
    case antigravityDesktop
    case claudeCode

    var usageApp: UsageApp {
        switch self {
        case .codex: return .codex
        case .antigravityCLI, .antigravityDesktop: return .antigravity
        case .claudeCode: return .claude
        }
    }

    var quotaApp: QuotaApp {
        switch self {
        case .codex: return .codex
        case .antigravityCLI, .antigravityDesktop: return .antigravity
        case .claudeCode: return .claude
        }
    }

    @MainActor
    var sourceBadge: String? {
        switch self {
        case .codex, .claudeCode:
            return nil
        case .antigravityCLI:
            return "CLI"
        case .antigravityDesktop:
            return tr("Desktop", "桌面端")
        }
    }
}

nonisolated struct SessionResumeCommand: Sendable, Equatable {
    let origin: SessionOrigin
    let sessionID: String
    let cwd: String?
    let command: String
    /// 实际附加的权限参数（空串表示未附加）。
    let permissionFlags: String
    /// 权限参数来源说明（用于悬浮提示）。
    let permissionSource: PermissionSource

    nonisolated enum PermissionSource: Sendable, Equatable {
        case none
        case inherited
        case inferred
        case forcedFullAccess
    }

    /// 按会话来源、工作目录与权限策略拼接终端恢复命令。
    static func build(
        origin: SessionOrigin,
        sessionID: String,
        cwd: String?,
        permission: SessionLaunchPermission? = nil,
        mode: ResumePermissionMode = .standard
    ) -> SessionResumeCommand {
        let cleanID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCwd = Self.normalizedCwd(cwd)
        let cdPrefix = cleanCwd.map { "cd \(ShellPathEscaper.singleQuoted($0)) && " } ?? ""
        let (flags, source) = Self.permissionFlags(origin: origin, permission: permission, mode: mode)
        let flagPart = flags.isEmpty ? "" : " \(flags)"

        let tail: String
        switch origin {
        case .codex:
            tail = "codex resume\(flagPart) \(cleanID)"
        case .antigravityCLI:
            tail = "agy\(flagPart) --conversation \(cleanID)"
        case .antigravityDesktop:
            tail = "agy\(flagPart)"
        case .claudeCode:
            tail = "claude\(flagPart) --resume \(cleanID)"
        }

        return SessionResumeCommand(
            origin: origin,
            sessionID: cleanID,
            cwd: cleanCwd,
            command: cdPrefix + tail,
            permissionFlags: flags,
            permissionSource: flags.isEmpty ? .none : source
        )
    }

    static func permissionFlags(
        origin: SessionOrigin,
        permission: SessionLaunchPermission?,
        mode: ResumePermissionMode
    ) -> (String, PermissionSource) {
        switch mode {
        case .standard:
            return ("", .none)
        case .fullAccess:
            switch origin {
            case .codex: return ("--dangerously-bypass-approvals-and-sandbox", .forcedFullAccess)
            case .antigravityCLI, .antigravityDesktop, .claudeCode:
                return ("--dangerously-skip-permissions", .forcedFullAccess)
            }
        case .inherit:
            guard let permission else { return ("", .none) }
            let source: PermissionSource = permission.isInferred ? .inferred : .inherited
            switch origin {
            case .codex:
                if permission.isCodexFullAccess {
                    return ("--dangerously-bypass-approvals-and-sandbox", source)
                }
                var parts: [String] = []
                if let sandbox = permission.codexSandbox,
                   SessionLaunchPermission.codexSandboxValues.contains(sandbox) {
                    parts.append("-s \(sandbox)")
                }
                if let approval = permission.codexApproval,
                   SessionLaunchPermission.codexApprovalValues.contains(approval) {
                    parts.append("-a \(approval)")
                }
                return (parts.joined(separator: " "), source)
            case .antigravityCLI, .antigravityDesktop:
                return permission.skipsPermissions == true
                    ? ("--dangerously-skip-permissions", source)
                    : ("", .none)
            case .claudeCode:
                if permission.skipsPermissions == true || permission.claudePermissionMode == "bypassPermissions" {
                    return ("--dangerously-skip-permissions", source)
                }
                if let mode = permission.claudePermissionMode, ["acceptEdits", "plan"].contains(mode) {
                    return ("--permission-mode \(mode)", source)
                }
                return ("", .none)
            }
        }
    }

    private static func normalizedCwd(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    @MainActor
    var permissionNote: String? {
        switch permissionSource {
        case .none:
            return nil
        case .inherited:
            return tr("Permissions inherited from the original session", "权限继承自原会话")
        case .inferred:
            return tr(
                "No launch record for this session; permissions follow your latest agy launch",
                "原会话无启动记录，权限按你最近一次 agy 启动方式推断"
            )
        case .forcedFullAccess:
            return tr("Always resume with full access (Settings)", "已设置为始终以完全放行恢复")
        }
    }

    @MainActor
    var helpText: String {
        var lines: [String] = []
        switch origin {
        case .antigravityDesktop:
            lines.append(tr(
                "Enter /resume in terminal to restore this desktop session",
                "进终端后输入 /resume 恢复桌面端会话"
            ))
            if !PrivacyDisplay.isEnabled {
                lines.append(command)
            }
        case .codex, .antigravityCLI, .claudeCode:
            if PrivacyDisplay.isEnabled {
                lines.append(tr("Copy terminal resume command", "复制终端恢复命令"))
            } else {
                lines.append(tr("Copy resume command: \(command)", "复制恢复命令：\(command)"))
            }
        }
        if let permissionNote {
            lines.append(permissionNote)
        }
        return lines.joined(separator: "\n")
    }

    var requiresDesktopResumeHint: Bool {
        origin == .antigravityDesktop
    }
}

// MARK: - Session History Record

nonisolated struct SessionHistoryRecord: Sendable, Codable, Equatable, Identifiable {
    /// 与 `ConversationInfo.key` 对齐（`codex:<id>`、`antigravity:<id>` 或 `claude:<id>`）。
    var key: String
    var sessionID: String
    var origin: SessionOrigin
    /// 还原出的工作目录路径（用于拼接 `cd '<escaped_cwd>'`）。
    var cwd: String?
    /// 项目目录名（有明确项目时为目录末级名称）。
    var projectName: String
    var lastActiveAt: Date
    var createdAt: Date?
    var title: String?
    var summary: String?
    var firstPrompt: String?
    var latestPrompt: String?
    var isSubagent: Bool
    /// 原会话启动权限（只读还原，可能为 nil）。
    var permission: SessionLaunchPermission?
    /// 会话所在 git 分支（若可读）。
    var gitBranch: String?

    var id: String { key }

    func resumeCommand(mode: ResumePermissionMode) -> SessionResumeCommand {
        SessionResumeCommand.build(
            origin: origin,
            sessionID: sessionID,
            cwd: cwdExists ? cwd : nil,
            permission: permission,
            mode: mode
        )
    }

    /// 按用户当前设置生成的恢复命令。
    @MainActor
    var resumeCommand: SessionResumeCommand {
        resumeCommand(mode: SettingsStore.shared.resumePermissionMode)
    }

    /// cwd 是否仍存在于磁盘（目录被删除或移动时恢复命令自动去掉 `cd`）。
    var cwdExists: Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
    }

    /// cwd 有记录但已不存在。
    var cwdIsMissing: Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        return !cwdExists
    }

    /// 主展示标题：优先会话标题，其次首条提问摘要、最近提问摘要、内容摘要。
    var primaryTitle: String? {
        for candidate in [title, firstPrompt, latestPrompt, summary] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// 次级提问预览：若最近提问与主标题不同，供检索或详情辅助展示。
    var secondaryPromptPreview: String? {
        let primary = primaryTitle ?? ""
        for candidate in [latestPrompt, firstPrompt, summary] {
            guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text != primary
            else { continue }
            return text
        }
        return nil
    }

    private var searchableFields: [String?] {
        [projectName, cwd, title, summary, firstPrompt, latestPrompt, sessionID, gitBranch]
    }

    /// 忽略大小写匹配项目目录名、工作目录路径、对话标题/摘要、首条/最近提问关键词与分支；
    /// 同时支持中文标题的拼音全拼与首字母（如 “hgcz” 命中 “回归测试”）。
    func matches(lowercasedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        for field in searchableFields {
            if let value = field, !value.isEmpty, value.lowercased().contains(query) {
                return true
            }
        }
        guard PinyinSearch.isPinyinCandidate(query) else { return false }
        for field in [title, firstPrompt, latestPrompt, projectName] {
            if let value = field, PinyinSearch.matches(value, query: query) {
                return true
            }
        }
        return false
    }

    /// 当搜索词命中在提问内容而非标题时，返回命中的提问摘要以便在列表中直观呈现。
    func matchingSnippet(lowercasedQuery query: String) -> String? {
        guard !query.isEmpty else { return nil }
        if let primary = primaryTitle, primary.lowercased().contains(query) {
            return nil
        }
        for candidate in [latestPrompt, firstPrompt, summary] {
            if let value = candidate, value.lowercased().contains(query) {
                return value
            }
        }
        return nil
    }
}

// MARK: - Pinyin Search

/// 中文拼音检索：用系统 `CFStringTransform` 转拉丁字母，支持全拼与首字母匹配，结果按字符串缓存。
nonisolated enum PinyinSearch {
    private static let cache = PinyinCache()

    /// 只有纯 ASCII 字母的查询才尝试拼音匹配。
    static func isPinyinCandidate(_ query: String) -> Bool {
        !query.isEmpty && query.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.lowercaseLetters.contains($0) }
    }

    static func matches(_ text: String, query: String) -> Bool {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) else { return false }
        let forms = cache.forms(for: text)
        return forms.full.contains(query) || forms.initials.contains(query)
    }

    static func latinForms(of text: String) -> (full: String, initials: String) {
        let mutable = NSMutableString(string: String(text.prefix(160))) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutable as String).lowercased()
        let words = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let full = words.joined()
        let initials = String(words.compactMap(\.first))
        return (full, initials)
    }
}

private nonisolated final class PinyinCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: (full: String, initials: String)] = [:]

    func forms(for text: String) -> (full: String, initials: String) {
        lock.lock()
        if let hit = storage[text] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let computed = PinyinSearch.latinForms(of: text)
        lock.lock()
        if storage.count > 4000 { storage.removeAll(keepingCapacity: true) }
        storage[text] = computed
        lock.unlock()
        return computed
    }
}
