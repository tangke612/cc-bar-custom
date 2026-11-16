import Foundation

// MARK: - Filter & Sort

nonisolated enum LocalSkillScopeFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case user
    case builtin

    @MainActor
    var label: String {
        switch self {
        case .all: return tr("All types", "全部类型")
        case .user: return tr("User", "用户安装")
        case .builtin: return tr("Built-in", "内置技能")
        }
    }
}

nonisolated enum LocalSkillSort: String, CaseIterable, Hashable, Sendable {
    case name
    case recent
    case source

    @MainActor
    var label: String {
        switch self {
        case .name: return tr("Name", "按名称")
        case .recent: return tr("Updated", "最近修改")
        case .source: return tr("Source", "按来源")
        }
    }
}

// MARK: - Source Kind

nonisolated enum LocalSkillSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case agentsShared
    case codexUser
    case codexSystem
    case codexVendor
    case claudeUser
    case claudePlugins
    case antigravityUser
    case geminiUser
    case antigravityBuiltin
    case antigravityCLIBuiltin
    case cursorUser
    case cursorBuiltin
    case opencodeUser
    case piUser
    case qwenWork
    case minimaxUser
    case minimaxBuiltin
    case aionUi

    var isBuiltin: Bool {
        switch self {
        case .codexSystem, .antigravityBuiltin, .antigravityCLIBuiltin, .cursorBuiltin, .minimaxBuiltin:
            return true
        case .agentsShared, .codexUser, .codexVendor, .claudeUser, .claudePlugins,
             .antigravityUser, .geminiUser, .cursorUser, .opencodeUser, .piUser,
             .qwenWork, .minimaxUser, .aionUi:
            return false
        }
    }

    var primaryApp: UsageApp? {
        switch self {
        case .codexUser, .codexSystem, .codexVendor:
            return .codex
        case .claudeUser, .claudePlugins:
            return .claude
        case .antigravityUser, .geminiUser, .antigravityBuiltin, .antigravityCLIBuiltin:
            return .antigravity
        case .cursorUser, .cursorBuiltin:
            return .cursor
        case .opencodeUser:
            return .opencode
        case .piUser:
            return .pi
        case .agentsShared, .qwenWork, .minimaxUser, .minimaxBuiltin, .aionUi:
            return nil
        }
    }

    var supportedApps: Set<UsageApp> {
        switch self {
        case .agentsShared:
            return [.codex, .antigravity, .cursor, .opencode, .pi]
        case .codexUser, .codexSystem, .codexVendor:
            return [.codex]
        case .claudeUser, .claudePlugins:
            return [.claude]
        case .antigravityUser, .geminiUser, .antigravityBuiltin, .antigravityCLIBuiltin:
            return [.antigravity]
        case .cursorUser, .cursorBuiltin:
            return [.cursor]
        case .opencodeUser:
            return [.opencode]
        case .piUser:
            return [.pi]
        case .qwenWork, .minimaxUser, .minimaxBuiltin, .aionUi:
            return []
        }
    }

    var sourceGroupID: String {
        switch self {
        case .agentsShared: return "agents"
        case .codexUser, .codexSystem, .codexVendor: return "codex"
        case .claudeUser, .claudePlugins: return "claude"
        case .antigravityUser, .geminiUser, .antigravityBuiltin, .antigravityCLIBuiltin: return "antigravity"
        case .cursorUser, .cursorBuiltin: return "cursor"
        case .opencodeUser: return "opencode"
        case .piUser: return "pi"
        case .qwenWork: return "qwenwork"
        case .minimaxUser, .minimaxBuiltin: return "minimax"
        case .aionUi: return "aionui"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .agentsShared:
            return "square.stack.3d.up"
        default:
            return "sparkles"
        }
    }

    @MainActor
    var sourceBadgeLabel: String {
        switch self {
        case .agentsShared: return tr("Shared (~/.agents)", "共享 (~/.agents)")
        case .codexUser: return "Codex"
        case .codexSystem: return "Codex · System"
        case .codexVendor: return tr("Codex · Vendor", "Codex · 扩展")
        case .claudeUser: return "Claude Code"
        case .claudePlugins: return tr("Claude Plugin", "Claude 插件")
        case .antigravityUser: return "Antigravity"
        case .geminiUser: return "Gemini"
        case .antigravityBuiltin: return "Antigravity · IDE"
        case .antigravityCLIBuiltin: return "Antigravity · CLI"
        case .cursorUser, .cursorBuiltin: return "Cursor"
        case .opencodeUser: return "OpenCode"
        case .piUser: return "Pi"
        case .qwenWork: return "QwenWork"
        case .minimaxUser, .minimaxBuiltin: return "MiniMax"
        case .aionUi: return "AionUi"
        }
    }

    @MainActor
    static func sourceGroupLabel(for groupID: String) -> String {
        switch groupID {
        case "agents": return tr("Shared (.agents)", "共享 (.agents)")
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "antigravity": return "Antigravity / Gemini"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "qwenwork": return "QwenWork"
        case "minimax": return "MiniMax"
        case "aionui": return "AionUi"
        default: return groupID
        }
    }

    static let orderedGroupIDs: [String] = [
        "agents",
        "codex",
        "claude",
        "antigravity",
        "cursor",
        "opencode",
        "pi",
        "qwenwork",
        "minimax",
        "aionui",
    ]
}

