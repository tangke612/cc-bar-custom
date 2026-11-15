import Foundation

// 拆分自 SessionHistoryService.swift：路径归一化 / 项目 cwd 还原、文本与 URI 提取、时间戳与文件戳辅助。

extension SessionHistoryScanner {
    // MARK: - Path Normalization & Real Project CWD Recovery (TCC-Safe)

    nonisolated static func isSpecificWorkspacePath(_ raw: String, homePath: String) -> Bool {
        let cleaned = standardizePathString(raw)
        guard !cleaned.isEmpty, cleaned != "/", cleaned != homePath else { return false }
        return !isIgnoredSystemOrConfigPath(cleaned, homePath: homePath)
    }

    nonisolated static func preferredCwd(_ primary: String?, fallback: String?, homePath: String) -> String? {
        if let primary, isSpecificWorkspacePath(primary, homePath: homePath) { return primary }
        if let fallback, isSpecificWorkspacePath(fallback, homePath: homePath) { return fallback }
        return primary ?? fallback
    }

    /// 结合显式 workspace 与工具调用/URI 候选路径还原真实项目目录（严格遵循 TCC 保护目录不触盘原则）。
    nonisolated static func normalizeProjectAndCwd(
        explicitCwd: String?,
        inferredPaths: [String],
        homePath: String
    ) -> (cwd: String?, projectName: String) {
        let cleanExplicit = explicitCwd.map(standardizePathString).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }

        // 1) 若显式路径已经是具体的项目目录（非 `/` 且非泛指 `$HOME`），优先使用它并按允许范围归一到 git 根目录
        if let cleanExplicit, cleanExplicit != homePath, !isIgnoredSystemOrConfigPath(cleanExplicit, homePath: homePath) {
            let resolvedDir = resolveProjectDirectory(fromCandidatePath: cleanExplicit, isKnownDirectory: true, homePath: homePath)
            let name = URL(fileURLWithPath: resolvedDir).lastPathComponent
            return (resolvedDir, name)
        }

        // 2) 显式路径缺失或是泛指 `$HOME` 时，从工具调用路径 / file:/// URI 投票还原真实项目根目录
        var counts: [String: Int] = [:]
        var firstSeenOrder: [String: Int] = [:]
        for (idx, candidate) in inferredPaths.enumerated() {
            let std = standardizePathString(candidate)
            guard !std.isEmpty, std != "/", std != homePath,
                  !isIgnoredSystemOrConfigPath(std, homePath: homePath)
            else { continue }
            let projectDir = resolveProjectDirectory(fromCandidatePath: std, isKnownDirectory: false, homePath: homePath)
            guard !projectDir.isEmpty, projectDir != "/", projectDir != homePath,
                  !isIgnoredSystemOrConfigPath(projectDir, homePath: homePath)
            else { continue }
            counts[projectDir, default: 0] += 1
            if firstSeenOrder[projectDir] == nil { firstSeenOrder[projectDir] = idx }
        }

