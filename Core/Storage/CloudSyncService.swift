import Foundation
import Observation

// MARK: - Natural Day Wire Format ("YYYY-MM-DD")

/// 跨时区安全的自然日编码：导出端写成发送方本地日历的 `YYYY-MM-DD`，导入端还原为接收方本地日历当天 0 点，
/// 保证 `UsageBucket.day` 与 `StatsRange.bounds` 始终对齐到本机自然日 0 点。
nonisolated enum CloudSyncCalendarDay {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func date(from raw: String, calendar: Calendar = .current) -> Date? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]),
              (1970...2200).contains(y),
              (1...12).contains(m),
              (1...31).contains(d)
        else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        guard let built = calendar.date(from: comps) else { return nil }
        return calendar.startOfDay(for: built)
    }
}

// MARK: - Wire Models (Per-Device Single-Writer Shard)

/// 未归属到具体对话档案的按日桶（如早期历史迁移残差）。
nonisolated struct SyncedUsageBucket: Sendable, Codable, Equatable {
    var app: UsageApp
    var model: String
    var speed: UsageSpeed
    var day: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var costUSD: String
    var requestCount: Int
    var hasUnpricedUsage: Bool
    var timing: GenerationTiming?
}

/// 按 `(conversationKey, day, model, speed)` 导出的对话用量桶。
nonisolated struct SyncedConversationUsageBucket: Sendable, Codable, Equatable {
    var conversationKey: String
    var app: UsageApp
    var day: String
    var model: String
    var speed: UsageSpeed
    var firstAt: Date
    var lastAt: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int
    var costUSD: String
    var inputCostUSD: String
    var outputCostUSD: String
    var cacheReadCostUSD: String
    var cacheCreationCostUSD: String
    var hasUnpricedUsage: Bool
    var timing: GenerationTiming?
}

/// 单台设备的导出分片（`<syncDir>/devices/device-<deviceID>.json`）。
///
/// 安全边界：
/// - 每台设备只写自己的分片文件，只读其他设备的分片文件，天然无并发写锁或数据库损坏风险；
/// - 仅导出**纯本机产生**的对话摘要与 Token 账单，绝不把其他设备的分片再次导出（避免环路放大）；
/// - 不含任何 OAuth Token、API Key、邮箱、原始日志文件全文或本机私有源文件路径。
nonisolated struct CCBarDeviceSyncShard: Sendable, Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var deviceID: String
    var deviceName: String
    var exportedAt: Date
    var unattributedDayBuckets: [SyncedUsageBucket]
    var conversationInfos: [ConversationInfo]
    var conversationBuckets: [SyncedConversationUsageBucket]
    var sessionRecords: [SessionHistoryRecord]
}

// MARK: - Peer Status & Merged Overlay

nonisolated struct CloudSyncPeerStatus: Sendable, Equatable, Identifiable {
    var deviceID: String
    var deviceName: String
    var exportedAt: Date
    var conversationCount: Int
    var isDownloadingFromICloud: Bool = false

    var id: String { deviceID }
}

nonisolated struct MergedCloudOverlay: Sendable, Equatable {
    var netUsageBuckets: [UsageBucket]
    var syncedInfos: [ConversationInfo]
    var netConversationBuckets: [ConversationUsageBucket]
    var syncedDeviceNames: [String: String]
    var syncedSessionRecords: [SessionHistoryRecord]

    static let empty = MergedCloudOverlay(
        netUsageBuckets: [],
        syncedInfos: [],
        netConversationBuckets: [],
        syncedDeviceNames: [:],
        syncedSessionRecords: []
    )
}

// MARK: - Pure Export & Deduplicating Merge Engine