// MARK: - Skill Models

nonisolated struct LocalSkillResourceEntry: Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var path: String
    var isDirectory: Bool
    var childCount: Int

    var id: String { path }
}

nonisolated struct LocalSkillRecord: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var folderName: String
    var description: String
    var metadata: [String: String]
    var sourceKind: LocalSkillSourceKind
    var directoryPath: String
    var skillFilePath: String
    var displayPath: String
    var isSymlink: Bool
    var symlinkTarget: String?
    var modifiedAt: Date?
    var fileSizeBytes: Int64
    var lineCount: Int
    var bodyMarkdown: String
    var rawFrontmatter: String?
    var resources: [LocalSkillResourceEntry]

    var isBuiltin: Bool { sourceKind.isBuiltin }

    func matches(usageApp: UsageApp?) -> Bool {
        guard let usageApp else { return true }
        return sourceKind.supportedApps.contains(usageApp)
    }

    func matches(lowercasedQuery query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        var fields: [String] = [
            name,
            folderName,
            description,
            displayPath,
            sourceKind.rawValue,
            sourceKind.sourceGroupID,
        ]
        fields.append(contentsOf: metadata.values)

        for value in fields where !value.isEmpty {
            if value.lowercased().contains(trimmed) {
                return true
            }
        }

        guard PinyinSearch.isPinyinCandidate(trimmed) else { return false }
        for field in [name, folderName, description] where !field.isEmpty {
            if PinyinSearch.matches(field, query: trimmed) {
                return true
            }
        }
        return false
    }
}

// MARK: - SKILL.md Frontmatter Parser