        if let bestInferred = counts.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return (firstSeenOrder[lhs.key] ?? .max) > (firstSeenOrder[rhs.key] ?? .max)
            }
            return lhs.value < rhs.value
        })?.key {
            let name = URL(fileURLWithPath: bestInferred).lastPathComponent
            return (bestInferred, name)
        }

        // 3) 兜底保留 `$HOME` 供终端 `cd` 使用，项目名记为 `~`
        if let cleanExplicit {
            let name = cleanExplicit == homePath ? "~" : URL(fileURLWithPath: cleanExplicit).lastPathComponent
            return (cleanExplicit, name)
        }
        return (nil, "")
    }

    nonisolated static func resolveProjectDirectory(
        fromCandidatePath standardizedPath: String,
        isKnownDirectory: Bool,
        homePath: String
    ) -> String {
        let url = URL(fileURLWithPath: standardizedPath)

        // 允许做文件系统探测的家目录非 TCC 路径：检查目录与最近 .git 根
        if ConversationProjectResolver.allowsFileSystemCheck(standardizedPath: standardizedPath, home: homePath) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: standardizedPath, isDirectory: &isDir) {
                let startDir = isDir.boolValue ? url : url.deletingLastPathComponent()
                if let gitRoot = nearestGitRoot(from: startDir, homePath: homePath) {
                    return gitRoot.path
                }
                if isKnownDirectory && isDir.boolValue {
                    return startDir.path
                }
            }
        }

        // 不触碰文件系统（TCC 目录如 ~/Documents、~/Desktop，或已删除路径）：纯字符串启发式还原项目根
        var dirURL = url
        if !isKnownDirectory && !url.pathExtension.isEmpty {
            dirURL = url.deletingLastPathComponent()
        }

        let homePrefix = homePath + "/"
        if dirURL.path.hasPrefix(homePrefix) {
            let relComponents = dirURL.path.dropFirst(homePrefix.count).split(separator: "/").map(String.init)
            if let first = relComponents.first {
                let lowerFirst = first.lowercased()
                let containerFolders: Set<String> = [
                    "documents", "desktop", "downloads", "projects", "work", "code", "repos", "src", "dev", "developer"
                ]
                if containerFolders.contains(lowerFirst) {
                    if relComponents.count >= 2 {
                        return "\(homePath)/\(relComponents[0])/\(relComponents[1])"
                    }
                } else if !isKnownDirectory {
                    return "\(homePath)/\(relComponents[0])"
                }
            }
        }
        return dirURL.path
    }

    nonisolated static func nearestGitRoot(from directoryURL: URL, homePath: String) -> URL? {
        let fm = FileManager.default
        var current = directoryURL.standardizedFileURL
        while current.path != "/", current.path.hasPrefix(homePath + "/") {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated static func isIgnoredSystemOrConfigPath(_ path: String, homePath: String) -> Bool {
        let lower = path.lowercased()
        let lowerHome = homePath.lowercased()
        if lower == lowerHome { return false }
        if lower.hasPrefix(lowerHome + "/") {
            let homeIgnoredDirs = [
                "\(lowerHome)/.gemini",
                "\(lowerHome)/.codex",
                "\(lowerHome)/.claude",
                "\(lowerHome)/.agents",
                "\(lowerHome)/.config",
                "\(lowerHome)/.local",
                "\(lowerHome)/.cache",
                "\(lowerHome)/library",
            ]
            return homeIgnoredDirs.contains { lower == $0 || lower.hasPrefix($0 + "/") }
        }
        let systemPrefixes = [
            "/tmp/", "/private/tmp/", "/var/", "/private/var/",
            "/system/", "/library/", "/usr/", "/bin/", "/sbin/", "/opt/", "/dev/", "/applications/",
        ]
        if lower == "/tmp" || lower == "/private/tmp" || lower == "/applications" { return true }
        return systemPrefixes.contains { lower == $0 || lower.hasPrefix($0) }
    }

    nonisolated static func standardizePathString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let fromURI = fileURIToPath(trimmed) {
            return URL(fileURLWithPath: fromURI).standardizedFileURL.path
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    nonisolated static func fileURIToPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("file://") else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        let stripped = String(trimmed.dropFirst("file://".count))
        return stripped.removingPercentEncoding ?? stripped
    }

    // MARK: - Text & URI Extraction Helpers

    nonisolated static let fileURIRegex = try? NSRegularExpression(
        pattern: #"file:///[^\s\"'<>`)\]}]+"#
    )

    nonisolated static func extractFileURIPaths(fromUTF8Bytes bytes: [UInt8]) -> [String] {
        let text = String(decoding: bytes, as: UTF8.self)
        return extractFileURIPaths(fromString: text)
    }

    nonisolated static func extractFileURIPaths(fromString text: String) -> [String] {
        guard let regex = fileURIRegex else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var paths: [String] = []
        for match in matches.prefix(25) {
            guard let range = Range(match.range, in: text) else { continue }
            var uri = String(text[range])
            if let hashIdx = uri.firstIndex(of: "#") {
                uri = String(uri[..<hashIdx])
            }
            if let path = fileURIToPath(uri) {
                paths.append(path)
            }
        }
        return paths
    }

    nonisolated static func extractPathsFromShellCommand(_ cmd: String) -> [String] {
        var results: [String] = []
        let pattern = #"(?:^|&&|\|\||;)\s*cd\s+(?:'([^']+)'|\"([^\"]+)\"|([^\s;&|]+))"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd))
            for m in matches {
                for group in 1...3 {
                    if let r = Range(m.range(at: group), in: cmd) {
                        let candidate = String(cmd[r])
                        if candidate.hasPrefix("/") || candidate.hasPrefix("~/") {
                            results.append(candidate)
                        }
                    }
                }
            }
        }
        return results
    }

    nonisolated static func extractActiveWorkspaceFromPrompt(_ content: String) -> String? {
        guard let marker = content.range(of: "Command Working Directory:") else { return nil }
        let rest = content[marker.upperBound...]
        guard let lineEnd = rest.firstIndex(where: \.isNewline) else {
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest[..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func extractAntigravityUserPrompt(_ content: String) -> String? {
        if let open = content.range(of: "<USER_REQUEST>"),
           let close = content.range(of: "</USER_REQUEST>", range: open.upperBound..<content.endIndex) {
            let inner = String(content[open.upperBound..<close.lowerBound])
            return cleanUserPromptText(inner)
        }
        if content.contains("<CONTEXT_SUMMARY>") {
            return nil
        }
        return cleanUserPromptText(content)
    }

    /// 过滤 Codex / Antigravity 系统注入的 XML 块，提取真实用户提问摘要。
    nonisolated static func cleanUserPromptText(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }

        if let open = text.range(of: "<USER_REQUEST>"),
           let close = text.range(of: "</USER_REQUEST>", range: open.upperBound..<text.endIndex) {
            text = String(text[open.upperBound..<close.lowerBound])
        }

        let xmlBlockPatterns = [
            #"<environment_context>[\s\S]*?</environment_context>"#,
            #"<permissions[\s\S]*?</permissions[^>]*>"#,
            #"<collaboration_mode>[\s\S]*?</collaboration_mode>"#,
            #"<system-reminder>[\s\S]*?</system-reminder>"#,
            #"<ADDITIONAL_METADATA>[\s\S]*?</ADDITIONAL_METADATA>"#,
            #"<INSTRUCTIONS>[\s\S]*?</INSTRUCTIONS>"#,
            #"<subagent_notification>[\s\S]*?</subagent_notification>"#,
            #"<CONTEXT_SUMMARY>[\s\S]*?</CONTEXT_SUMMARY>"#,
        ]
        for pattern in xmlBlockPatterns {
            if text.contains("<"), let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: " "
                )
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("# AGENTS.md instructions for ")
            || trimmed.hasPrefix("<environment_context>")
            || trimmed.hasPrefix("<permissions")
            || trimmed.hasPrefix("<turn_aborted>") {
            return nil
        }
        return cleanSummaryText(trimmed, maxLength: 260)
    }

    nonisolated static func cleanSummaryText(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }

    // MARK: - Timestamp & File Stamp Helpers

    nonisolated static func fileStamp(of url: URL) -> SessionHistoryCacheState.FileStamp? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let walAttrs = try? fm.attributesOfItem(atPath: url.path + "-wal")
        return SessionHistoryCacheState.FileStamp(
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            walSize: (walAttrs?[.size] as? NSNumber)?.int64Value ?? 0,
            walMtime: (walAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }

    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        if let parsed = JSONLTimestamp.parse(raw) { return parsed }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    nonisolated static func extractFastISO8601Timestamp(from line: String) -> Date? {
        guard let keyRange = line.range(of: "\"timestamp\":\"") ?? line.range(of: "\"timestamp\": \"") else {
            return nil
        }
        let start = keyRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        return JSONLTimestamp.parse(String(line[start..<end]))
    }

    nonisolated static func extractFastCreatedAtTimestamp(from line: String) -> Date? {
        guard let keyRange = line.range(of: "\"created_at\":\"") ?? line.range(of: "\"created_at\": \"") else {
            return nil
        }
        let start = keyRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        return JSONLTimestamp.parse(String(line[start..<end]))
    }
}
