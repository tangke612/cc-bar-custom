import Foundation

// MARK: - Claude Code Sessions & agy Launch Permissions (Strictly Read-Only)
//
// 拆分自 SessionHistoryService.swift：
// - Claude Code：扫描 `~/.claude/projects/**/*.jsonl`，按 mtime/size 增量缓存，提取 sessionId / cwd / gitBranch /
//   首末提问 / permissionMode，恢复命令为 `claude --resume <id>`。
// - agy 启动日志：`~/.gemini/antigravity-cli/log/cli-*.log` 开头会记录
//   `overrides.go] --dangerously-skip-permissions: auto-approving all tool permissions`，
//   同一日志中的 `Created conversation <id>` / `Resuming conversation <id>` 即本次启动打开的会话。
//   以「最近一次打开该会话的启动」为准还原 YOLO 状态；没有日志记录的会话按最近一次启动方式推断。

extension SessionHistoryScanner {
    // MARK: Claude Code

    nonisolated static func scanClaude(
        roots: SessionHistoryRoots,
        state: inout SessionHistoryCacheState
    ) -> [SessionHistoryRecord] {
        guard let projectsRoot = roots.claudeProjects,
              FileManager.default.fileExists(atPath: projectsRoot.path)
        else {
            state.claudeFiles = [:]
            return []
        }

        let files = JSONLDirectoryEnumerator.enumerate(at: projectsRoot, includeZstd: false).files
        var next: [String: SessionHistoryCacheState.CodexEntry] = [:]
        next.reserveCapacity(files.count)
        var bySession: [String: SessionHistoryRecord] = [:]

        for file in files {
            // 子代理日志（`<session>/subagents/*.jsonl`）并入父会话，不单独列出。
            if file.url.pathComponents.contains("subagents") { continue }
            let stamp = SessionHistoryCacheState.FileStamp(
                size: Int64(clamping: file.size),
                mtime: file.modificationTime
            )
            let key = file.url.path
            let record: SessionHistoryRecord?
            if let cached = state.claudeFiles[key], cached.stamp == stamp {
                record = cached.record
            } else {
                record = parseClaudeSession(file: file, homePath: roots.homePath)
            }
            guard let record else { continue }
            next[key] = SessionHistoryCacheState.CodexEntry(stamp: stamp, record: record)
            if let existing = bySession[record.key], existing.lastActiveAt >= record.lastActiveAt {
                continue
            }
            bySession[record.key] = record
        }

        state.claudeFiles = next
        return Array(bySession.values)
    }