nonisolated enum LocalSkillFrontmatterParser {
    struct ParsedSkillDocument: Sendable, Equatable {
        var name: String
        var description: String
        var metadata: [String: String]
        var rawFrontmatter: String?
        var body: String
        var lineCount: Int
    }

    private enum BlockScalarMode {
        case folded
        case literal
    }

    private enum BlockChomp {
        case clip
        case strip
        case keep
    }

    static func parse(markdown: String, fallbackName: String) -> ParsedSkillDocument {
        var normalized = markdown
        if normalized.hasPrefix("\u{FEFF}") {
            normalized.removeFirst()
        }
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let allLines = normalized.components(separatedBy: "\n")
        let totalLines = normalized.isEmpty ? 0 : allLines.count

        var parsedName = ""
        var parsedDescription = ""
        var metadata: [String: String] = [:]
        var rawFrontmatter: String?
        var bodyLines = allLines

        if let firstLine = allLines.first,
           firstLine.trimmingCharacters(in: .whitespaces) == "---" {
            var closingIndex: Int?
            for idx in 1..<allLines.count {
                let trimmed = allLines[idx].trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "..." {
                    closingIndex = idx
                    break
                }
            }

            if let endIdx = closingIndex {
                let fmLines = Array(allLines[1..<endIdx])
                rawFrontmatter = fmLines.joined(separator: "\n")
                let parsed = parseFrontmatterLines(fmLines)
                parsedName = parsed.name
                parsedDescription = parsed.description
                metadata = parsed.metadata
                bodyLines = (endIdx + 1) < allLines.count ? Array(allLines[(endIdx + 1)...]) : []
            }
        }

        let body = bodyLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName = parsedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackName
            : parsedName.trimmingCharacters(in: .whitespacesAndNewlines)

        var resolvedDescription = parsedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedDescription.isEmpty,
           let shortDesc = metadata["short-description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shortDesc.isEmpty {
            resolvedDescription = shortDesc
        }
        if resolvedDescription.isEmpty {
            resolvedDescription = extractFallbackDescription(from: body)
        }

        return ParsedSkillDocument(
            name: resolvedName,
            description: resolvedDescription,
            metadata: metadata,
            rawFrontmatter: rawFrontmatter,
            body: body,
            lineCount: totalLines
        )
    }

    private struct FrontmatterFields {
        var name = ""
        var description = ""
        var metadata: [String: String] = [:]
    }

    private static func parseFrontmatterLines(_ lines: [String]) -> FrontmatterFields {
        var result = FrontmatterFields()
        var idx = 0

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                idx += 1
                continue
            }

            // Top-level keys must start at column 0.
            if leadingSpaceCount(line) > 0 {
                idx += 1
                continue
            }

            guard let colonIdx = line.firstIndex(of: ":") else {
                idx += 1
                continue
            }

            let rawKey = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let key = unquote(rawKey).lowercased()
            let afterColon = String(line[line.index(after: colonIdx)...])
            let rawValue = afterColon.trimmingCharacters(in: .whitespaces)

            if key == "metadata" && rawValue.isEmpty {
                idx += 1
                while idx < lines.count {
                    let subLine = lines[idx]
                    let subTrimmed = subLine.trimmingCharacters(in: .whitespaces)
                    if subTrimmed.isEmpty || subTrimmed.hasPrefix("#") {
                        idx += 1
                        continue
                    }
                    let indent = leadingSpaceCount(subLine)
                    if indent == 0 {
                        break
                    }
                    if let subColon = subTrimmed.firstIndex(of: ":") {
                        let subKey = unquote(String(subTrimmed[..<subColon]).trimmingCharacters(in: .whitespaces))
                        let subVal = String(subTrimmed[subTrimmed.index(after: subColon)...]).trimmingCharacters(in: .whitespaces)
                        if !subKey.isEmpty, !subVal.isEmpty {
                            result.metadata[subKey] = unquote(subVal)
                        }
                    }
                    idx += 1
                }
                continue
            }

            if let (mode, chomp) = parseBlockScalarHeader(rawValue) {
                idx += 1
                var blockLines: [String] = []
                while idx < lines.count {
                    let blockLine = lines[idx]
                    if blockLine.trimmingCharacters(in: .whitespaces).isEmpty {
                        blockLines.append("")
                        idx += 1
                        continue
                    }
                    if leadingSpaceCount(blockLine) == 0 {
                        break
                    }
                    blockLines.append(blockLine)
                    idx += 1
                }
                let rendered = renderBlockScalar(lines: blockLines, mode: mode, chomp: chomp)
                assignTopLevelField(key: key, value: rendered, into: &result)
                continue
            }

            // Plain scalar (with optional indented multi-line continuation for description).
            if rawValue.isEmpty && key == "description" {
                idx += 1
                var contLines: [String] = []
                while idx < lines.count {
                    let nextLine = lines[idx]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty {
                        if !contLines.isEmpty { contLines.append("") }
                        idx += 1
                        continue
                    }
                    if leadingSpaceCount(nextLine) == 0 {
                        break
                    }
                    contLines.append(nextTrimmed)
                    idx += 1
                }
                let joined = foldParagraphLines(contLines)
                assignTopLevelField(key: key, value: joined, into: &result)
                continue
            }

            var scalarValue = unquote(rawValue)
            idx += 1
            if key == "description", !rawValue.isEmpty, !isQuoted(rawValue) {
                var contLines = [scalarValue]
                while idx < lines.count {
                    let nextLine = lines[idx]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty || leadingSpaceCount(nextLine) == 0 {
                        break
                    }
                    contLines.append(nextTrimmed)
                    idx += 1
                }
                scalarValue = contLines.joined(separator: " ")
            }
            assignTopLevelField(key: key, value: scalarValue, into: &result)
        }

        return result
    }

    private static func assignTopLevelField(key: String, value: String, into fields: inout FrontmatterFields) {
        switch key {
        case "name":
            fields.name = value
        case "description":
            fields.description = value
        default:
            break
        }
    }

    private static func parseBlockScalarHeader(_ rawValue: String) -> (BlockScalarMode, BlockChomp)? {
        guard let first = rawValue.first, first == ">" || first == "|" else { return nil }
        let rest = rawValue.dropFirst()
        // Allow optional chomp/indent indicators (e.g. ">-", "|-", ">2-", "|+")
        for ch in rest {
            if ch != "-" && ch != "+" && !ch.isNumber && ch != " " {
                return nil
            }
        }
        let mode: BlockScalarMode = first == ">" ? .folded : .literal
        let chomp: BlockChomp
        if rest.contains("-") {
            chomp = .strip
        } else if rest.contains("+") {
            chomp = .keep
        } else {
            chomp = .clip
        }
        return (mode, chomp)
    }

    private static func renderBlockScalar(
        lines: [String],
        mode: BlockScalarMode,
        chomp: BlockChomp
    ) -> String {
        var trimmedEnd = lines
        while let last = trimmedEnd.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trimmedEnd.removeLast()
        }
        let nonEmptyIndents = trimmedEnd
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(leadingSpaceCount)
        let minIndent = nonEmptyIndents.min() ?? 0

        let dedented: [String] = trimmedEnd.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            return String(line.dropFirst(min(minIndent, line.count)))
        }

        let content: String
        switch mode {
        case .literal:
            content = dedented.joined(separator: "\n")
        case .folded:
            content = foldParagraphLines(dedented)
        }

        switch chomp {
        case .strip, .clip:
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        case .keep:
            return content
        }
    }

    private static func foldParagraphLines(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current.removeAll()
                }
            } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current.removeAll()
                }
                paragraphs.append(trimmed)
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " {
                count += 1
            } else if ch == "\t" {
                count += 2
            } else {
                break
            }
        }
        return count
    }

    private static func isQuoted(_ text: String) -> Bool {
        (text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2)
            || (text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2)
    }

    private static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }

    private static func extractFallbackDescription(from body: String) -> String {
        guard !body.isEmpty else { return "" }
        let lines = body.components(separatedBy: "\n")
        var paragraph: [String] = []
        var inFence = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("<!--") {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(trimmed)
        }

        let joined = paragraph.joined(separator: " ")
        if joined.count > 240 {
            return String(joined.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return joined
    }
}
