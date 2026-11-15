import Foundation
import SQLite3

// 拆分自 SessionHistoryService.swift：Antigravity CLI / 桌面端会话的严格只读解析与 SQLite 辅助。

extension SessionHistoryScanner {
    // MARK: - 2. Antigravity Session Parsing (Strictly Read-Only SQLite + Transcripts)

    nonisolated struct AntigravitySummaryRow {
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

    nonisolated struct AntigravityHistoryEntry {
        var firstPrompt: String?
        var latestPrompt: String?
        var workspace: String?
        var lastTimestamp: Date?
    }

    nonisolated struct AntigravityMetadataItem {
        var summary: String?
        var lastModified: Date?
        var created: Date?
    }

    nonisolated static func scanAntigravity(
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

    nonisolated static func mergeSummaryRow(
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

    nonisolated static func buildAntigravitySignature(
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

    nonisolated static func buildAntigravityRecord(
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

    nonisolated struct AntigravityDBInfo {
        var workspacePath: String?
        var inferredPaths: [String] = []
        var trajectorySource: Int64?
        var parentConversationID: String?
        var createdAt: Date?
    }

    nonisolated static func readAntigravitySummariesDB(
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

    nonisolated static func readAntigravityConversationDB(
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

    nonisolated static func readAntigravityHistoryJSONL(
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

    nonisolated static func readAntigravityMetadataJSON(
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

    nonisolated struct ParsedTranscript {
        var firstPrompt: String?
        var latestPrompt: String?
        var firstAt: Date?
        var lastAt: Date?
        var activeWorkspace: String?
        var candidatePaths: [String] = []
    }

    nonisolated static func parseAntigravityTranscript(
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

    nonisolated struct SQLiteReadError: Error {
        var code: Int32
    }

    /// 严格只读打开 SQLite：绝不传 `SQLITE_OPEN_READWRITE` 或 `SQLITE_OPEN_CREATE`。
    /// 若数据库无 `-wal`/`-shm` 且因目录权限等返回 `SQLITE_CANTOPEN`，降级使用 `immutable=1` URI 只读打开。
    nonisolated static func withReadOnlySQLite(
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

    nonisolated static func openReadOnlySQLite(
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

    nonisolated static func sqliteTables(_ db: OpaquePointer) -> Set<String> {
        var names: Set<String> = []
        sqliteRows(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") { stmt in
            if let name = sqliteText(stmt, 0) { names.insert(name) }
        }
        return names
    }

    nonisolated static func sqliteColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        var cols: Set<String> = []
        sqliteRows(db, sql: "PRAGMA table_info(\(table))") { stmt in
            if let name = sqliteText(stmt, 1) { cols.insert(name) }
        }
        return cols
    }

    nonisolated static func sqliteRows(
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

    nonisolated static func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    nonisolated static func sqliteBlob(_ stmt: OpaquePointer, _ index: Int32) -> [UInt8]? {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        return Array(UnsafeRawBufferPointer(start: ptr, count: count))
    }
}