nonisolated enum CloudSyncMerger {
    /// 最多随分片导出的最近会话提问摘要条数（Token 账单与 `ConversationInfo` 全量导出不受此限制）。
    static let maxExportedSessionRecords = 2_000

    nonisolated private struct DayBucketKey: Hashable, Sendable {
        var day: String
        var app: UsageApp
        var model: String
        var speed: UsageSpeed
    }

    nonisolated private struct ResolvedDayBucketKey: Hashable, Sendable {
        var day: Date
        var app: UsageApp
        var model: String
        var speed: UsageSpeed
    }

    nonisolated private struct ConvBucketKey: Hashable, Sendable {
        var conversationKey: String
        var day: Date
        var model: String
        var speed: UsageSpeed
    }

    static func normalizedHomePath(_ rawHome: String) -> String {
        let std = URL(fileURLWithPath: rawHome).standardizedFileURL.path
        if std.count > 1 && std.hasSuffix("/") {
            return String(std.dropLast())
        }
        return std
    }

    /// 将本机家目录前缀折算为 `~`，既避免跨机器暴露系统用户名，又支持不同用户名 Mac 之间自动对齐同相对路径项目。
    static func portablePath(_ rawPath: String, homePath: String) -> String {
        guard !rawPath.isEmpty else { return rawPath }
        let home = normalizedHomePath(homePath)
        guard !home.isEmpty, home != "/" else { return rawPath }
        if rawPath == home { return "~" }
        if rawPath.hasPrefix(home + "/") {
            return "~" + String(rawPath.dropFirst(home.count))
        }
        return rawPath
    }

    static func expandPortablePath(_ rawPath: String, homePath: String) -> String {
        guard !rawPath.isEmpty else { return rawPath }
        let home = normalizedHomePath(homePath)
        if rawPath == "~" { return home }
        if rawPath.hasPrefix("~/") {
            return home + String(rawPath.dropFirst(1))
        }
        return rawPath
    }

    /// 从纯本机分区生成当前设备的导出分片。
    static func makeLocalShard(
        deviceID: String,
        deviceName: String,
        exportedAt: Date = Date(),
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        localUsageBuckets: [UsageBucket],
        localConversations: (infos: [ConversationInfo], buckets: [ConversationUsageBucket]),
        localSessionRecords: [SessionHistoryRecord],
        calendar: Calendar = .current
    ) -> CCBarDeviceSyncShard {
        let home = normalizedHomePath(homePath)
        let localInfoKeys = Set(localConversations.infos.lazy.filter { $0.app != .cursor }.map(\.key))

        let exportedInfos: [ConversationInfo] = localConversations.infos
            .filter { $0.app != .cursor }
            .map { info in
                var copy = info
                copy.sourcePaths = []
                if copy.projectStatus.isPathBased, !copy.projectPath.isEmpty {
                    let portable = portablePath(copy.projectPath, homePath: home)
                    copy.projectPath = portable
                    copy.projectKey = "path:\(portable)"
                }
                return copy
            }
            .sorted { $0.key < $1.key }

        var attributedByDayKey: [DayBucketKey: UsageTotals] = [:]
        var exportedConvBuckets: [SyncedConversationUsageBucket] = []
        exportedConvBuckets.reserveCapacity(localConversations.buckets.count)

        for bucket in localConversations.buckets where bucket.app != .cursor && localInfoKeys.contains(bucket.conversationKey) {
            let dayStr = CloudSyncCalendarDay.string(from: bucket.day, calendar: calendar)
            let dayKey = DayBucketKey(day: dayStr, app: bucket.app, model: bucket.model, speed: bucket.speed)
            var attr = attributedByDayKey[dayKey] ?? .zero
            attr.inputTokens += bucket.inputTokens
            attr.outputTokens += bucket.outputTokens
            attr.cacheReadTokens += bucket.cacheReadTokens
            attr.cacheCreationTokens += bucket.cacheCreationTokens
            attr.costUSD += bucket.costUSD
            attr.requestCount += bucket.requestCount
            attr.hasUnpricedUsage = attr.hasUnpricedUsage || bucket.hasUnpricedUsage
            attr.timing.merge(bucket.timing)
            attributedByDayKey[dayKey] = attr

            exportedConvBuckets.append(SyncedConversationUsageBucket(
                conversationKey: bucket.conversationKey,
                app: bucket.app,
                day: dayStr,
                model: bucket.model,
                speed: bucket.speed,
                firstAt: bucket.firstAt,
                lastAt: bucket.lastAt,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                cacheCreationTokens: bucket.cacheCreationTokens,
                requestCount: bucket.requestCount,
                costUSD: bucket.costUSD.asPlainString,
                inputCostUSD: bucket.inputCostUSD.asPlainString,
                outputCostUSD: bucket.outputCostUSD.asPlainString,
                cacheReadCostUSD: bucket.cacheReadCostUSD.asPlainString,
                cacheCreationCostUSD: bucket.cacheCreationCostUSD.asPlainString,
                hasUnpricedUsage: bucket.hasUnpricedUsage,
                timing: bucket.timing.isEmpty ? nil : bucket.timing
            ))
        }

        exportedConvBuckets.sort { lhs, rhs in
            if lhs.conversationKey != rhs.conversationKey { return lhs.conversationKey < rhs.conversationKey }
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.speed.rawValue < rhs.speed.rawValue
        }

        var localByDayKey: [DayBucketKey: UsageTotals] = [:]
        for bucket in localUsageBuckets where bucket.app != .cursor {
            let dayStr = CloudSyncCalendarDay.string(from: bucket.day, calendar: calendar)
            let key = DayBucketKey(day: dayStr, app: bucket.app, model: bucket.model, speed: bucket.speed)
            localByDayKey[key, default: .zero].add(bucket)
        }

        var unattributedDayBuckets: [SyncedUsageBucket] = []
        for (key, localTotal) in localByDayKey {
            let attributed = attributedByDayKey[key] ?? .zero
            let residual = localTotal.clampedSubtracting(attributed)
            guard residual.hasUsage else { continue }
            let residualTiming = subtractTiming(localTotal.timing, attributed.timing)
            unattributedDayBuckets.append(SyncedUsageBucket(
                app: key.app,
                model: key.model,
                speed: key.speed,
                day: key.day,
                inputTokens: residual.inputTokens,
                outputTokens: residual.outputTokens,
                cacheReadTokens: residual.cacheReadTokens,
                cacheCreationTokens: residual.cacheCreationTokens,
                costUSD: residual.costUSD.asPlainString,
                requestCount: residual.requestCount,
                hasUnpricedUsage: residual.hasUnpricedUsage,
                timing: residualTiming.isEmpty ? nil : residualTiming
            ))
        }
        unattributedDayBuckets.sort { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.app != rhs.app { return lhs.app.rawValue < rhs.app.rawValue }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.speed.rawValue < rhs.speed.rawValue
        }

        let exportedSessions: [SessionHistoryRecord] = localSessionRecords
            .lazy
            .filter { !$0.isSubagent && !$0.isRemoteSynced }
            .prefix(Self.maxExportedSessionRecords)
            .map { record in
                var copy = record
                copy.syncedDeviceName = nil
                if let cwd = copy.cwd, !cwd.isEmpty {
                    copy.cwd = portablePath(cwd, homePath: home)
                }
                return copy
            }

        return CCBarDeviceSyncShard(
            schemaVersion: CCBarDeviceSyncShard.currentSchemaVersion,
            deviceID: deviceID,
            deviceName: deviceName,
            exportedAt: exportedAt,
            unattributedDayBuckets: unattributedDayBuckets,
            conversationInfos: exportedInfos,
            conversationBuckets: exportedConvBuckets,
            sessionRecords: exportedSessions
        )
    }

    /// 将其他设备的分片与本机快照做去重残差合并：
    /// - 不同设备的独立对话完整并入；
    /// - 同一 `conversationKey` 若在多台设备重复存在或跨机续聊，按 `(conversationKey, day, model, speed)` 取最大后减去本机已有量，零重复计费；
    /// - 项目路径严格遵守 `ConversationProjectResolver.allowsFileSystemCheck` TCC 边界，不触碰受保护目录。
    static func mergePeers(
        peers: [CCBarDeviceSyncShard],
        localConversations: (infos: [ConversationInfo], buckets: [ConversationUsageBucket]),
        localSessionKeys: Set<String>,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        calendar: Calendar = .current
    ) -> MergedCloudOverlay {
        guard !peers.isEmpty else { return .empty }

        let home = normalizedHomePath(homePath)
        let sortedPeers = peers.sorted { lhs, rhs in
            if lhs.exportedAt == rhs.exportedAt { return lhs.deviceID < rhs.deviceID }
            return lhs.exportedAt > rhs.exportedAt
        }

        let localInfosByKey = Dictionary(uniqueKeysWithValues: localConversations.infos.map { ($0.key, $0) })
        var localConvBucketsByKey: [ConvBucketKey: ConversationUsageBucket] = [:]
        localConvBucketsByKey.reserveCapacity(localConversations.buckets.count)
        for bucket in localConversations.buckets {
            let key = ConvBucketKey(
                conversationKey: bucket.conversationKey,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            if let existing = localConvBucketsByKey[key] {
                localConvBucketsByKey[key] = sumConversationBuckets(existing, bucket)
            } else {
                localConvBucketsByKey[key] = bucket
            }
        }

        var dirExistsCache: [String: Bool] = [:]
        var peerInfosByKey: [String: (info: ConversationInfo, deviceName: String)] = [:]
        var peerMaxConvBuckets: [ConvBucketKey: ConversationUsageBucket] = [:]
        var peerUnattributedByDayKey: [ResolvedDayBucketKey: UsageBucket] = [:]
        var peerSessionsByKey: [String: SessionHistoryRecord] = [:]

        for peer in sortedPeers where peer.schemaVersion >= 1 {
            let cleanDeviceName = peer.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayDeviceName = cleanDeviceName.isEmpty ? "Mac" : cleanDeviceName

            for rawInfo in peer.conversationInfos where rawInfo.app != .cursor {
                let resolved = resolveImportedProject(
                    info: rawInfo,
                    homePath: home,
                    dirExistsCache: &dirExistsCache
                )
                if var existing = peerInfosByKey[resolved.key] {
                    existing.info = mergePeerInfo(primary: existing.info, secondary: resolved)
                    peerInfosByKey[resolved.key] = existing
                } else {
                    peerInfosByKey[resolved.key] = (resolved, displayDeviceName)
                }
            }

            for sb in peer.conversationBuckets where sb.app != .cursor {
                guard let day = CloudSyncCalendarDay.date(from: sb.day, calendar: calendar) else { continue }
                let decoded = ConversationUsageBucket(
                    conversationKey: sb.conversationKey,
                    app: sb.app,
                    day: day,
                    model: sb.model,
                    speed: sb.speed,
                    firstAt: sb.firstAt,
                    lastAt: sb.lastAt,
                    inputTokens: max(0, sb.inputTokens),
                    outputTokens: max(0, sb.outputTokens),
                    cacheReadTokens: max(0, sb.cacheReadTokens),
                    cacheCreationTokens: max(0, sb.cacheCreationTokens),
                    requestCount: max(0, sb.requestCount),
                    costUSD: max(0, Decimal(plainString: sb.costUSD) ?? 0),
                    inputCostUSD: max(0, Decimal(plainString: sb.inputCostUSD) ?? 0),
                    outputCostUSD: max(0, Decimal(plainString: sb.outputCostUSD) ?? 0),
                    cacheReadCostUSD: max(0, Decimal(plainString: sb.cacheReadCostUSD) ?? 0),
                    cacheCreationCostUSD: max(0, Decimal(plainString: sb.cacheCreationCostUSD) ?? 0),
                    hasUnpricedUsage: sb.hasUnpricedUsage,
                    timing: sb.timing ?? .zero
                )
                let key = ConvBucketKey(
                    conversationKey: decoded.conversationKey,
                    day: decoded.day,
                    model: decoded.model,
                    speed: decoded.speed
                )
                if let existing = peerMaxConvBuckets[key] {
                    peerMaxConvBuckets[key] = maxConversationBuckets(existing, decoded)
                } else {
                    peerMaxConvBuckets[key] = decoded
                }
            }

            for ub in peer.unattributedDayBuckets where ub.app != .cursor {
                guard let day = CloudSyncCalendarDay.date(from: ub.day, calendar: calendar) else { continue }
                let bucket = UsageBucket(
                    app: ub.app,
                    model: ub.model,
                    speed: ub.speed,
                    day: day,
                    inputTokens: max(0, ub.inputTokens),
                    outputTokens: max(0, ub.outputTokens),
                    cacheReadTokens: max(0, ub.cacheReadTokens),
                    cacheCreationTokens: max(0, ub.cacheCreationTokens),
                    costUSD: max(0, Decimal(plainString: ub.costUSD) ?? 0),
                    requestCount: max(0, ub.requestCount),
                    hasUnpricedUsage: ub.hasUnpricedUsage,
                    timing: ub.timing ?? .zero
                )
                let key = ResolvedDayBucketKey(day: day, app: ub.app, model: ub.model, speed: ub.speed)
                if var existing = peerUnattributedByDayKey[key] {
                    existing.inputTokens += bucket.inputTokens
                    existing.outputTokens += bucket.outputTokens
                    existing.cacheReadTokens += bucket.cacheReadTokens
                    existing.cacheCreationTokens += bucket.cacheCreationTokens
                    existing.costUSD += bucket.costUSD
                    existing.requestCount += bucket.requestCount
                    existing.hasUnpricedUsage = existing.hasUnpricedUsage || bucket.hasUnpricedUsage
                    existing.timing.merge(bucket.timing)
                    peerUnattributedByDayKey[key] = existing
                } else {
                    peerUnattributedByDayKey[key] = bucket
                }
            }

            for rawRecord in peer.sessionRecords where !rawRecord.isSubagent {
                guard !localSessionKeys.contains(rawRecord.key) else { continue }
                var imported = rawRecord
                imported.syncedDeviceName = displayDeviceName
                if let cwd = imported.cwd, !cwd.isEmpty {
                    let expanded = expandPortablePath(cwd, homePath: home)
                    imported.cwd = URL(fileURLWithPath: expanded).standardizedFileURL.path
                }
                if let existing = peerSessionsByKey[imported.key] {
                    if imported.lastActiveAt > existing.lastActiveAt {
                        peerSessionsByKey[imported.key] = imported
                    }
                } else {
                    peerSessionsByKey[imported.key] = imported
                }
            }
        }

        var netConversationBuckets: [ConversationUsageBucket] = []
        var keysWithNetUsage = Set<String>()
        for (key, peerBucket) in peerMaxConvBuckets {
            // 仅合入有对话档案的桶，保证统计页「概览总量 − 已归属 = 未归属」恒成立。
            guard peerInfosByKey[key.conversationKey] != nil || localInfosByKey[key.conversationKey] != nil else {
                continue
            }
            let netBucket: ConversationUsageBucket?
            if let localBucket = localConvBucketsByKey[key] {
                netBucket = subtractConversationBucket(peerBucket, localBucket)
            } else {
                netBucket = conversationBucketHasUsage(peerBucket) ? peerBucket : nil
            }
            if let netBucket {
                netConversationBuckets.append(netBucket)
                keysWithNetUsage.insert(key.conversationKey)
            }
        }

        // 将子任务/续接链祖先档案一并保留，保证 ConversationAggregator.subtaskGrouping 能正常归根。
        var neededInfoKeys = keysWithNetUsage
        for key in keysWithNetUsage {
            var cursor = key
            var visited: Set<String> = [cursor]
            while let entry = peerInfosByKey[cursor] {
                guard let next = entry.info.parentKey ?? entry.info.continuationKey,
                      visited.insert(next).inserted
                else { break }
                neededInfoKeys.insert(next)
                cursor = next
            }
        }

        var syncedInfos: [ConversationInfo] = []
        var syncedDeviceNames: [String: String] = [:]
        for key in neededInfoKeys {
            guard let entry = peerInfosByKey[key] else { continue }
            syncedInfos.append(entry.info)
            if localInfosByKey[key] == nil {
                syncedDeviceNames[key] = entry.deviceName
            }
        }
        // 对于仅在远端存在会话记录（如 0 token 新建会话）的情况，也登记其设备归属供 UI 展示。
        for (sessionKey, record) in peerSessionsByKey where localInfosByKey[sessionKey] == nil {
            if syncedDeviceNames[sessionKey] == nil, let deviceName = record.syncedDeviceName {
                syncedDeviceNames[sessionKey] = deviceName
            }
        }

        var mergedDayBuckets = peerUnattributedByDayKey
        for bucket in netConversationBuckets {
            let key = ResolvedDayBucketKey(
                day: bucket.day,
                app: bucket.app,
                model: bucket.model,
                speed: bucket.speed
            )
            if var existing = mergedDayBuckets[key] {
                existing.inputTokens += bucket.inputTokens
                existing.outputTokens += bucket.outputTokens
                existing.cacheReadTokens += bucket.cacheReadTokens
                existing.cacheCreationTokens += bucket.cacheCreationTokens
                existing.costUSD += bucket.costUSD
                existing.requestCount += bucket.requestCount
                existing.hasUnpricedUsage = existing.hasUnpricedUsage || bucket.hasUnpricedUsage
                existing.timing.merge(bucket.timing)
                mergedDayBuckets[key] = existing
            } else {
                mergedDayBuckets[key] = UsageBucket(
                    app: bucket.app,
                    model: bucket.model,
                    speed: bucket.speed,
                    day: bucket.day,
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    cacheCreationTokens: bucket.cacheCreationTokens,
                    costUSD: bucket.costUSD,
                    requestCount: bucket.requestCount,
                    hasUnpricedUsage: bucket.hasUnpricedUsage,
                    timing: bucket.timing
                )
            }
        }

        let sortedSessions = peerSessionsByKey.values.sorted { lhs, rhs in
            if lhs.lastActiveAt == rhs.lastActiveAt { return lhs.key < rhs.key }
            return lhs.lastActiveAt > rhs.lastActiveAt
        }

        return MergedCloudOverlay(
            netUsageBuckets: Array(mergedDayBuckets.values),
            syncedInfos: syncedInfos,
            netConversationBuckets: netConversationBuckets,
            syncedDeviceNames: syncedDeviceNames,
            syncedSessionRecords: sortedSessions
        )
    }

    // MARK: - Internal Helpers

    private static func resolveImportedProject(
        info: ConversationInfo,
        homePath: String,
        dirExistsCache: inout [String: Bool]
    ) -> ConversationInfo {
        var copy = info
        copy.sourcePaths = []
        guard copy.projectStatus.isPathBased, !copy.projectPath.isEmpty else { return copy }
        let expanded = expandPortablePath(copy.projectPath, homePath: homePath)
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        copy.projectPath = standardized
        copy.projectKey = "path:\(standardized)"
        let folderName = URL(fileURLWithPath: standardized).lastPathComponent
        if !folderName.isEmpty { copy.projectName = folderName }

        if ConversationProjectResolver.allowsFileSystemCheck(standardizedPath: standardized, home: homePath) {
            let exists: Bool
            if let cached = dirExistsCache[standardized] {
                exists = cached
            } else {
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir) && isDir.boolValue
                dirExistsCache[standardized] = ok
                exists = ok
            }
            copy.projectStatus = exists ? .available : .unverified
        } else {
            copy.projectStatus = .unverified
        }
        return copy
    }

    private static func mergePeerInfo(primary: ConversationInfo, secondary: ConversationInfo) -> ConversationInfo {
        var result = primary
        if (result.title ?? "").isEmpty, let title = secondary.title, !title.isEmpty {
            result.title = title
        } else if secondary.lastAt > result.lastAt, let title = secondary.title, !title.isEmpty {
            result.title = title
        }
        if result.projectStatus != .available && secondary.projectStatus == .available {
            result.projectKey = secondary.projectKey
            result.projectName = secondary.projectName
            result.projectPath = secondary.projectPath
            result.projectStatus = secondary.projectStatus
            result.projectSource = secondary.projectSource
        }
        if result.gitBranch == nil { result.gitBranch = secondary.gitBranch }
        if result.parentKey == nil { result.parentKey = secondary.parentKey }
        if result.continuationKey == nil { result.continuationKey = secondary.continuationKey }
        result.firstAt = min(result.firstAt, secondary.firstAt)
        result.lastAt = max(result.lastAt, secondary.lastAt)
        result.includesSubtasks = result.includesSubtasks || secondary.includesSubtasks
        result.cacheCreationAvailable = result.cacheCreationAvailable || secondary.cacheCreationAvailable
        return result
    }

    private static func conversationBucketHasUsage(_ bucket: ConversationUsageBucket) -> Bool {
        bucket.inputTokens > 0
            || bucket.outputTokens > 0
            || bucket.cacheReadTokens > 0
            || bucket.cacheCreationTokens > 0
            || bucket.costUSD > 0
            || bucket.requestCount > 0
    }

    private static func sumConversationBuckets(
        _ lhs: ConversationUsageBucket,
        _ rhs: ConversationUsageBucket
    ) -> ConversationUsageBucket {
        var copy = lhs
        copy.firstAt = min(lhs.firstAt, rhs.firstAt)
        copy.lastAt = max(lhs.lastAt, rhs.lastAt)
        copy.inputTokens += rhs.inputTokens
        copy.outputTokens += rhs.outputTokens
        copy.cacheReadTokens += rhs.cacheReadTokens
        copy.cacheCreationTokens += rhs.cacheCreationTokens
        copy.requestCount += rhs.requestCount
        copy.costUSD += rhs.costUSD
        copy.inputCostUSD += rhs.inputCostUSD
        copy.outputCostUSD += rhs.outputCostUSD
        copy.cacheReadCostUSD += rhs.cacheReadCostUSD
        copy.cacheCreationCostUSD += rhs.cacheCreationCostUSD
        copy.hasUnpricedUsage = lhs.hasUnpricedUsage || rhs.hasUnpricedUsage
        copy.timing.merge(rhs.timing)
        return copy
    }

    private static func maxConversationBuckets(
        _ lhs: ConversationUsageBucket,
        _ rhs: ConversationUsageBucket
    ) -> ConversationUsageBucket {
        var copy = lhs
        copy.firstAt = min(lhs.firstAt, rhs.firstAt)
        copy.lastAt = max(lhs.lastAt, rhs.lastAt)
        copy.inputTokens = max(lhs.inputTokens, rhs.inputTokens)
        copy.outputTokens = max(lhs.outputTokens, rhs.outputTokens)
        copy.cacheReadTokens = max(lhs.cacheReadTokens, rhs.cacheReadTokens)
        copy.cacheCreationTokens = max(lhs.cacheCreationTokens, rhs.cacheCreationTokens)
        copy.requestCount = max(lhs.requestCount, rhs.requestCount)
        copy.costUSD = max(lhs.costUSD, rhs.costUSD)
        copy.inputCostUSD = max(lhs.inputCostUSD, rhs.inputCostUSD)
        copy.outputCostUSD = max(lhs.outputCostUSD, rhs.outputCostUSD)
        copy.cacheReadCostUSD = max(lhs.cacheReadCostUSD, rhs.cacheReadCostUSD)
        copy.cacheCreationCostUSD = max(lhs.cacheCreationCostUSD, rhs.cacheCreationCostUSD)
        copy.hasUnpricedUsage = lhs.hasUnpricedUsage || rhs.hasUnpricedUsage
        copy.timing = GenerationTiming(
            firstTokenCount: max(lhs.timing.firstTokenCount, rhs.timing.firstTokenCount),
            firstTokenMs: max(lhs.timing.firstTokenMs, rhs.timing.firstTokenMs),
            timedOutputTokens: max(lhs.timing.timedOutputTokens, rhs.timing.timedOutputTokens),
            generationMs: max(lhs.timing.generationMs, rhs.timing.generationMs),
            estimatedOutputTokens: max(lhs.timing.estimatedOutputTokens, rhs.timing.estimatedOutputTokens),
            estimatedGenerationMs: max(lhs.timing.estimatedGenerationMs, rhs.timing.estimatedGenerationMs)
        )
        return copy
    }

    private static func subtractConversationBucket(
        _ peer: ConversationUsageBucket,
        _ local: ConversationUsageBucket
    ) -> ConversationUsageBucket? {
        let inputTokens = max(0, peer.inputTokens - local.inputTokens)
        let outputTokens = max(0, peer.outputTokens - local.outputTokens)
        let cacheReadTokens = max(0, peer.cacheReadTokens - local.cacheReadTokens)
        let cacheCreationTokens = max(0, peer.cacheCreationTokens - local.cacheCreationTokens)
        let requestCount = max(0, peer.requestCount - local.requestCount)
        let costUSD = max(Decimal.zero, peer.costUSD - local.costUSD)
        let inputCostUSD = max(Decimal.zero, peer.inputCostUSD - local.inputCostUSD)
        let outputCostUSD = max(Decimal.zero, peer.outputCostUSD - local.outputCostUSD)
        let cacheReadCostUSD = max(Decimal.zero, peer.cacheReadCostUSD - local.cacheReadCostUSD)
        let cacheCreationCostUSD = max(Decimal.zero, peer.cacheCreationCostUSD - local.cacheCreationCostUSD)

        guard inputTokens > 0
            || outputTokens > 0
            || cacheReadTokens > 0
            || cacheCreationTokens > 0
            || costUSD > 0
            || requestCount > 0
        else { return nil }

        return ConversationUsageBucket(
            conversationKey: peer.conversationKey,
            app: peer.app,
            day: peer.day,
            model: peer.model,
            speed: peer.speed,
            firstAt: peer.firstAt,
            lastAt: peer.lastAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            requestCount: requestCount,
            costUSD: costUSD,
            inputCostUSD: inputCostUSD,
            outputCostUSD: outputCostUSD,
            cacheReadCostUSD: cacheReadCostUSD,
            cacheCreationCostUSD: cacheCreationCostUSD,
            hasUnpricedUsage: peer.hasUnpricedUsage,
            timing: subtractTiming(peer.timing, local.timing)
        )
    }

    private static func subtractTiming(_ lhs: GenerationTiming, _ rhs: GenerationTiming) -> GenerationTiming {
        GenerationTiming(
            firstTokenCount: max(0, lhs.firstTokenCount - rhs.firstTokenCount),
            firstTokenMs: max(0, lhs.firstTokenMs - rhs.firstTokenMs),
            timedOutputTokens: max(0, lhs.timedOutputTokens - rhs.timedOutputTokens),
            generationMs: max(0, lhs.generationMs - rhs.generationMs),
            estimatedOutputTokens: max(0, lhs.estimatedOutputTokens - rhs.estimatedOutputTokens),
            estimatedGenerationMs: max(0, lhs.estimatedGenerationMs - rhs.estimatedGenerationMs)
        )
    }
}