    nonisolated private static func parseClaudeSession(
        file: JSONLFileDescriptor,
        homePath: String
    ) -> SessionHistoryRecord? {
        var sessionID: String?
        var rawCwd: String?
        var gitBranch: String?
        var createdAt: Date?
        var lastTimestamp: Date?
        var firstPrompt: String?
        var latestPrompt: String?
        var summary: String?
        var customTitle: String?
        var permissionMode: String?
        var allSidechain = true

        let ok = streamAllJSONLLines(url: file.url) { batch in
            for line in batch {
                if let ts = extractFastISO8601Timestamp(from: line) {
                    if createdAt == nil { createdAt = ts }
                    if lastTimestamp == nil || ts > lastTimestamp! { lastTimestamp = ts }
                }
                let interesting = line.contains("\"type\":\"user\"")
                    || line.contains("\"type\":\"summary\"")
                    || line.contains("\"custom-title\"")
                    || line.contains("\"permissionMode\"")
                    || (sessionID == nil && line.contains("\"sessionId\""))
                guard interesting,
                      line.utf8.count <= 262_144,
                      let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if sessionID == nil, let id = root["sessionId"] as? String, !id.isEmpty {
                    sessionID = id
                }
                if let cwd = root["cwd"] as? String, !cwd.isEmpty {
                    rawCwd = cwd
                }
                if let branch = root["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" {
                    gitBranch = branch
                }
                if let mode = root["permissionMode"] as? String, !mode.isEmpty {
                    permissionMode = mode
                }
                let type = root["type"] as? String
                if type == "summary", let text = root["summary"] as? String {
                    summary = cleanSummaryText(text, maxLength: 140)
                    continue
                }
                if type == "custom-title", let text = root["customTitle"] as? String {
                    customTitle = cleanSummaryText(text, maxLength: 140)
                    continue
                }
                guard type == "user" else { continue }
                if (root["isSidechain"] as? Bool) != true { allSidechain = false }
                if root["isMeta"] as? Bool == true { continue }
                guard let message = root["message"] as? [String: Any],
                      (message["role"] as? String) == "user"
                else { continue }
                // 工具结果也以 user 角色写入：内容数组里只有 tool_result 时跳过。
                if let items = message["content"] as? [[String: Any]],
                   items.allSatisfy({ ($0["type"] as? String) == "tool_result" }) {
                    continue
                }
                guard let rawText = extractTextFromContentArray(message["content"]) else { continue }
                if rawText.hasPrefix("<command-") || rawText.hasPrefix("<local-command-") { continue }
                guard let prompt = cleanUserPromptText(rawText) else { continue }
                if firstPrompt == nil { firstPrompt = prompt }
                latestPrompt = prompt
            }
        }
        guard ok else { return nil }

        let id = (sessionID ?? file.url.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, firstPrompt != nil || summary != nil || customTitle != nil else { return nil }

        let normalized = normalizeProjectAndCwd(explicitCwd: rawCwd, inferredPaths: [], homePath: homePath)
        var permission: SessionLaunchPermission?
        if let permissionMode {
            permission = SessionLaunchPermission(
                skipsPermissions: permissionMode == "bypassPermissions",
                claudePermissionMode: permissionMode
            )
        }

        return SessionHistoryRecord(
            key: "claude:\(id)",
            sessionID: id,
            origin: .claudeCode,
            cwd: normalized.cwd,
            projectName: normalized.projectName,
            lastActiveAt: lastTimestamp ?? Date(timeIntervalSince1970: file.modificationTime),
            createdAt: createdAt,
            title: customTitle,
            summary: summary,
            firstPrompt: firstPrompt,
            latestPrompt: latestPrompt,
            isSubagent: allSidechain && firstPrompt != nil,
            permission: permission,
            gitBranch: gitBranch
        )
    }

    // MARK: agy Launch Logs → --dangerously-skip-permissions

    nonisolated struct AgyPermissionIndex: Sendable {
        /// 会话 ID → 最近一次打开它的启动是否带 `--dangerously-skip-permissions`。
        var byConversation: [String: Bool] = [:]
        /// 最近一次 agy 启动是否带该参数（无记录会话的推断依据）；nil 表示没有任何日志。
        var latestLaunchSkips: Bool?
    }

    nonisolated static let agySkipPermissionMarker = "--dangerously-skip-permissions: auto-approving"

    nonisolated static func scanAgyLaunchLogs(
        roots: SessionHistoryRoots,
        state: inout SessionHistoryCacheState
    ) -> AgyPermissionIndex {
        guard let dir = roots.agyLogDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else {
            state.agyLogs = [:]
            return AgyPermissionIndex()
        }

        // 文件名 `cli-YYYYMMDD_HHMMSS.log` 按字典序即启动时间顺序。
        let logNames = names.filter { $0.hasPrefix("cli-") && $0.hasSuffix(".log") }.sorted()
        var next: [String: SessionHistoryCacheState.AgyLogEntry] = [:]
        var index = AgyPermissionIndex()

        for name in logNames {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            guard let stamp = fileStamp(of: url) else { continue }
            let entry: SessionHistoryCacheState.AgyLogEntry
            if let cached = state.agyLogs[name], cached.stamp == stamp {
                entry = cached
            } else {
                entry = parseAgyLaunchLog(url: url, stamp: stamp)
            }
            next[name] = entry
            index.latestLaunchSkips = entry.skipsPermissions
            for id in entry.conversationIDs {
                index.byConversation[id] = entry.skipsPermissions
            }
        }

        state.agyLogs = next
        return index
    }

    nonisolated static func parseAgyLaunchLog(
        url: URL,
        stamp: SessionHistoryCacheState.FileStamp
    ) -> SessionHistoryCacheState.AgyLogEntry {
        var skips = false
        var ids: [String] = []
        var seen = Set<String>()
        let markers = ["Created conversation ", "Resuming conversation "]

        _ = streamAllJSONLLines(url: url) { batch in
            for line in batch {
                if !skips, line.contains("overrides.go"), line.contains(agySkipPermissionMarker) {
                    skips = true
                    continue
                }
                for marker in markers {
                    guard let range = line.range(of: marker) else { continue }
                    let idPart = line[range.upperBound...].prefix(36)
                    let id = String(idPart)
                    if id.count == 36, UUID(uuidString: id) != nil, seen.insert(id).inserted {
                        ids.append(id)
                    }
                }
            }
        }
        return SessionHistoryCacheState.AgyLogEntry(stamp: stamp, skipsPermissions: skips, conversationIDs: ids)
    }

    nonisolated static func applyAgyPermissions(
        _ index: AgyPermissionIndex,
        to records: inout [SessionHistoryRecord]
    ) {
        for i in records.indices {
            guard records[i].origin == .antigravityCLI || records[i].origin == .antigravityDesktop else { continue }
            if records[i].origin == .antigravityCLI, let skips = index.byConversation[records[i].sessionID] {
                records[i].permission = SessionLaunchPermission(skipsPermissions: skips)
            } else if let latest = index.latestLaunchSkips {
                // 桌面端会话的权限由桌面 App 管理，CLI 恢复时不会继承；按最近一次 agy 启动方式推断。
                records[i].permission = SessionLaunchPermission(skipsPermissions: latest, isInferred: true)
            }
        }
    }
}
