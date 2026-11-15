import Foundation
import Observation
import SQLite3

// MARK: - Scan Roots & Incremental Cache State

nonisolated struct SessionHistoryRoots: Sendable {
    var codexHome: URL
    var antigravityRoots: [URL]
    var homePath: String

    static var production: SessionHistoryRoots {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return SessionHistoryRoots(
            codexHome: homeURL.appendingPathComponent(".codex", isDirectory: true),
            antigravityRoots: AntigravityScanner.defaultRoots(),
            homePath: homeURL.standardizedFileURL.path
        )
    }
}

nonisolated struct SessionHistoryCacheState: Sendable, Codable, Equatable {
    static let currentVersion = 1

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

    var version: Int = Self.currentVersion
    var codexIndexStamp: FileStamp?
    var codexIndex: [String: CodexIndexItem] = [:]
    var codexFiles: [String: CodexEntry] = [:]
    var antigravitySessions: [String: AntigravityEntry] = [:]
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
        let antigravityRecords = scanAntigravity(roots: roots, state: &nextState)

        var mergedByKey: [String: SessionHistoryRecord] = [:]
        mergedByKey.reserveCapacity(codexRecords.count + antigravityRecords.count)

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

    private static func mergeRecords(
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
            isSubagent: lhs.isSubagent && rhs.isSubagent
        )
    }

    // MARK: - 1. Codex CLI Session Parsing (Read-Only)

    private static func scanCodex(
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
    private static func streamAllJSONLLines(
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

    private static func readCodexSessionIndex(
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

    private static func parseCodexRollout(
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
            isSubagent: isSubagent
        )
    }

    private static func isCodexSubagent(payload: [String: Any]) -> Bool {
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return true
        }
        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty {
            return true
        }
        return false
    }

    private static func extractCodexUserPrompt(from root: [String: Any], type: String?) -> String? {
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

    private static func extractTextFromContentArray(_ raw: Any?) -> String? {
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

    // MARK: - 2. Antigravity Session Parsing (Strictly Read-Only SQLite + Transcripts)

    private nonisolated struct AntigravitySummaryRow {
        var id: String
        var title: String?
        var preview: String?
        var lastModified: Date?
        var created: Date?
        var workspacePaths: [String] = []
        var source: String?
        var appDataDir: String?
        var parentID: String?
        var fromCLIRoot: Bool
    }

    private nonisolated struct AntigravityHistoryEntry {
        var firstPrompt: String?
        var latestPrompt: String?
        var workspace: String?
        var lastTimestamp: Date?
    }

    private nonisolated struct AntigravityMetadataItem {
        var summary: String?
        var lastModified: Date?
        var created: Date?
    }

    private static func scanAntigravity(
        roots: SessionHistoryRoots,
        state: inout SessionHistoryCacheState
    ) -> [SessionHistoryRecord] {
        let fm = FileManager.default
        var summaryRows: [String: AntigravitySummaryRow] = [:]
        var historyEntries: [String: AntigravityHistoryEntry] = [:]
        var metadataItems: [String: AntigravityMetadataItem] = [:]
        var protoTitles: [String: String] = [:]
        var dbURLsByID: [String: [URL]] = [:]
        var transcriptURLsByID: [String: [URL]] = [:]
        var annotationURLsByID: [String: [URL]] = [:]
        var cliKnownIDs: Set<String> = []

        var seenRealPaths: Set<String> = []

        for root in roots.antigravityRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let rootName = root.lastPathComponent.lowercased()
            let isCLIRoot = rootName.contains("cli") || rootName.contains("acp")

            // 1) conversation_summaries.db (只读 SQLite)
            let summariesDB = root.appendingPathComponent("conversation_summaries.db", isDirectory: false)
            if fm.fileExists(atPath: summariesDB.path) {
                for row in readAntigravitySummariesDB(url: summariesDB, isCLIRoot: isCLIRoot) {
                    if row.fromCLIRoot
                        || row.source == "CORTEX_TRAJECTORY_SOURCE_CLI"
                        || row.appDataDir?.lowercased().contains("cli") == true {
                        cliKnownIDs.insert(row.id)
                    }
                    if let existing = summaryRows[row.id] {
                        summaryRows[row.id] = mergeSummaryRow(existing, row)
                    } else {
                        summaryRows[row.id] = row
                    }
                }
            }

            // 2) history.jsonl (CLI 历史索引)
            let historyURL = root.appendingPathComponent("history.jsonl", isDirectory: false)
            if fm.fileExists(atPath: historyURL.path) {
                for (id, entry) in readAntigravityHistoryJSONL(url: historyURL) {
                    if isCLIRoot { cliKnownIDs.insert(id) }
                    if var existing = historyEntries[id] {
                        existing.firstPrompt = existing.firstPrompt ?? entry.firstPrompt
                        if let tNew = entry.lastTimestamp, (existing.lastTimestamp == nil || tNew >= existing.lastTimestamp!) {
                            existing.latestPrompt = entry.latestPrompt ?? existing.latestPrompt
                            existing.workspace = entry.workspace ?? existing.workspace
                            existing.lastTimestamp = tNew
                        } else {
                            existing.latestPrompt = existing.latestPrompt ?? entry.latestPrompt
                            existing.workspace = existing.workspace ?? entry.workspace
                        }
                        historyEntries[id] = existing
                    } else {
                        historyEntries[id] = entry
                    }
                }
            }

            // 3) cache/conversation_metadata.json
            let metadataURL = root.appendingPathComponent("cache/conversation_metadata.json", isDirectory: false)
            if fm.fileExists(atPath: metadataURL.path) {
                for (id, meta) in readAntigravityMetadataJSON(url: metadataURL) where metadataItems[id] == nil {
                    if isCLIRoot { cliKnownIDs.insert(id) }
                    metadataItems[id] = meta
                }
            }

            // 4) agyhub_summaries_proto.pb (Desktop 标题缓存)
            for pbName in ["agyhub_summaries_proto.pb", "jetbox_summaries_proto.pb"] {
                let pbURL = root.appendingPathComponent(pbName, isDirectory: false)
                if let size = (try? fm.attributesOfItem(atPath: pbURL.path))?[.size] as? NSNumber,
                   size.intValue <= 32 * 1_048_576,
                   let data = try? Data(contentsOf: pbURL, options: .mappedIfSafe),
                   let fields = AntigravityScanner.Proto.fields(Array(data)) {
                    for bytes in fields.allBytes(1) {
                        guard let entry = AntigravityScanner.Proto.fields(bytes),
                              let id = entry.text(1),
                              protoTitles[id] == nil,
                              let title = cleanSummaryText(entry.message(2)?.text(1), maxLength: 140)
                        else { continue }
                        protoTitles[id] = title
                    }
                }
            }

            // 5) conversations/<id>.db
            let convDir = root.appendingPathComponent("conversations", isDirectory: true)
            if let names = try? fm.contentsOfDirectory(atPath: convDir.path) {
                for name in names.sorted() where name.hasSuffix(".db") {
                    let dbURL = convDir.appendingPathComponent(name, isDirectory: false)
                    guard seenRealPaths.insert(dbURL.resolvingSymlinksInPath().path).inserted else { continue }
                    let id = String(name.dropLast(3))
                    guard !id.isEmpty else { continue }
                    if isCLIRoot { cliKnownIDs.insert(id) }
                    dbURLsByID[id, default: []].append(dbURL)
                }
            }

            // 6) brain/<id>/.system_generated/logs/transcript.jsonl
            let brainDir = root.appendingPathComponent("brain", isDirectory: true)
            if let brainIDs = try? fm.contentsOfDirectory(atPath: brainDir.path) {
                for id in brainIDs.sorted() where !id.hasPrefix(".") {
                    let transcriptURL = brainDir
                        .appendingPathComponent(id, isDirectory: true)
                        .appendingPathComponent(".system_generated/logs/transcript.jsonl", isDirectory: false)
                    guard fm.fileExists(atPath: transcriptURL.path),
                          seenRealPaths.insert(transcriptURL.resolvingSymlinksInPath().path).inserted
                    else { continue }
                    if isCLIRoot { cliKnownIDs.insert(id) }
                    transcriptURLsByID[id, default: []].append(transcriptURL)
                }
            }

            // 7) annotations/<id>.pbtxt
            let annotationsDir = root.appendingPathComponent("annotations", isDirectory: true)
            if let names = try? fm.contentsOfDirectory(atPath: annotationsDir.path) {
                for name in names.sorted() where name.hasSuffix(".pbtxt") {
                    let id = String(name.dropLast(6))
                    guard !id.isEmpty else { continue }
                    annotationURLsByID[id, default: []].append(annotationsDir.appendingPathComponent(name, isDirectory: false))
                }
            }
        }

        var allIDs = Set<String>()
        allIDs.formUnion(summaryRows.keys)
        allIDs.formUnion(historyEntries.keys)
        allIDs.formUnion(dbURLsByID.keys)
        allIDs.formUnion(transcriptURLsByID.keys)

        var nextSessions: [String: SessionHistoryCacheState.AntigravityEntry] = [:]
        nextSessions.reserveCapacity(allIDs.count)
        var records: [SessionHistoryRecord] = []
        records.reserveCapacity(allIDs.count)

        for id in allIDs.sorted() {
            let dbURLs = dbURLsByID[id] ?? []
            let transcriptURLs = transcriptURLsByID[id] ?? []
            let annotationURLs = annotationURLsByID[id] ?? []
            let summaryRow = summaryRows[id]
            let historyEntry = historyEntries[id]
            let metaItem = metadataItems[id]
            let protoTitle = protoTitles[id]
            let isCLIHint = cliKnownIDs.contains(id)

            let signature = buildAntigravitySignature(
                id: id,
                isCLIHint: isCLIHint,
                summaryRow: summaryRow,
                historyEntry: historyEntry,
                metaItem: metaItem,
                protoTitle: protoTitle,
                dbURLs: dbURLs,
                transcriptURLs: transcriptURLs,
                annotationURLs: annotationURLs
            )

            if let cached = state.antigravitySessions[id], cached.compositeSignature == signature {
                nextSessions[id] = cached
                records.append(cached.record)
                continue
            }

            guard let built = buildAntigravityRecord(
                id: id,
                isCLIHint: isCLIHint,
                summaryRow: summaryRow,
                historyEntry: historyEntry,
                metaItem: metaItem,
                protoTitle: protoTitle,
                dbURLs: dbURLs,
                transcriptURLs: transcriptURLs,
                annotationURLs: annotationURLs,
                homePath: roots.homePath
            ) else { continue }

            nextSessions[id] = SessionHistoryCacheState.AntigravityEntry(
                compositeSignature: signature,
                record: built
            )
            records.append(built)
        }

        state.antigravitySessions = nextSessions
        return records
    }

    private static func mergeSummaryRow(
        _ lhs: AntigravitySummaryRow,
        _ rhs: AntigravitySummaryRow
    ) -> AntigravitySummaryRow {
        AntigravitySummaryRow(
            id: lhs.id,
            title: lhs.title ?? rhs.title,
            preview: lhs.preview ?? rhs.preview,
            lastModified: [lhs.lastModified, rhs.lastModified].compactMap { $0 }.max(),
            created: [lhs.created, rhs.created].compactMap { $0 }.min(),
            workspacePaths: lhs.workspacePaths + rhs.workspacePaths,
            source: lhs.source ?? rhs.source,
            appDataDir: lhs.appDataDir ?? rhs.appDataDir,
            parentID: lhs.parentID ?? rhs.parentID,
            fromCLIRoot: lhs.fromCLIRoot || rhs.fromCLIRoot
        )
    }

    private static func buildAntigravitySignature(
        id: String,
        isCLIHint: Bool,
        summaryRow: AntigravitySummaryRow?,
        historyEntry: AntigravityHistoryEntry?,
        metaItem: AntigravityMetadataItem?,
        protoTitle: String?,
        dbURLs: [URL],
        transcriptURLs: [URL],
        annotationURLs: [URL]
    ) -> String {
        var parts: [String] = [
            id,
            isCLIHint ? "cli" : "desk",
            summaryRow?.title ?? "",
            summaryRow?.preview ?? "",
            summaryRow?.source ?? "",
            summaryRow?.workspacePaths.joined(separator: ",") ?? "",
            String(summaryRow?.lastModified?.timeIntervalSince1970 ?? 0),
            historyEntry?.latestPrompt ?? "",
            historyEntry?.workspace ?? "",
            String(historyEntry?.lastTimestamp?.timeIntervalSince1970 ?? 0),
            metaItem?.summary ?? "",
            protoTitle ?? "",
        ]
        for url in dbURLs + transcriptURLs + annotationURLs {
            if let stamp = fileStamp(of: url) {
                parts.append("\(url.path):\(stamp.size):\(stamp.mtime):\(stamp.walSize):\(stamp.walMtime)")
            }
        }
        return parts.joined(separator: "|")
    }

    private static func buildAntigravityRecord(
        id: String,
        isCLIHint: Bool,
        summaryRow: AntigravitySummaryRow?,
        historyEntry: AntigravityHistoryEntry?,
        metaItem: AntigravityMetadataItem?,
        protoTitle: String?,
        dbURLs: [URL],
        transcriptURLs: [URL],
        annotationURLs: [URL],
        homePath: String
    ) -> SessionHistoryRecord? {
        var explicitWorkspaces: [String] = []
        if let summaryPaths = summaryRow?.workspacePaths {
            explicitWorkspaces.append(contentsOf: summaryPaths)
        }
        if let histWorkspace = historyEntry?.workspace, !histWorkspace.isEmpty {
            explicitWorkspaces.append(histWorkspace)
        }

        var dbSourceCodes: Set<Int64> = []
        var dbParentID: String?
        var dbCreatedAt: Date?
        var dbModifiedAt: Date?
        var inferredPaths: [String] = []

        for dbURL in dbURLs {
            if let mod = (try? FileManager.default.attributesOfItem(atPath: dbURL.path))?[.modificationDate] as? Date {
                dbModifiedAt = max(dbModifiedAt ?? .distantPast, mod)
            }
            if let info = readAntigravityConversationDB(url: dbURL, needStepPaths: transcriptURLs.isEmpty) {
                if let ws = info.workspacePath, !ws.isEmpty {
                    explicitWorkspaces.append(ws)
                }
                inferredPaths.append(contentsOf: info.inferredPaths)
                if let src = info.trajectorySource {
                    dbSourceCodes.insert(src)
                }
                if let parent = info.parentConversationID, !parent.isEmpty {
                    dbParentID = dbParentID ?? parent
                }
                if let created = info.createdAt {
                    dbCreatedAt = [dbCreatedAt, created].compactMap { $0 }.min()
                }
            }
        }

        var firstPrompt: String?
        var latestPrompt: String?
        var transcriptLastAt: Date?
        var transcriptCreatedAt: Date?

        let hasSpecificExplicitWorkspace = explicitWorkspaces.contains { raw in
            isSpecificWorkspacePath(raw, homePath: homePath)
        }

        for transcriptURL in transcriptURLs {
            if let mod = (try? FileManager.default.attributesOfItem(atPath: transcriptURL.path))?[.modificationDate] as? Date {
                transcriptLastAt = max(transcriptLastAt ?? .distantPast, mod)
            }
            let parsed = parseAntigravityTranscript(
                url: transcriptURL,
                extractToolPaths: !hasSpecificExplicitWorkspace
            )
            if firstPrompt == nil { firstPrompt = parsed.firstPrompt }
            if let latest = parsed.latestPrompt { latestPrompt = latest }
            if let created = parsed.firstAt {
                transcriptCreatedAt = [transcriptCreatedAt, created].compactMap { $0 }.min()
            }
            if let last = parsed.lastAt {
                transcriptLastAt = max(transcriptLastAt ?? .distantPast, last)
            }
            inferredPaths.append(contentsOf: parsed.candidatePaths)
            if let activeWs = parsed.activeWorkspace, !activeWs.isEmpty {
                explicitWorkspaces.append(activeWs)
            }
        }

        firstPrompt = firstPrompt ?? historyEntry?.firstPrompt
        latestPrompt = latestPrompt ?? historyEntry?.latestPrompt

        var annotationTitle: String?
        for annURL in annotationURLs {
            if let size = (try? FileManager.default.attributesOfItem(atPath: annURL.path))?[.size] as? NSNumber,
               size.intValue <= 1_048_576,
               let data = try? Data(contentsOf: annURL),
               let parsedTitle = AntigravityScanner.parseAnnotationTitle(data) {
                annotationTitle = parsedTitle
                break
            }
        }

        let resolvedTitle = annotationTitle
            ?? summaryRow?.title
            ?? protoTitle
            ?? metaItem?.summary

        let resolvedSummary = summaryRow?.preview ?? metaItem?.summary

        // CLI vs 桌面端来源判定：
        // - 存在于 antigravity-cli / antigravity-acp 数据根
        // - 或 conversation_summaries.source == CORTEX_TRAJECTORY_SOURCE_CLI / app_data_dir 含 cli
        // - 或 trajectory_meta.source == 17（CLI 轨迹枚举值）
        let isCLI = isCLIHint
            || summaryRow?.source == "CORTEX_TRAJECTORY_SOURCE_CLI"
            || summaryRow?.appDataDir?.lowercased().contains("cli") == true
            || dbSourceCodes.contains(17)
        let origin: SessionOrigin = isCLI ? .antigravityCLI : .antigravityDesktop

        let bestExplicit = explicitWorkspaces.first(where: { isSpecificWorkspacePath($0, homePath: homePath) })
            ?? explicitWorkspaces.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        let normalized = normalizeProjectAndCwd(
            explicitCwd: bestExplicit,
            inferredPaths: inferredPaths,
            homePath: homePath
        )

        let lastActiveCandidates: [Date?] = [
            summaryRow?.lastModified,
            historyEntry?.lastTimestamp,
            metaItem?.lastModified,
            transcriptLastAt,
            dbModifiedAt,
        ]
        guard let lastActiveAt = lastActiveCandidates.compactMap({ $0 }).max() else {
            return nil
        }

        let createdAt = [
            summaryRow?.created,
            metaItem?.created,
            transcriptCreatedAt,
            dbCreatedAt,
        ].compactMap { $0 }.min()

        let isSubagent = !(summaryRow?.parentID ?? dbParentID ?? "").isEmpty

        return SessionHistoryRecord(
            key: "antigravity:\(id)",
            sessionID: id,
            origin: origin,
            cwd: normalized.cwd,
            projectName: normalized.projectName,
            lastActiveAt: lastActiveAt,
            createdAt: createdAt,
            title: resolvedTitle,
            summary: resolvedSummary,
            firstPrompt: firstPrompt,
            latestPrompt: latestPrompt,
            isSubagent: isSubagent
        )
    }

    private nonisolated struct AntigravityDBInfo {
        var workspacePath: String?
        var inferredPaths: [String] = []
        var trajectorySource: Int64?
        var parentConversationID: String?
        var createdAt: Date?
    }

    private static func readAntigravitySummariesDB(
        url: URL,
        isCLIRoot: Bool
    ) -> [AntigravitySummaryRow] {
        var rowsResult: [AntigravitySummaryRow] = []
        try? withReadOnlySQLite(url) { db in
            let cols = sqliteColumns(db, table: "conversation_summaries")
            guard cols.contains("conversation_id") else { return }

            let selectCols = [
                "conversation_id",
                cols.contains("title") ? "title" : "NULL",
                cols.contains("preview") ? "preview" : "NULL",
                cols.contains("last_modified_time") ? "last_modified_time" : "NULL",
                cols.contains("created_time") ? "created_time" : "NULL",
                cols.contains("workspace_uris") ? "workspace_uris" : "NULL",
                cols.contains("source") ? "source" : "NULL",
                cols.contains("app_data_dir") ? "app_data_dir" : "NULL",
                cols.contains("parent_conversation_id") ? "parent_conversation_id" : "NULL",
            ].joined(separator: ", ")

            let sql = "SELECT \(selectCols) FROM conversation_summaries"
            sqliteRows(db, sql: sql) { stmt in
                guard let id = sqliteText(stmt, 0)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty
                else { return }
                let title = cleanSummaryText(sqliteText(stmt, 1), maxLength: 140)
                let preview = cleanSummaryText(sqliteText(stmt, 2), maxLength: 240)
                let lastModified = sqliteText(stmt, 3).flatMap(parseTimestamp)
                let created = sqliteText(stmt, 4).flatMap(parseTimestamp)
                let workspaceURIsJSON = sqliteText(stmt, 5)
                let source = sqliteText(stmt, 6)
                let appDataDir = sqliteText(stmt, 7)
                let parentID = sqliteText(stmt, 8)

                var workspaces: [String] = []
                if let workspaceURIsJSON,
                   let data = workspaceURIsJSON.data(using: .utf8),
                   let uris = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    workspaces = uris.compactMap(fileURIToPath)
                }

                rowsResult.append(AntigravitySummaryRow(
                    id: id,
                    title: title,
                    preview: preview,
                    lastModified: lastModified,
                    created: created,
                    workspacePaths: workspaces,
                    source: source,
                    appDataDir: appDataDir,
                    parentID: parentID,
                    fromCLIRoot: isCLIRoot
                ))
            }
        }
        return rowsResult
    }

    private static func readAntigravityConversationDB(
        url: URL,
        needStepPaths: Bool
    ) -> AntigravityDBInfo? {
        var info = AntigravityDBInfo()
        do {
            try withReadOnlySQLite(url) { db in
                let tables = sqliteTables(db)

                if tables.contains("trajectory_meta") {
                    let cols = sqliteColumns(db, table: "trajectory_meta")
                    let srcExpr = cols.contains("source") ? "source" : "NULL"
                    let parentExpr = cols.contains("parent_conversation_id") ? "parent_conversation_id" : "NULL"
                    sqliteRows(db, sql: "SELECT \(srcExpr), \(parentExpr) FROM trajectory_meta LIMIT 1") { stmt in
                        if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                            info.trajectorySource = sqlite3_column_int64(stmt, 0)
                        }
                        info.parentConversationID = sqliteText(stmt, 1)
                    }
                }

                if tables.contains("trajectory_metadata_blob") {
                    sqliteRows(db, sql: "SELECT data FROM trajectory_metadata_blob LIMIT 4") { stmt in
                        guard let blob = sqliteBlob(stmt, 0) else { return }
                        if let fields = AntigravityScanner.Proto.fields(blob) {
                            if info.workspacePath == nil,
                               let ws = fields.message(1)?.text(1),
                               let path = fileURIToPath(ws) {
                                info.workspacePath = path
                            }
                            if info.createdAt == nil,
                               let tsFields = fields.message(2),
                               let seconds = tsFields.varint(1),
                               seconds > 1_500_000_000, seconds < 4_102_444_800 {
                                let nanos = Double(tsFields.varint(2) ?? 0) / 1_000_000_000
                                info.createdAt = Date(timeIntervalSince1970: Double(seconds) + nanos)
                            }
                        }
                        info.inferredPaths.append(contentsOf: extractFileURIPaths(fromUTF8Bytes: blob))
                    }
                }

                // 若缺少 transcript.jsonl 且未拿到明确项目路径，从 steps 前若干条轻量提取 file:/// 路径（限制字节避免读大负载）。
                if needStepPaths && (info.workspacePath == nil || info.workspacePath == "/") && tables.contains("steps") {
                    let cols = sqliteColumns(db, table: "steps")
                    if cols.contains("step_payload") {
                        sqliteRows(
                            db,
                            sql: "SELECT substr(step_payload, 1, 16384) FROM steps WHERE instr(step_payload, 'file:///') > 0 LIMIT 40"
                        ) { stmt in
                            if let blob = sqliteBlob(stmt, 0) {
                                info.inferredPaths.append(contentsOf: extractFileURIPaths(fromUTF8Bytes: blob))
                            }
                        }
                    }
                }
            }
            return info
        } catch {
            return nil
        }
    }

    private static func readAntigravityHistoryJSONL(
        url: URL
    ) -> [String: AntigravityHistoryEntry] {
        var entries: [String: AntigravityHistoryEntry] = [:]
        _ = streamAllJSONLLines(url: url) { batch in
            for line in batch {
                guard line.utf8.count <= 131_072,
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = (obj["conversationId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty
                else { continue }
                let prompt = cleanUserPromptText(obj["display"] as? String)
                let workspace = (obj["workspace"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let ts: Date?
                if let ms = obj["timestamp"] as? Double {
                    ts = Date(timeIntervalSince1970: ms > 10_000_000_000 ? ms / 1000.0 : ms)
                } else if let msInt = obj["timestamp"] as? Int64 {
                    let v = Double(msInt)
                    ts = Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000.0 : v)
                } else {
                    ts = nil
                }

                var entry = entries[id] ?? AntigravityHistoryEntry()
                if entry.firstPrompt == nil { entry.firstPrompt = prompt }
                if let prompt { entry.latestPrompt = prompt }
                if let workspace, !workspace.isEmpty { entry.workspace = workspace }
                if let ts { entry.lastTimestamp = max(entry.lastTimestamp ?? .distantPast, ts) }
                entries[id] = entry
            }
        }
        return entries
    }

    private static func readAntigravityMetadataJSON(
        url: URL
    ) -> [String: AntigravityMetadataItem] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= 16 * 1_048_576,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: AntigravityMetadataItem] = [:]
        for (id, rawVal) in root {
            guard let dict = rawVal as? [String: Any] else { continue }
            let summary = cleanSummaryText(dict["summary"] as? String, maxLength: 200)
            let lastMod = (dict["lastModifiedTime"] as? String).flatMap(parseTimestamp)
            let created = (dict["createdTime"] as? String).flatMap(parseTimestamp)
            result[id] = AntigravityMetadataItem(summary: summary, lastModified: lastMod, created: created)
        }
        return result
    }

    private nonisolated struct ParsedTranscript {
        var firstPrompt: String?
        var latestPrompt: String?
        var firstAt: Date?
        var lastAt: Date?
        var activeWorkspace: String?
        var candidatePaths: [String] = []
    }

    private static func parseAntigravityTranscript(
        url: URL,
        extractToolPaths: Bool
    ) -> ParsedTranscript {
        var parsed = ParsedTranscript()
        _ = streamAllJSONLLines(url: url) { batch in
            for line in batch {
                if let ts = extractFastCreatedAtTimestamp(from: line) {
                    if parsed.firstAt == nil { parsed.firstAt = ts }
                    if parsed.lastAt == nil || ts > parsed.lastAt! {
                        parsed.lastAt = ts
                    }
                }

                let isUserInput = line.contains("\"USER_INPUT\"")
                let needsToolScan = extractToolPaths && parsed.candidatePaths.count < 40 && (
                    line.contains("\"tool_calls\"")
                        || line.contains("file:///")
                        || line.contains("Active Workspaces:")
                )
                guard isUserInput || needsToolScan else { continue }

                if line.utf8.count <= 262_144,
                   let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let createdStr = obj["created_at"] as? String,
                       let ts = parseTimestamp(createdStr) {
                        if parsed.firstAt == nil { parsed.firstAt = ts }
                        if parsed.lastAt == nil || ts > parsed.lastAt! {
                            parsed.lastAt = ts
                        }
                    }

                    if (obj["type"] as? String) == "USER_INPUT",
                       let content = obj["content"] as? String {
                        if parsed.activeWorkspace == nil,
                           let ws = extractActiveWorkspaceFromPrompt(content) {
                            parsed.activeWorkspace = ws
                        }
                        if let prompt = extractAntigravityUserPrompt(content) {
                            if parsed.firstPrompt == nil { parsed.firstPrompt = prompt }
                            parsed.latestPrompt = prompt
                        }
                    }

                    if needsToolScan {
                        if let toolCalls = obj["tool_calls"] as? [[String: Any]] {
                            for call in toolCalls {
                                guard let args = call["arguments"] as? [String: Any] else { continue }
                                for key in ["Cwd", "cwd", "Path", "path", "TargetFile", "Directory"] {
                                    if let p = args[key] as? String, p.hasPrefix("/") {
                                        parsed.candidatePaths.append(p)
                                    }
                                }
                                if let cmd = args["CommandLine"] as? String ?? args["command"] as? String {
                                    parsed.candidatePaths.append(contentsOf: extractPathsFromShellCommand(cmd))
                                }
                            }
                        }
                        if let content = obj["content"] as? String, content.contains("file:///") {
                            parsed.candidatePaths.append(contentsOf: extractFileURIPaths(fromString: content))
                        }
                    }
                } else if needsToolScan {
                    // 超长行仅用轻量正则扫描 file:/// URI，不整体解码大 JSON
                    parsed.candidatePaths.append(contentsOf: extractFileURIPaths(fromString: String(line.prefix(32_768))))
                }
            }
        }
        return parsed
    }

    // MARK: - Strictly Read-Only SQLite Helpers

    private nonisolated struct SQLiteReadError: Error {
        var code: Int32
    }

    /// 严格只读打开 SQLite：绝不传 `SQLITE_OPEN_READWRITE` 或 `SQLITE_OPEN_CREATE`。
    /// 若数据库无 `-wal`/`-shm` 且因目录权限等返回 `SQLITE_CANTOPEN`，降级使用 `immutable=1` URI 只读打开。
    private static func withReadOnlySQLite(
        _ url: URL,
        body: (OpaquePointer) throws -> Void
    ) throws {
        do {
            try openReadOnlySQLite(url, immutable: false, body: body)
        } catch let err as SQLiteReadError
            where (err.code & 0xff) == SQLITE_CANTOPEN
            && !FileManager.default.fileExists(atPath: url.path + "-wal")
            && !FileManager.default.fileExists(atPath: url.path + "-shm") {
            try openReadOnlySQLite(url, immutable: true, body: body)
        }
    }

    private static func openReadOnlySQLite(
        _ url: URL,
        immutable: Bool,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var opened: OpaquePointer?
        let filename = immutable ? "\(url.absoluteURL.absoluteString)?immutable=1" : url.path
        let flags = immutable ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) : SQLITE_OPEN_READONLY
        let rc = sqlite3_open_v2(filename, &opened, flags, nil)
        guard rc == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteReadError(code: rc)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 1500)
        // 强制 query_only，双重保障绝不产生任何写操作
        _ = sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)
        try body(db)
    }

    private static func sqliteTables(_ db: OpaquePointer) -> Set<String> {
        var names: Set<String> = []
        sqliteRows(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") { stmt in
            if let name = sqliteText(stmt, 0) { names.insert(name) }
        }
        return names
    }

    private static func sqliteColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        var cols: Set<String> = []
        sqliteRows(db, sql: "PRAGMA table_info(\(table))") { stmt in
            if let name = sqliteText(stmt, 1) { cols.insert(name) }
        }
        return cols
    }

    private static func sqliteRows(
        _ db: OpaquePointer,
        sql: String,
        body: (OpaquePointer) -> Void
    ) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                body(stmt)
            }
        }
    }

    private static func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private static func sqliteBlob(_ stmt: OpaquePointer, _ index: Int32) -> [UInt8]? {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        return Array(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    // MARK: - Path Normalization & Real Project CWD Recovery (TCC-Safe)

    private static func isSpecificWorkspacePath(_ raw: String, homePath: String) -> Bool {
        let cleaned = standardizePathString(raw)
        guard !cleaned.isEmpty, cleaned != "/", cleaned != homePath else { return false }
        return !isIgnoredSystemOrConfigPath(cleaned, homePath: homePath)
    }

    private static func preferredCwd(_ primary: String?, fallback: String?, homePath: String) -> String? {
        if let primary, isSpecificWorkspacePath(primary, homePath: homePath) { return primary }
        if let fallback, isSpecificWorkspacePath(fallback, homePath: homePath) { return fallback }
        return primary ?? fallback
    }

    /// 结合显式 workspace 与工具调用/URI 候选路径还原真实项目目录（严格遵循 TCC 保护目录不触盘原则）。
    static func normalizeProjectAndCwd(
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

    private static func resolveProjectDirectory(
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

    private static func nearestGitRoot(from directoryURL: URL, homePath: String) -> URL? {
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

    private static func isIgnoredSystemOrConfigPath(_ path: String, homePath: String) -> Bool {
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

    private static func standardizePathString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let fromURI = fileURIToPath(trimmed) {
            return URL(fileURLWithPath: fromURI).standardizedFileURL.path
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func fileURIToPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("file://") else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        let stripped = String(trimmed.dropFirst("file://".count))
        return stripped.removingPercentEncoding ?? stripped
    }

    // MARK: - Text & URI Extraction Helpers

    private static let fileURIRegex = try? NSRegularExpression(
        pattern: #"file:///[^\s\"'<>`)\]}]+"#
    )

    private static func extractFileURIPaths(fromUTF8Bytes bytes: [UInt8]) -> [String] {
        let text = String(decoding: bytes, as: UTF8.self)
        return extractFileURIPaths(fromString: text)
    }

    private static func extractFileURIPaths(fromString text: String) -> [String] {
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

    private static func extractPathsFromShellCommand(_ cmd: String) -> [String] {
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

    private static func extractActiveWorkspaceFromPrompt(_ content: String) -> String? {
        guard let marker = content.range(of: "Command Working Directory:") else { return nil }
        let rest = content[marker.upperBound...]
        guard let lineEnd = rest.firstIndex(where: \.isNewline) else {
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest[..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractAntigravityUserPrompt(_ content: String) -> String? {
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
    static func cleanUserPromptText(_ raw: String?) -> String? {
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

    static func cleanSummaryText(_ raw: String?, maxLength: Int) -> String? {
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

    private static func fileStamp(of url: URL) -> SessionHistoryCacheState.FileStamp? {
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

    private static func parseTimestamp(_ raw: String) -> Date? {
        if let parsed = JSONLTimestamp.parse(raw) { return parsed }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func extractFastISO8601Timestamp(from line: String) -> Date? {
        guard let keyRange = line.range(of: "\"timestamp\":\"") ?? line.range(of: "\"timestamp\": \"") else {
            return nil
        }
        let start = keyRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        return JSONLTimestamp.parse(String(line[start..<end]))
    }

    private static func extractFastCreatedAtTimestamp(from line: String) -> Date? {
        guard let keyRange = line.range(of: "\"created_at\":\"") ?? line.range(of: "\"created_at\": \"") else {
            return nil
        }
        let start = keyRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        return JSONLTimestamp.parse(String(line[start..<end]))
    }
}

// MARK: - SessionHistoryService (@MainActor Observable Coordinator)

@Observable
@MainActor
final class SessionHistoryService {
    private(set) var records: [SessionHistoryRecord] = []
    private(set) var recordsByKey: [String: SessionHistoryRecord] = [:]
    private(set) var isIndexing = false
    private(set) var lastIndexedAt: Date?
    private(set) var revision: UInt64 = 0

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
        if let lastIndexedAt, Date().timeIntervalSince(lastIndexedAt) < minAge, !records.isEmpty {
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
                self.applyRecords(output.records)
                self.lastIndexedAt = Date()
            } while self.queuedRescan
        }
        activeScanTask = runner
        await runner.value
    }

    private func applyRecords(_ newRecords: [SessionHistoryRecord]) {
        guard records != newRecords else { return }
        records = newRecords
        var map: [String: SessionHistoryRecord] = [:]
        map.reserveCapacity(newRecords.count)
        for record in newRecords {
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
        default:
            altKey = nil
        }
        return altKey.flatMap { recordsByKey[$0] }
    }

    /// 供某个 `ConversationInfo` 构造一键恢复命令（优先采用深度还原过 cwd 与 CLI/桌面端来源的索引记录）。
    func resumeCommand(for info: ConversationInfo) -> SessionResumeCommand? {
        if let indexed = record(for: info) {
            return indexed.resumeCommand
        }
        switch info.app {
        case .codex:
            let fallbackCwd = info.projectStatus.isPathBased ? info.projectPath : nil
            return SessionResumeCommand.build(
                origin: .codex,
                sessionID: info.conversationID,
                cwd: fallbackCwd
            )
        case .antigravity:
            let fallbackCwd = info.projectStatus.isPathBased ? info.projectPath : nil
            let isCLI = info.sourcePaths.contains { $0.lowercased().contains("antigravity-cli") || $0.lowercased().contains("antigravity-acp") }
            return SessionResumeCommand.build(
                origin: isCLI ? .antigravityCLI : .antigravityDesktop,
                sessionID: info.conversationID,
                cwd: fallbackCwd
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