// MARK: - CloudSyncService (@MainActor Coordinator)

@Observable
@MainActor
final class CloudSyncService {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var peerStatuses: [CloudSyncPeerStatus] = []

    nonisolated private struct PeerFileStamp: Equatable, Sendable {
        var size: Int64
        var mtime: Double
    }

    nonisolated private struct CachedPeerShard: Equatable, Sendable {
        var stamp: PeerFileStamp
        var shard: CCBarDeviceSyncShard
    }

    nonisolated private struct PeerScanOutput: Sendable {
        var peersByDeviceID: [String: CachedPeerShard]
        var downloadingDeviceIDs: Set<String>
        var readError: String?
    }

    private struct ExportSignature: Equatable {
        var syncDirectoryPath: String
        var deviceName: String
        var localUsageRevision: UInt64
        var localConversationRevision: UInt64
        var localSessionRevision: UInt64
    }

    private struct MergeSignature: Equatable {
        var localUsageRevision: UInt64
        var localConversationRevision: UInt64
        var localSessionRevision: UInt64
    }

    @ObservationIgnored private let injectedSettings: SettingsStore?
    @ObservationIgnored private var cachedPeersByDeviceID: [String: CachedPeerShard] = [:]
    @ObservationIgnored private var cachedSyncDirectoryPath: String?
    @ObservationIgnored private var lastExportedAt: Date?
    @ObservationIgnored private var lastExportSignature: ExportSignature?
    @ObservationIgnored private var lastMergeSignature: MergeSignature?

