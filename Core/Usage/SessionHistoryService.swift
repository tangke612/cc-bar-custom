import Foundation
import Observation
import SQLite3

// MARK: - Scan Roots & Incremental Cache State

nonisolated struct SessionHistoryRoots: Sendable {
    var codexHome: URL
    var antigravityRoots: [URL]
    var homePath: String
    /// `~/.claude/projects`（Claude Code 会话 JSONL）。
    var claudeProjects: URL?
    /// `~/.gemini/antigravity-cli/log`（agy 启动日志，用于还原 `--dangerously-skip-permissions`）。
    var agyLogDirectory: URL?

    init(
        codexHome: URL,
        antigravityRoots: [URL],
        homePath: String,
        claudeProjects: URL? = nil,
        agyLogDirectory: URL? = nil
    ) {
        self.codexHome = codexHome
        self.antigravityRoots = antigravityRoots
        self.homePath = homePath
        self.claudeProjects = claudeProjects
        self.agyLogDirectory = agyLogDirectory
    }

    static var production: SessionHistoryRoots {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return SessionHistoryRoots(
            codexHome: homeURL.appendingPathComponent(".codex", isDirectory: true),
            antigravityRoots: AntigravityScanner.defaultRoots(),
            homePath: homeURL.standardizedFileURL.path,
            claudeProjects: ClaudeJSONLScanner.defaultRoot(),
            agyLogDirectory: homeURL.appendingPathComponent(".gemini/antigravity-cli/log", isDirectory: true)
        )
    }
}

nonisolated struct SessionHistoryCacheState: Sendable, Codable, Equatable {
    static let currentVersion = 2

    nonisolated struct FileStamp: Sendable, Codable, Equatable {
        var size: Int64
        var mtime: Double
        var walSize: Int64 = 0
        var walMtime: Double = 0
    }

    nonisolated struct CodexEntry: Sendable, Codable, Equatable {
        var stamp: FileStamp
        var record: SessionHistoryRecord
    }

    nonisolated struct CodexIndexItem: Sendable, Codable, Equatable {
        var title: String?
        var updatedAt: Date?
    }

    nonisolated struct AntigravityEntry: Sendable, Codable, Equatable {
        var compositeSignature: String
        var record: SessionHistoryRecord
    }

    nonisolated struct AgyLogEntry: Sendable, Codable, Equatable {
        var stamp: FileStamp
        var skipsPermissions: Bool
        var conversationIDs: [String]
    }

    var version: Int = Self.currentVersion
    var codexIndexStamp: FileStamp?
    var codexIndex: [String: CodexIndexItem] = [:]
    var codexFiles: [String: CodexEntry] = [:]
    var antigravitySessions: [String: AntigravityEntry] = [:]
    var claudeFiles: [String: CodexEntry] = [:]
    var agyLogs: [String: AgyLogEntry] = [:]
}

// MARK: - SessionHistoryScanner (Strictly Read-Only, Background Nonisolated)

