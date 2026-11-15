import Foundation

// MARK: - Shell Path Escaping

nonisolated enum ShellPathEscaper {
    /// 统一单引号转义：将路径中的 `'` 替换为 `'\''` 并整体使用单引号包裹，兼容空格与特殊字符。
    static func singleQuoted(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Session Origin & Resume Command

nonisolated enum SessionOrigin: String, Sendable, Codable, Equatable, Hashable {
    case codex
    case antigravityCLI
    case antigravityDesktop

    var usageApp: UsageApp {
        switch self {
        case .codex: return .codex
        case .antigravityCLI, .antigravityDesktop: return .antigravity
        }
    }

    var quotaApp: QuotaApp {
        switch self {
        case .codex: return .codex
        case .antigravityCLI, .antigravityDesktop: return .antigravity
        }
    }

    @MainActor
    var sourceBadge: String? {
        switch self {
        case .codex:
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

    /// 按会话来源与工作目录拼接终端恢复命令。
    static func build(origin: SessionOrigin, sessionID: String, cwd: String?) -> SessionResumeCommand {
        let cleanID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCwd = Self.normalizedCwd(cwd)
        let cdPrefix = cleanCwd.map { "cd \(ShellPathEscaper.singleQuoted($0)) && " } ?? ""

        let tail: String
        switch origin {
        case .codex:
            tail = "codex resume \(cleanID)"
        case .antigravityCLI:
            tail = "agy --conversation \(cleanID)"
        case .antigravityDesktop:
            tail = "agy"
        }

        return SessionResumeCommand(
            origin: origin,
            sessionID: cleanID,
            cwd: cleanCwd,
            command: cdPrefix + tail
        )
    }

    private static func normalizedCwd(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    @MainActor
    var helpText: String {
        switch origin {
        case .antigravityDesktop:
            return tr(
                "Enter /resume in terminal to restore this desktop session",
                "进终端后输入 /resume 恢复桌面端会话"
            )
        case .codex, .antigravityCLI:
            if PrivacyDisplay.isEnabled {
                return tr("Copy terminal resume command", "复制终端恢复命令")
            }
            return tr("Copy resume command: \(command)", "复制恢复命令：\(command)")
        }
    }

    var requiresDesktopResumeHint: Bool {
        origin == .antigravityDesktop
    }
}

// MARK: - Session History Record

nonisolated struct SessionHistoryRecord: Sendable, Codable, Equatable, Identifiable {
    /// 与 `ConversationInfo.key` 对齐（`codex:<id>` 或 `antigravity:<id>`）。
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

    var id: String { key }

    var resumeCommand: SessionResumeCommand {
        SessionResumeCommand.build(origin: origin, sessionID: sessionID, cwd: cwd)
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

    /// 忽略大小写匹配项目目录名、工作目录路径、对话标题/摘要与首条/最近提问关键词。
    func matches(lowercasedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields: [String?] = [
            projectName,
            cwd,
            title,
            summary,
            firstPrompt,
            latestPrompt,
            sessionID,
        ]
        for field in fields {
            if let value = field, !value.isEmpty, value.lowercased().contains(query) {
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