    private var settings: SettingsStore { injectedSettings ?? .shared }

    init(settings: SettingsStore? = nil) {
        self.injectedSettings = settings
    }

    /// 定时轮询写盘节流：内容未变不写；内容变化后至少间隔 90 秒才重写本机分片，减少 iCloud / 网盘上传频次。
    private static let periodicExportInterval: TimeInterval = 90

    nonisolated static func devicesDirectoryURL(in rootURL: URL) -> URL {
        rootURL.appendingPathComponent("devices", isDirectory: true)
    }

    nonisolated static func shardFileURL(in rootURL: URL, deviceID: String) -> URL {
        let safeID = sanitizeDeviceID(deviceID)
        return devicesDirectoryURL(in: rootURL).appendingPathComponent("device-\(safeID).json", isDirectory: false)
    }

    nonisolated private static func sanitizeDeviceID(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = raw.unicodeScalars.filter { allowed.contains($0) }
        let str = String(String.UnicodeScalarView(filtered))
        return str.isEmpty ? "unknown" : str
    }

    /// 冷启动快速载入其他设备已同步到本地的分片，让界面首屏即包含跨设备数据；不在此刻写本机分片。
    func loadPeerShardsOnStartup(appState: AppState) async {
        let settings = self.settings
        guard settings.cloudSyncEnabled else { return }
        guard let rootURL = settings.resolvedCloudSyncDirectoryURL else {
            lastError = tr("Select a sync folder to start syncing.", "请选择同步文件夹以开始同步。")
            return
        }
        await performSync(appState: appState, rootURL: rootURL, exportMode: .none)
    }