nonisolated enum SessionHistoryScanner {
    nonisolated struct ScanOutput: Sendable {
        var records: [SessionHistoryRecord]
        var state: SessionHistoryCacheState
    }

    static func scan(
        previous: SessionHistoryCacheState?,
        roots: SessionHistoryRoots
    ) -> ScanOutput {
        let baseline = previous?.version == SessionHistoryCacheState.currentVersion
            ? previous
            : nil
        var nextState = baseline ?? SessionHistoryCacheState()

        let codexRecords = scanCodex(roots: roots, state: &nextState)
        var antigravityRecords = scanAntigravity(roots: roots, state: &nextState)
        let claudeRecords = scanClaude(roots: roots, state: &nextState)
        let agyPermissions = scanAgyLaunchLogs(roots: roots, state: &nextState)
        applyAgyPermissions(agyPermissions, to: &antigravityRecords)

        var mergedByKey: [String: SessionHistoryRecord] = [:]
        mergedByKey.reserveCapacity(codexRecords.count + antigravityRecords.count + claudeRecords.count)
        for record in claudeRecords {
            mergedByKey[record.key] = record
        }

        for record in codexRecords {
            if let existing = mergedByKey[record.key] {
                mergedByKey[record.key] = mergeRecords(existing, record)
            } else {
                mergedByKey[record.key] = record
            }
        }
        for record in antigravityRecords {
            if let existing = mergedByKey[record.key] {
                mergedByKey[record.key] = mergeRecords(existing, record)
            } else {
                mergedByKey[record.key] = record
            }
        }

        let sorted = mergedByKey.values.sorted { lhs, rhs in
            if lhs.lastActiveAt == rhs.lastActiveAt {
                return lhs.key < rhs.key
            }
            return lhs.lastActiveAt > rhs.lastActiveAt
        }

        return ScanOutput(records: sorted, state: nextState)
    }

    static func mergeRecords(
        _ lhs: SessionHistoryRecord,
        _ rhs: SessionHistoryRecord
    ) -> SessionHistoryRecord {
        let newer = lhs.lastActiveAt >= rhs.lastActiveAt ? lhs : rhs
        let older = lhs.lastActiveAt >= rhs.lastActiveAt ? rhs : lhs
        let resolvedOrigin: SessionOrigin
        if lhs.origin == .antigravityCLI || rhs.origin == .antigravityCLI {
            resolvedOrigin = .antigravityCLI
        } else {
            resolvedOrigin = newer.origin
        }
        let chosenCwd = preferredCwd(newer.cwd, fallback: older.cwd, homePath: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        let chosenProjectName = !newer.projectName.isEmpty ? newer.projectName : older.projectName
        return SessionHistoryRecord(
            key: newer.key,
            sessionID: newer.sessionID,
            origin: resolvedOrigin,
            cwd: chosenCwd,
            projectName: chosenProjectName,
            lastActiveAt: max(lhs.lastActiveAt, rhs.lastActiveAt),
            createdAt: [lhs.createdAt, rhs.createdAt].compactMap { $0 }.min(),
            title: newer.title ?? older.title,
            summary: newer.summary ?? older.summary,
            firstPrompt: older.firstPrompt ?? newer.firstPrompt,
            latestPrompt: newer.latestPrompt ?? older.latestPrompt,
            isSubagent: lhs.isSubagent && rhs.isSubagent,
            permission: newer.permission ?? older.permission,
            gitBranch: newer.gitBranch ?? older.gitBranch
        )
    }

    // MARK: - 1. Codex CLI Session Parsing (Read-Only)

    static func scanCodex(
        roots: SessionHistoryRoots,
        state: inout SessionHistoryCacheState
    ) -> [SessionHistoryRecord] {
        let indexURL = roots.codexHome.appendingPathComponent("session_index.jsonl", isDirectory: false)
        if let stamp = fileStamp(of: indexURL) {
            if state.codexIndexStamp != stamp {
                state.codexIndex = readCodexSessionIndex(url: indexURL)
                state.codexIndexStamp = stamp
            }
        } else {
            state.codexIndexStamp = nil
            state.codexIndex = [:]
        }

        let sessionDirs = [
            roots.codexHome.appendingPathComponent("sessions", isDirectory: true),
            roots.codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        var descriptors: [JSONLFileDescriptor] = []
        for dir in sessionDirs {
            descriptors.append(contentsOf: JSONLDirectoryEnumerator.enumerate(at: dir, includeZstd: true).files)
        }

        var nextCodexFiles: [String: SessionHistoryCacheState.CodexEntry] = [:]
        nextCodexFiles.reserveCapacity(descriptors.count)
        var results: [SessionHistoryRecord] = []
        results.reserveCapacity(descriptors.count)

        for file in descriptors {
            let stamp = SessionHistoryCacheState.FileStamp(
                size: Int64(clamping: file.size),
                mtime: file.modificationTime
            )
            let stateKey = codexSessionUUID(from: file.url) ?? file.url.path

            var record: SessionHistoryRecord?
            if let cached = state.codexFiles[stateKey], cached.stamp == stamp {
                record = cached.record
            } else {
                record = parseCodexRollout(file: file, homePath: roots.homePath)
            }

            guard var resolved = record else { continue }
            if let indexItem = state.codexIndex[resolved.sessionID] {
                if let indexedTitle = indexItem.title, !indexedTitle.isEmpty {
                    resolved.title = indexedTitle
                }
                if let updatedAt = indexItem.updatedAt, updatedAt > resolved.lastActiveAt {
                    resolved.lastActiveAt = updatedAt
                }
            }
            nextCodexFiles[stateKey] = SessionHistoryCacheState.CodexEntry(
                stamp: stamp,
                record: resolved
            )
            results.append(resolved)
        }

        state.codexFiles = nextCodexFiles
        return results
    }

    /// 分块流式读取完整 JSONL（支持 `.jsonl` 与 `.jsonl.zst`），同时兼容末尾缺少换行符的最后一行，不将大文件一次性载入内存。
    @discardableResult
    static func streamAllJSONLLines(
        url: URL,
        chunkSize: Int = 64 * 1024,
        batchLines: Int = 512,
        onBatch: (ArraySlice<String>) -> Void
    ) -> Bool {
        let isZstd = url.pathExtension.lowercased() == "zst"
        let readChunk: (Int) throws -> Data?
        var fileHandle: FileHandle?
        var zstdReader: ZstdStreamReader?

        if isZstd {
            guard let reader = try? ZstdStreamReader(url: url) else { return false }
            zstdReader = reader
            readChunk = { count in try zstdReader?.read(upToCount: count) }
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            fileHandle = handle
            readChunk = { count in try fileHandle?.read(upToCount: count) }
        }
        defer { try? fileHandle?.close() }

        let newline = UInt8(ascii: "\n")
        var pending = Data()

        func emitData(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
                if line.last == "\r" { return String(line.dropLast()) }
                return String(line)
            }
            if lines.isEmpty { return }
            var idx = 0
            while idx < lines.count {
                let end = min(idx + batchLines, lines.count)
                onBatch(lines[idx..<end])
                idx = end
            }
            lines.removeAll(keepingCapacity: false)
        }

        while true {
            var finished = false
            var failed = false
            autoreleasepool {
                let chunk: Data?
                do {
                    chunk = try readChunk(chunkSize)
                } catch {
                    failed = true
                    return
                }
                guard let chunk, !chunk.isEmpty else {
                    finished = true
                    return
                }
                let appendedStart = pending.endIndex
                pending.append(chunk)
                guard let lastNewline = pending[appendedStart...].lastIndex(of: newline) else { return }
                let completeEnd = pending.index(after: lastNewline)
                let completePart = pending.subdata(in: pending.startIndex..<completeEnd)
                pending.removeSubrange(pending.startIndex..<completeEnd)
                emitData(completePart)
            }
            if failed { return false }
            if finished { break }
        }

        if !pending.isEmpty {
            autoreleasepool {
                emitData(pending)
                pending.removeAll(keepingCapacity: false)
            }
        }
        return true
    }

    static func readCodexSessionIndex(
        url: URL
    ) -> [String: SessionHistoryCacheState.CodexIndexItem] {
        var index: [String: SessionHistoryCacheState.CodexIndexItem] = [:]
        _ = streamAllJSONLLines(url: url) { batch in
            for line in batch {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawID = obj["id"] as? String
                else { continue }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                let title = cleanSummaryText(obj["thread_name"] as? String, maxLength: 140)
                let updatedAt = (obj["updated_at"] as? String).flatMap(parseTimestamp)
                var item = index[id] ?? SessionHistoryCacheState.CodexIndexItem()
                if let title { item.title = title }
                if let updatedAt {
                    item.updatedAt = max(item.updatedAt ?? .distantPast, updatedAt)
                }
                index[id] = item
            }
        }
        return index
    }

    static func parseCodexRollout(
        file: JSONLFileDescriptor,
        homePath: String
    ) -> SessionHistoryRecord? {
        let filenameUUID = codexSessionUUID(from: file.url)
        var ownSessionID = filenameUUID
        var sawOwnMeta = false
        var rawCwd: String?
        var isSubagent = false
        var createdAt: Date?
        var lastTimestamp: Date?
        var firstPrompt: String?
        var latestPrompt: String?
        var codexApproval: String?
        var codexSandbox: String?
        var gitBranch: String?

        let succeeded = streamAllJSONLLines(url: file.url) { batch in
            for line in batch {
                // 快速预筛：只对可能含时间戳、元数据或用户提问的行做 JSON 反序列化，避免大体积工具输出阻塞。
                if let ts = extractFastISO8601Timestamp(from: line) {
                    if createdAt == nil { createdAt = ts }
                    if lastTimestamp == nil || ts > lastTimestamp! {
                        lastTimestamp = ts
                    }
                }

                let maybeMeta = line.contains("\"session_meta\"") || line.contains("\"turn_context\"")
                let maybeUser = line.contains("\"user_message\"")
                    || line.contains("\"UserMessage\"")
                    || line.contains("\"role\":\"user\"")
                    || line.contains("\"role\": \"user\"")

                guard maybeMeta || maybeUser else { continue }
                // 超长行若仅是巨型工具负载则跳过完整反序列化（正常提问和 meta 远小于 256KB）
                guard line.utf8.count <= 262_144,
                      let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let tsString = root["timestamp"] as? String,
                   let ts = parseTimestamp(tsString) {
                    if createdAt == nil { createdAt = ts }
                    if lastTimestamp == nil || ts > lastTimestamp! {
                        lastTimestamp = ts
                    }
                }

                let type = root["type"] as? String
                if type == "session_meta", let payload = root["payload"] as? [String: Any] {
                    let metaID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                    if ownSessionID == nil { ownSessionID = metaID }
                    let historyBase = ((payload["history_base"] as? [String: Any])?["thread_id"] as? String)
                    let isOwnMeta = metaID == nil
                        || metaID == ownSessionID
                        || (!sawOwnMeta && historyBase != nil && historyBase == metaID)
                    if isOwnMeta {
                        if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                            rawCwd = cwd
                        }
                        if isCodexSubagent(payload: payload) {
                            isSubagent = true
                        }
                        if let branch = (payload["git"] as? [String: Any])?["branch"] as? String,
                           !branch.isEmpty {
                            gitBranch = branch
                        }
                        if let metaTS = (payload["timestamp"] as? String).flatMap(parseTimestamp) {
                            if createdAt == nil { createdAt = metaTS }
                            if lastTimestamp == nil || metaTS > lastTimestamp! {
                                lastTimestamp = metaTS
                            }
                        }
                        sawOwnMeta = true
                    }
                    continue
                }

                if type == "turn_context", let payload = root["payload"] as? [String: Any] {
                    if rawCwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                        rawCwd = cwd
                    }
                    // 最近一次 turn_context 的审批与沙箱策略即原会话当前权限（只接受字符串，忽略未知结构）。
                    if let approval = payload["approval_policy"] as? String, !approval.isEmpty {
                        codexApproval = approval
                    }
                    if let sandbox = payload["sandbox_policy"] as? [String: Any],
                       let type = sandbox["type"] as? String, !type.isEmpty {
                        codexSandbox = type
                    } else if let sandbox = payload["sandbox_policy"] as? String, !sandbox.isEmpty {
                        codexSandbox = sandbox
                    }
                    continue
                }

                if let prompt = extractCodexUserPrompt(from: root, type: type) {
                    if firstPrompt == nil { firstPrompt = prompt }
                    latestPrompt = prompt
                }
            }
        }

        guard succeeded else { return nil }
        guard let sessionID = ownSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else { return nil }

        let fallbackMtime = Date(timeIntervalSince1970: file.modificationTime)
        let activeAt = lastTimestamp ?? fallbackMtime
        let normalized = normalizeProjectAndCwd(
            explicitCwd: rawCwd,
            inferredPaths: [],
            homePath: homePath
        )

        return SessionHistoryRecord(
            key: "codex:\(sessionID)",
            sessionID: sessionID,
            origin: .codex,
            cwd: normalized.cwd,
            projectName: normalized.projectName,
            lastActiveAt: activeAt,
            createdAt: createdAt ?? (file.creationTime > 0 ? Date(timeIntervalSince1970: file.creationTime) : nil),
            title: nil,
            summary: nil,
            firstPrompt: firstPrompt,
            latestPrompt: latestPrompt,
            isSubagent: isSubagent,
            permission: (codexApproval != nil || codexSandbox != nil)
                ? SessionLaunchPermission(codexApproval: codexApproval, codexSandbox: codexSandbox)
                : nil,
            gitBranch: gitBranch
        )
    }

    static func isCodexSubagent(payload: [String: Any]) -> Bool {
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return true
        }
        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty {
            return true
        }
        return false
    }

    static func extractCodexUserPrompt(from root: [String: Any], type: String?) -> String? {
        if type == "event_msg", let payload = root["payload"] as? [String: Any] {
            let subType = payload["type"] as? String
            if subType == "user_message", let msg = payload["message"] as? String {
                return cleanUserPromptText(msg)
            }
            if subType == "item_completed",
               let item = payload["item"] as? [String: Any],
               (item["type"] as? String) == "UserMessage" {
                if let text = extractTextFromContentArray(item["content"]) {
                    return cleanUserPromptText(text)
                }
            }
        }
        if type == "response_item",
           let payload = root["payload"] as? [String: Any],
           (payload["type"] as? String) == "message",
           (payload["role"] as? String) == "user" {
            if let text = extractTextFromContentArray(payload["content"]) {
                return cleanUserPromptText(text)
            }
        }
        return nil
    }

    static func extractTextFromContentArray(_ raw: Any?) -> String? {
        if let str = raw as? String { return str }
        guard let items = raw as? [[String: Any]] else { return nil }
        var pieces: [String] = []
        for item in items {
            let itemType = item["type"] as? String
            if itemType == "input_text" || itemType == "text" || itemType == "Text" {
                if let text = item["text"] as? String, !text.isEmpty {
                    pieces.append(text)
                }
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    static func codexSessionUUID(from url: URL) -> String? {
        let plainURL = JSONLDirectoryEnumerator.isZstd(url) ? url.deletingPathExtension() : url
        let name = plainURL.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }

}

// MARK: - SessionHistoryService (@MainActor Observable Coordinator)

@Observable
@MainActor
final class SessionHistoryService {
    private(set) var records: [SessionHistoryRecord] = []
    private(set) var recordsByKey: [String: SessionHistoryRecord] = [:]
    private(set) var localRecords: [SessionHistoryRecord] = []
    private(set) var isIndexing = false
    private(set) var lastIndexedAt: Date?
    private(set) var revision: UInt64 = 0
    private(set) var localRevision: UInt64 = 0

    @ObservationIgnored private var syncedRecords: [SessionHistoryRecord] = []
    /// 判断某个 `ConversationInfo.key` 是否仅来自其他同步设备（本机无日志档案）。
    @ObservationIgnored var isRemoteOnlyConversation: ((String) -> Bool)?
    @ObservationIgnored private var cacheState: SessionHistoryCacheState?
    @ObservationIgnored private var didLoadDiskCache = false
    @ObservationIgnored private var activeScanTask: Task<Void, Never>?
    @ObservationIgnored private var queuedRescan = false
    @ObservationIgnored private let roots: SessionHistoryRoots
    @ObservationIgnored private let cacheFileURL: URL?

    init(
        roots: SessionHistoryRoots = .production,
        cacheFileURL: URL? = SessionHistoryService.defaultCacheFileURL()
    ) {
        self.roots = roots
        self.cacheFileURL = cacheFileURL
    }

    nonisolated static func defaultCacheFileURL() -> URL? {
        guard !AppRuntime.isRunningUnitTests else { return nil }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("CCBar", isDirectory: true)
            .appendingPathComponent("session-history-cache-v1.json", isDirectory: false)
    }

    /// 非阻塞触发后台增量扫描（节流间隔默认 3 秒，强制刷新传 `minAge: 0`）。
    func refreshInBackground(minAge: TimeInterval = 3.0) {
        if let lastIndexedAt, Date().timeIntervalSince(lastIndexedAt) < minAge, !localRecords.isEmpty {
            return
        }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        if let activeScanTask {
            queuedRescan = true
            await activeScanTask.value
            return
        }

        let runner = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeScanTask = nil
                self.isIndexing = false
            }
            self.isIndexing = true
            repeat {
                self.queuedRescan = false
                let shouldLoadDisk = !self.didLoadDiskCache
                self.didLoadDiskCache = true
                let currentCache = self.cacheState
                let scanRoots = self.roots
                let diskURL = self.cacheFileURL

                let output = await Task.detached(priority: .utility) { () -> SessionHistoryScanner.ScanOutput in
                    var baseline = currentCache
                    if baseline == nil, shouldLoadDisk, let diskURL {
                        baseline = Self.loadDiskCache(from: diskURL)
                    }
                    let scanned = SessionHistoryScanner.scan(previous: baseline, roots: scanRoots)
                    if let diskURL, scanned.state != baseline {
                        Self.saveDiskCache(scanned.state, to: diskURL)
                    }
                    return scanned
                }.value

                self.cacheState = output.state
                self.applyLocalRecords(output.records)
                self.lastIndexedAt = Date()
            } while self.queuedRescan
        }
        activeScanTask = runner
        await runner.value
    }

    private func applyLocalRecords(_ newLocalRecords: [SessionHistoryRecord]) {
        guard localRecords != newLocalRecords else { return }
        localRecords = newLocalRecords
        localRevision &+= 1
        rebuildMergedRecords()
    }

    /// 替换其他设备云同步进来的会话摘要记录（仅存于内存，不写 `session-history-cache-v1.json`）。
    func replaceSyncedRecords(_ newSyncedRecords: [SessionHistoryRecord]) {
        guard syncedRecords != newSyncedRecords else { return }
        syncedRecords = newSyncedRecords
        rebuildMergedRecords()
    }

    private func rebuildMergedRecords() {
        let merged: [SessionHistoryRecord]
        if syncedRecords.isEmpty {
            merged = localRecords
        } else {
            let localKeys = Set(localRecords.map(\.key))
            var combined = localRecords
            combined.reserveCapacity(localRecords.count + syncedRecords.count)
            for synced in syncedRecords where !localKeys.contains(synced.key) {
                combined.append(synced)
            }
            combined.sort { lhs, rhs in
                if lhs.lastActiveAt == rhs.lastActiveAt { return lhs.key < rhs.key }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
            merged = combined
        }

        guard records != merged else { return }
        records = merged
        var map: [String: SessionHistoryRecord] = [:]
        map.reserveCapacity(merged.count)
        for record in merged {
            map[record.key] = record
        }
        recordsByKey = map
        revision &+= 1
    }

    func record(forKey key: String) -> SessionHistoryRecord? {
        recordsByKey[key]
    }

    func record(for info: ConversationInfo) -> SessionHistoryRecord? {
        if let exact = recordsByKey[info.key] {
            return exact
        }
        let altKey: String?
        switch info.app {
        case .codex:
            altKey = "codex:\(info.conversationID)"
        case .antigravity:
            altKey = "antigravity:\(info.conversationID)"
        case .claude:
            altKey = "claude:\(info.conversationID)"
        default:
            altKey = nil
        }
        return altKey.flatMap { recordsByKey[$0] }
    }

    /// 供某个 `ConversationInfo` 构造一键恢复命令（优先采用深度还原过 cwd 与 CLI/桌面端来源的索引记录）。
    /// 对仅存在于其他同步设备的远端对话返回 nil，避免生成本机无法执行的无效恢复命令。
    func resumeCommand(for info: ConversationInfo) -> SessionResumeCommand? {
        if let indexed = record(for: info) {
            guard !indexed.isRemoteSynced else { return nil }
            return indexed.resumeCommand
        }
        if isRemoteOnlyConversation?(info.key) == true {
            return nil
        }
        switch info.app {
        case .codex:
            let fallbackCwd = info.projectStatus.isPathBased ? info.projectPath : nil
            return SessionResumeCommand.build(
                origin: .codex,
                sessionID: info.conversationID,
                cwd: fallbackCwd,
                mode: SettingsStore.shared.resumePermissionMode
            )
        case .antigravity:
            let fallbackCwd = info.projectStatus.isPathBased ? info.projectPath : nil
            let isCLI = info.sourcePaths.contains { $0.lowercased().contains("antigravity-cli") || $0.lowercased().contains("antigravity-acp") }
            return SessionResumeCommand.build(
                origin: isCLI ? .antigravityCLI : .antigravityDesktop,
                sessionID: info.conversationID,
                cwd: fallbackCwd,
                mode: SettingsStore.shared.resumePermissionMode
            )
        case .claude:
            let fallbackCwd = info.projectStatus.isPathBased ? info.projectPath : nil
            return SessionResumeCommand.build(
                origin: .claudeCode,
                sessionID: info.conversationID,
                cwd: fallbackCwd,
                mode: SettingsStore.shared.resumePermissionMode
            )
        default:
            return nil
        }
    }

    /// 菜单栏弹窗快捷区与实时检索：忽略大小写按项目名、路径、标题摘要、提问关键词过滤。
    func querySessions(
        search: String,
        allowedApps: Set<UsageApp>? = nil,
        includeSubagentsWhenEmptySearch: Bool = false,
        limit: Int
    ) -> [SessionHistoryRecord] {
        let normalizedQuery = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [SessionHistoryRecord] = []
        result.reserveCapacity(min(limit, records.count))

        for record in records {
            if let allowedApps, !allowedApps.contains(record.origin.usageApp) {
                continue
            }
            if normalizedQuery.isEmpty && !includeSubagentsWhenEmptySearch && record.isSubagent {
                continue
            }
            guard record.matches(lowercasedQuery: normalizedQuery) else { continue }
            result.append(record)
            if result.count >= limit { break }
        }
        return result
    }

    nonisolated private static func loadDiskCache(from url: URL) -> SessionHistoryCacheState? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SessionHistoryCacheState.self, from: data),
              decoded.version == SessionHistoryCacheState.currentVersion
        else { return nil }
        return decoded
    }

    nonisolated private static func saveDiskCache(_ state: SessionHistoryCacheState, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