    /// Scheduler 周期同步入口。
    func syncPeriodically(appState: AppState) async {
        let settings = self.settings
        guard settings.cloudSyncEnabled else {
            disableAndClearOverlay(appState: appState)
            return
        }
        guard let rootURL = settings.resolvedCloudSyncDirectoryURL else {
            lastError = tr("Select a sync folder to start syncing.", "请选择同步文件夹以开始同步。")
            return
        }
        await performSync(appState: appState, rootURL: rootURL, exportMode: .throttled)
    }

    /// 用户手动点击「立即同步」、首次打开开关或切换目录时调用。
    func syncNow(appState: AppState) async {
        let settings = self.settings
        guard settings.cloudSyncEnabled else {
            disableAndClearOverlay(appState: appState)
            return
        }
        guard let rootURL = settings.resolvedCloudSyncDirectoryURL else {
            lastError = tr("Select a sync folder to start syncing.", "请选择同步文件夹以开始同步。")
            return
        }
        await performSync(appState: appState, rootURL: rootURL, exportMode: .immediate)
    }

    /// 退出前若本机分片有未导出的新用量，尽力做一次原子落盘；任何异常都不阻断退出。
    func flushForTermination(appState: AppState) async {
        let settings = self.settings
        guard settings.cloudSyncEnabled,
              let rootURL = settings.resolvedCloudSyncDirectoryURL
        else { return }
        let signature = currentExportSignature(appState: appState, rootURL: rootURL, settings: settings)
        guard signature != lastExportSignature else { return }

        let deviceID = settings.cloudSyncDeviceID
        let deviceName = settings.effectiveCloudSyncDeviceName
        let localUsage = appState.usageService.aggregator.snapshotLocal()
        let localConversations = appState.usageService.conversationAggregator.snapshot()
        let localSessions = appState.sessionHistory.localRecords

        let ok = await Task.detached(priority: .utility) { () -> Bool in
            let shard = CloudSyncMerger.makeLocalShard(
                deviceID: deviceID,
                deviceName: deviceName,
                localUsageBuckets: localUsage,
                localConversations: localConversations,
                localSessionRecords: localSessions
            )
            return (try? Self.writeLocalShard(shard, rootURL: rootURL)) != nil
        }.value

        if ok {
            lastExportSignature = signature
            lastExportedAt = Date()
        }
    }

    /// 关闭云同步时清空内存中的跨设备叠加层；本机历史与网盘已有分片均原样保留。
    func disableAndClearOverlay(appState: AppState) {
        let hadOverlay = !cachedPeersByDeviceID.isEmpty || !peerStatuses.isEmpty || lastError != nil
        cachedPeersByDeviceID.removeAll()
        cachedSyncDirectoryPath = nil
        peerStatuses = []
        lastError = nil
        lastMergeSignature = nil
        appState.usageService.aggregator.replaceSynced(buckets: [])
        appState.usageService.conversationAggregator.replaceSynced(infos: [], buckets: [], deviceNames: [:])
        appState.sessionHistory.replaceSyncedRecords([])
        if hadOverlay {
            appState.usageService.refreshPublishedTotals()
        }
    }

    /// 从同步目录移除某台已停用旧设备的分片文件，并立刻刷新合并视图。
    func removePeerShard(deviceID: String, appState: AppState) async {
        guard let rootURL = self.settings.resolvedCloudSyncDirectoryURL else { return }
        let fileURL = Self.shardFileURL(in: rootURL, deviceID: deviceID)
        _ = await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: fileURL)
        }.value
        cachedPeersByDeviceID.removeValue(forKey: deviceID)
        lastMergeSignature = nil
        recomputeMergedOverlayIfNeeded(appState: appState, force: true, publishTotals: true)
        rebuildPeerStatuses(downloadingDeviceIDs: [])
    }

    /// 当本机扫描新增了某段跨机共有对话的 Token 时，零磁盘 I/O 即时重算去重残差，避免本机+远端短暂重复计费。
    func recomputeMergedOverlayIfNeeded(
        appState: AppState,
        force: Bool = false,
        publishTotals: Bool = true
    ) {
        guard self.settings.cloudSyncEnabled else { return }
        guard !cachedPeersByDeviceID.isEmpty else {
            appState.usageService.aggregator.replaceSynced(buckets: [])
            appState.usageService.conversationAggregator.replaceSynced(infos: [], buckets: [], deviceNames: [:])
            appState.sessionHistory.replaceSyncedRecords([])
            return
        }

        let currentSig = MergeSignature(
            localUsageRevision: appState.usageService.aggregator.localRevision,
            localConversationRevision: appState.usageService.conversationAggregator.localRevision,
            localSessionRevision: appState.sessionHistory.localRevision
        )
        guard force || currentSig != lastMergeSignature else { return }
        lastMergeSignature = currentSig

        let peers = cachedPeersByDeviceID.values.map(\.shard)
        let localConversations = appState.usageService.conversationAggregator.snapshot()
        let localSessionKeys = Set(appState.sessionHistory.localRecords.map(\.key))
        let overlay = CloudSyncMerger.mergePeers(
            peers: peers,
            localConversations: localConversations,
            localSessionKeys: localSessionKeys
        )

        appState.usageService.aggregator.replaceSynced(buckets: overlay.netUsageBuckets)
        appState.usageService.conversationAggregator.replaceSynced(
            infos: overlay.syncedInfos,
            buckets: overlay.netConversationBuckets,
            deviceNames: overlay.syncedDeviceNames
        )
        appState.sessionHistory.replaceSyncedRecords(overlay.syncedSessionRecords)
        if publishTotals {
            appState.usageService.refreshPublishedTotals()
        }
    }

    // MARK: - Private Sync Pipeline

    private enum ExportMode {
        case none
        case throttled
        case immediate
    }

    private func performSync(
        appState: AppState,
        rootURL: URL,
        exportMode: ExportMode
    ) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let settings = self.settings
        if settings.cloudSyncDirectoryMode == .icloudDrive && !SettingsStore.isICloudDriveAvailable {
            lastError = tr(
                "iCloud Drive is not available on this Mac. Enable iCloud Drive or choose a custom sync folder.",
                "当前 Mac 未开启 iCloud Drive，请在系统设置中启用 iCloud 云盘，或改选自定义同步目录。"
            )
            return
        }

        let rootPath = rootURL.standardizedFileURL.path
        if cachedSyncDirectoryPath != rootPath {
            cachedPeersByDeviceID.removeAll()
            cachedSyncDirectoryPath = rootPath
            lastExportSignature = nil
            lastMergeSignature = nil
        }

        let exportSignature = currentExportSignature(appState: appState, rootURL: rootURL, settings: settings)
        let now = Date()
        let shouldExport: Bool
        switch exportMode {
        case .none:
            shouldExport = false
        case .immediate:
            shouldExport = true
        case .throttled:
            if exportSignature != lastExportSignature {
                if let lastExportedAt {
                    shouldExport = now.timeIntervalSince(lastExportedAt) >= Self.periodicExportInterval
                } else {
                    shouldExport = true
                }
            } else {
                shouldExport = false
            }
        }

        let deviceID = settings.cloudSyncDeviceID
        let deviceName = settings.effectiveCloudSyncDeviceName
        let previousCache = cachedPeersByDeviceID

        let localInputs: (
            usage: [UsageBucket],
            conversations: (infos: [ConversationInfo], buckets: [ConversationUsageBucket]),
            sessions: [SessionHistoryRecord]
        )? = shouldExport ? (
            appState.usageService.aggregator.snapshotLocal(),
            appState.usageService.conversationAggregator.snapshot(),
            appState.sessionHistory.localRecords
        ) : nil

        let ioResult = await Task.detached(priority: .utility) { () -> (wroteShard: Bool, writeError: String?, peerScan: PeerScanOutput) in
            var wrote = false
            var writeErr: String?
            if let localInputs {
                do {
                    let shard = CloudSyncMerger.makeLocalShard(
                        deviceID: deviceID,
                        deviceName: deviceName,
                        exportedAt: now,
                        localUsageBuckets: localInputs.usage,
                        localConversations: localInputs.conversations,
                        localSessionRecords: localInputs.sessions
                    )
                    try Self.writeLocalShard(shard, rootURL: rootURL)
                    wrote = true
                } catch {
                    writeErr = error.localizedDescription
                }
            }
            let scanned = Self.scanPeerDirectory(
                rootURL: rootURL,
                localDeviceID: deviceID,
                previousCache: previousCache
            )
            return (wrote, writeErr, scanned)
        }.value

        if ioResult.wroteShard {
            lastExportSignature = exportSignature
            lastExportedAt = now
        }

        let peersChanged = ioResult.peerScan.peersByDeviceID != cachedPeersByDeviceID
        cachedPeersByDeviceID = ioResult.peerScan.peersByDeviceID
        rebuildPeerStatuses(downloadingDeviceIDs: ioResult.peerScan.downloadingDeviceIDs)

        if let writeError = ioResult.writeError {
            lastError = writeError
            AppLog.warn(.persistence, "cloud sync write failed: \(Redact.message(writeError))")
        } else if let readError = ioResult.peerScan.readError {
            lastError = readError
            AppLog.warn(.persistence, "cloud sync read failed: \(Redact.message(readError))")
        } else {
            lastError = nil
            lastSyncedAt = now
        }

        recomputeMergedOverlayIfNeeded(
            appState: appState,
            force: peersChanged,
            publishTotals: true
        )
    }

    private func currentExportSignature(
        appState: AppState,
        rootURL: URL,
        settings: SettingsStore
    ) -> ExportSignature {
        ExportSignature(
            syncDirectoryPath: rootURL.standardizedFileURL.path,
            deviceName: settings.effectiveCloudSyncDeviceName,
            localUsageRevision: appState.usageService.aggregator.localRevision,
            localConversationRevision: appState.usageService.conversationAggregator.localRevision,
            localSessionRevision: appState.sessionHistory.localRevision
        )
    }

    private func rebuildPeerStatuses(downloadingDeviceIDs: Set<String>) {
        var statuses: [CloudSyncPeerStatus] = cachedPeersByDeviceID.values.map { entry in
            CloudSyncPeerStatus(
                deviceID: entry.shard.deviceID,
                deviceName: entry.shard.deviceName,
                exportedAt: entry.shard.exportedAt,
                conversationCount: entry.shard.conversationInfos.count,
                isDownloadingFromICloud: downloadingDeviceIDs.contains(entry.shard.deviceID)
            )
        }
        for downloadingID in downloadingDeviceIDs where cachedPeersByDeviceID[downloadingID] == nil {
            statuses.append(CloudSyncPeerStatus(
                deviceID: downloadingID,
                deviceName: String(downloadingID.prefix(8)),
                exportedAt: .distantPast,
                conversationCount: 0,
                isDownloadingFromICloud: true
            ))
        }
        statuses.sort { lhs, rhs in
            if lhs.exportedAt == rhs.exportedAt { return lhs.deviceName < rhs.deviceName }
            return lhs.exportedAt > rhs.exportedAt
        }
        peerStatuses = statuses
    }

    nonisolated private static func writeLocalShard(
        _ shard: CCBarDeviceSyncShard,
        rootURL: URL
    ) throws {
        let devicesDir = devicesDirectoryURL(in: rootURL)
        try FileManager.default.createDirectory(at: devicesDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(shard)
        let targetURL = shardFileURL(in: rootURL, deviceID: shard.deviceID)
        try data.write(to: targetURL, options: .atomic)
    }

    nonisolated private static func scanPeerDirectory(
        rootURL: URL,
        localDeviceID: String,
        previousCache: [String: CachedPeerShard]
    ) -> PeerScanOutput {
        let fm = FileManager.default
        let devicesDir = devicesDirectoryURL(in: rootURL)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: devicesDir.path, isDirectory: &isDir), isDir.boolValue else {
            return PeerScanOutput(peersByDeviceID: [:], downloadingDeviceIDs: [], readError: nil)
        }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: devicesDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: []
            )
        } catch {
            return PeerScanOutput(
                peersByDeviceID: previousCache,
                downloadingDeviceIDs: [],
                readError: error.localizedDescription
            )
        }

        let safeLocalID = sanitizeDeviceID(localDeviceID)
        let decoder = JSONDecoder()
        var nextPeers: [String: CachedPeerShard] = [:]
        var downloadingIDs = Set<String>()

        for url in urls {
            let name = url.lastPathComponent
            // iCloud Drive 开启「优化 Mac 储存空间」时的未下载占位文件：请求后台拉取并保留上次内存快照。
            if name.hasPrefix(".device-"), name.hasSuffix(".json.icloud") {
                let fileID = String(name.dropFirst(".device-".count).dropLast(".json.icloud".count))
                guard !fileID.isEmpty, fileID != safeLocalID, fileID != localDeviceID else { continue }
                try? fm.startDownloadingUbiquitousItem(at: url)
                downloadingIDs.insert(fileID)
                if let cached = previousCache[fileID] {
                    nextPeers[fileID] = cached
                }
                continue
            }

            guard name.hasPrefix("device-"), name.hasSuffix(".json") else { continue }
            let fileID = String(name.dropFirst("device-".count).dropLast(".json".count))
            guard !fileID.isEmpty, fileID != safeLocalID, fileID != localDeviceID else { continue }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stamp = PeerFileStamp(
                size: Int64(values?.fileSize ?? 0),
                mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            )

            if let cached = previousCache[fileID], cached.stamp == stamp {
                nextPeers[fileID] = cached
                continue
            }

            if let data = try? Data(contentsOf: url),
               let decoded = try? decoder.decode(CCBarDeviceSyncShard.self, from: data),
               decoded.deviceID != localDeviceID {
                nextPeers[decoded.deviceID] = CachedPeerShard(stamp: stamp, shard: decoded)
            } else if let cached = previousCache[fileID] {
                // 网盘同步中途读失败时保留上一份可用内存分片，不清空已显示的远端数据。
                nextPeers[fileID] = cached
            }
        }

        return PeerScanOutput(
            peersByDeviceID: nextPeers,
            downloadingDeviceIDs: downloadingIDs,
            readError: nil
        )
    }
}
