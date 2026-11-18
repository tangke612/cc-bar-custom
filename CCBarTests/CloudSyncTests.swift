import XCTest
@testable import CCBar

@MainActor
final class CloudSyncTests: XCTestCase {
    private let calendar = Calendar.current
    private var tempDir: URL!
    private var suiteName: String!
    private var suiteDefaults: UserDefaults!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDir = tempDir.resolvingSymlinksInPath()

        suiteName = "com.nanvon.ccbar.tests.cloudsync.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - 1. Disjoint Multi-Device Merge & Pure Local Persistence Invariant

    func testDisjointDevicesMergeSummariesAndTokenBillingPreservingLocalSnapshot() throws {
        let targetDay = day(2026, 11, 18)
        let macAHome = "/Users/alice"
        let macBHome = tempDir.appendingPathComponent("bob-home", isDirectory: true)
        let macBProject = macBHome.appendingPathComponent("code/ccbar", isDirectory: true)
        try FileManager.default.createDirectory(at: macBProject, withIntermediateDirectories: true)

        // Mac B data (exported from /Users/alice/code/ccbar)
        let macBConvKey = "claude:conv-mac-b"
        let macBInfo = makeInfo(
            key: macBConvKey,
            id: "conv-mac-b",
            app: .claude,
            title: "多设备同步设计",
            projectPath: "/Users/alice/code/ccbar",
            sourcePaths: ["/Users/alice/.claude/projects/secret.jsonl"],
            at: targetDay.addingTimeInterval(3600)
        )
        let macBConvBucket = makeConvBucket(
            key: macBConvKey,
            app: .claude,
            day: targetDay,
            model: "claude-sonnet-4-5",
            input: 2_000,
            output: 800,
            cost: Decimal(string: "4.00")!,
            requests: 3,
            at: targetDay.addingTimeInterval(3600)
        )
        // Mac B total day bucket includes 300 unattributed legacy tokens ($0.30)
        let macBDayBucket = UsageBucket(
            app: .claude,
            model: "claude-sonnet-4-5",
            speed: .standard,
            day: targetDay,
            inputTokens: 2_300,
            outputTokens: 800,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: Decimal(string: "4.30")!,
            requestCount: 4,
            hasUnpricedUsage: false
        )
        let macBSession = SessionHistoryRecord(
            key: macBConvKey,
            sessionID: "conv-mac-b",
            origin: .claudeCode,
            cwd: "/Users/alice/code/ccbar",
            projectName: "ccbar",
            lastActiveAt: targetDay.addingTimeInterval(3600),
            createdAt: targetDay.addingTimeInterval(1800),
            title: "多设备同步设计",
            summary: "按方案 1 实现单写多读分片",
            firstPrompt: "这个conversations能不能通过云端同步？",
            latestPrompt: "按方案1,同步对话列表摘要和token账单。",
            isSubagent: false,
            permission: nil,
            gitBranch: "custom"
        )

        let macBShard = CloudSyncMerger.makeLocalShard(
            deviceID: "device-mac-b",
            deviceName: "Studio Mac",
            exportedAt: targetDay.addingTimeInterval(4000),
            homePath: macAHome,
            localUsageBuckets: [macBDayBucket],
            localConversations: (infos: [macBInfo], buckets: [macBConvBucket]),
            localSessionRecords: [macBSession],
            calendar: calendar
        )

        // Verify privacy & residual invariants on exported wire shard
        XCTAssertEqual(macBShard.conversationInfos.first?.sourcePaths, [], "Export must strip local log paths")
        XCTAssertEqual(macBShard.conversationInfos.first?.projectPath, "~/code/ccbar", "Home prefix must be portable ~")
        XCTAssertEqual(macBShard.sessionRecords.first?.cwd, "~/code/ccbar")
        XCTAssertEqual(macBShard.unattributedDayBuckets.count, 1)
        XCTAssertEqual(macBShard.unattributedDayBuckets.first?.inputTokens, 300)
        XCTAssertEqual(macBShard.unattributedDayBuckets.first?.costUSD, "0.3")

        // Mac A (local receiver running at macBHome)
        let localConvKey = "codex:conv-local-a"
        let localInfo = makeInfo(
            key: localConvKey,
            id: "conv-local-a",
            app: .codex,
            title: "本地悬停弹窗优化",
            projectPath: macBProject.path,
            sourcePaths: ["/tmp/rollout.jsonl"],
            at: targetDay.addingTimeInterval(1200)
        )
        let localConvBucket = makeConvBucket(
            key: localConvKey,
            app: .codex,
            day: targetDay,
            model: "gpt-5",
            input: 1_000,
            output: 500,
            cost: Decimal(string: "1.50")!,
            requests: 2,
            at: targetDay.addingTimeInterval(1200)
        )
        let localDayBucket = UsageBucket(
            app: .codex,
            model: "gpt-5",
            speed: .standard,
            day: targetDay,
            inputTokens: 1_200,
            outputTokens: 500,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: Decimal(string: "1.70")!,
            requestCount: 3,
            hasUnpricedUsage: false
        )

        let usageAgg = UsageAggregator()
        usageAgg.load(from: [localDayBucket])

        let convAgg = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: macBHome.path))
        convAgg.load(infos: [localInfo], buckets: [localConvBucket])

        let overlay = CloudSyncMerger.mergePeers(
            peers: [macBShard],
            localConversations: convAgg.snapshot(),
            localSessionKeys: [],
            homePath: macBHome.path,
            calendar: calendar
        )

        usageAgg.replaceSynced(buckets: overlay.netUsageBuckets)
        convAgg.replaceSynced(
            infos: overlay.syncedInfos,
            buckets: overlay.netConversationBuckets,
            deviceNames: overlay.syncedDeviceNames
        )

        // 1) Pure local persistence snapshots MUST remain untouched
        XCTAssertEqual(usageAgg.snapshotLocal().count, 1)
        XCTAssertEqual(usageAgg.snapshotLocal().first?.app, .codex)
        XCTAssertEqual(convAgg.snapshot().infos.map(\.key), [localConvKey])
        XCTAssertEqual(convAgg.snapshot().buckets.map(\.conversationKey), [localConvKey])

        // 2) Display totals include both local and synced billing
        let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDay)!
        let codexTotals = usageAgg.totals(app: .codex, from: targetDay, to: nextDay)
        let claudeTotals = usageAgg.totals(app: .claude, from: targetDay, to: nextDay)
        XCTAssertEqual(codexTotals.inputTokens, 1_200)
        XCTAssertEqual(codexTotals.costUSD, Decimal(string: "1.70")!)
        XCTAssertEqual(claudeTotals.inputTokens, 2_300)
        XCTAssertEqual(claudeTotals.outputTokens, 800)
        XCTAssertEqual(claudeTotals.costUSD, Decimal(string: "4.30")!)

        // 3) Conversation list & attribution consistency (totals - attributed == unattributed)
        let queryResult = convAgg.query(ConversationQueryRequest(
            revision: convAgg.revision,
            app: nil,
            projectKey: nil,
            from: targetDay,
            to: nextDay,
            search: "",
            sort: .recent
        ))
        XCTAssertEqual(queryResult.rows.map(\.id), [macBConvKey, localConvKey])
        XCTAssertEqual(convAgg.syncedDeviceName(forKey: macBConvKey), "Studio Mac")
        XCTAssertNil(convAgg.syncedDeviceName(forKey: localConvKey))

        let breakdown = convAgg.overviewBreakdown(ConversationOverviewRequest(
            revision: convAgg.revision,
            from: targetDay,
            to: nextDay,
            apps: [.codex, .claude],
            topConversationLimit: 10
        ))
        XCTAssertEqual(breakdown.attributedByApp[.claude]?.inputTokens, 2_000)
        XCTAssertEqual(claudeTotals.clampedSubtracting(breakdown.attributedByApp[.claude] ?? .zero).inputTokens, 300)

        // 4) Synced session history record carries prompt summaries & device badge
        XCTAssertEqual(overlay.syncedSessionRecords.count, 1)
        let importedSession = try XCTUnwrap(overlay.syncedSessionRecords.first)
        XCTAssertTrue(importedSession.isRemoteSynced)
        XCTAssertEqual(importedSession.syncedDeviceName, "Studio Mac")
        XCTAssertEqual(importedSession.cwd, macBProject.path)
        XCTAssertEqual(importedSession.firstPrompt, "这个conversations能不能通过云端同步？")
        XCTAssertEqual(importedSession.latestPrompt, "按方案1,同步对话列表摘要和token账单。")
    }

    // MARK: - 2. Duplicate & Cross-Device Continued Conversation Deduplication

    func testDuplicateAndContinuedConversationZeroDoubleCounting() throws {
        let targetDay = day(2026, 11, 18)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDay)!

        let duplicateKey = "codex:dup-1"
        let continuedKey = "codex:cont-2"

        let localDupInfo = makeInfo(key: duplicateKey, id: "dup-1", app: .codex, title: "完全相同对话", projectPath: nil, at: targetDay)
        let localContInfo = makeInfo(key: continuedKey, id: "cont-2", app: .codex, title: "跨机续聊对话", projectPath: nil, at: targetDay)

        let localDupBucket = makeConvBucket(
            key: duplicateKey, app: .codex, day: targetDay, model: "gpt-5",
            input: 1_000, output: 400, cost: Decimal(string: "1.00")!, requests: 2, at: targetDay
        )
        let localContBucket = makeConvBucket(
            key: continuedKey, app: .codex, day: targetDay, model: "gpt-5",
            input: 1_000, output: 400, cost: Decimal(string: "1.00")!, requests: 2, at: targetDay
        )

        // Peer B has identical dup-1, and continued cont-2 up to 1600 in / 700 out / $1.80 / 4 reqs
        let peerBShard = CloudSyncMerger.makeLocalShard(
            deviceID: "peer-b",
            deviceName: "MacBook Air",
            exportedAt: targetDay.addingTimeInterval(600),
            homePath: "/Users/alice",
            localUsageBuckets: [],
            localConversations: (
                infos: [localDupInfo, localContInfo],
                buckets: [
                    localDupBucket,
                    makeConvBucket(
                        key: continuedKey, app: .codex, day: targetDay, model: "gpt-5",
                        input: 1_600, output: 700, cost: Decimal(string: "1.80")!, requests: 4,
                        at: targetDay.addingTimeInterval(500)
                    )
                ]
            ),
            localSessionRecords: [],
            calendar: calendar
        )

        // Peer C also synced an intermediate snapshot of cont-2 (1200 in / 500 out / $1.20 / 3 reqs)
        let peerCShard = CloudSyncMerger.makeLocalShard(
            deviceID: "peer-c",
            deviceName: "Mac mini",
            exportedAt: targetDay.addingTimeInterval(300),
            homePath: "/Users/alice",
            localUsageBuckets: [],
            localConversations: (
                infos: [localContInfo],
                buckets: [
                    makeConvBucket(
                        key: continuedKey, app: .codex, day: targetDay, model: "gpt-5",
                        input: 1_200, output: 500, cost: Decimal(string: "1.20")!, requests: 3,
                        at: targetDay.addingTimeInterval(250)
                    )
                ]
            ),
            localSessionRecords: [],
            calendar: calendar
        )

        let usageAgg = UsageAggregator()
        usageAgg.load(from: [
            UsageBucket(
                app: .codex, model: "gpt-5", speed: .standard, day: targetDay,
                inputTokens: 2_000, outputTokens: 800, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: Decimal(string: "2.00")!, requestCount: 4, hasUnpricedUsage: false
            )
        ])
        let convAgg = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: tempDir.path))
        convAgg.load(infos: [localDupInfo, localContInfo], buckets: [localDupBucket, localContBucket])

        let overlay = CloudSyncMerger.mergePeers(
            peers: [peerBShard, peerCShard],
            localConversations: convAgg.snapshot(),
            localSessionKeys: [duplicateKey, continuedKey],
            homePath: tempDir.path,
            calendar: calendar
        )

        // Duplicate conversation must produce 0 net buckets; continued conversation produces exact +600/+300/+$0.80/+2 delta
        XCTAssertEqual(overlay.netConversationBuckets.count, 1)
        let netCont = try XCTUnwrap(overlay.netConversationBuckets.first)
        XCTAssertEqual(netCont.conversationKey, continuedKey)
        XCTAssertEqual(netCont.inputTokens, 600)
        XCTAssertEqual(netCont.outputTokens, 300)
        XCTAssertEqual(netCont.costUSD, Decimal(string: "0.80")!)
        XCTAssertEqual(netCont.requestCount, 2)
        XCTAssertNil(overlay.syncedDeviceNames[continuedKey], "Conversation present locally must not be marked remote-only")

        usageAgg.replaceSynced(buckets: overlay.netUsageBuckets)
        convAgg.replaceSynced(
            infos: overlay.syncedInfos,
            buckets: overlay.netConversationBuckets,
            deviceNames: overlay.syncedDeviceNames
        )

        // Effective totals: dup-1 (1000/400/$1.00) + cont-2 (1600/700/$1.80) = 2600/1100/$2.80
        let combinedTotals = usageAgg.totals(app: .codex, from: targetDay, to: nextDay)
        XCTAssertEqual(combinedTotals.inputTokens, 2_600)
        XCTAssertEqual(combinedTotals.outputTokens, 1_100)
        XCTAssertEqual(combinedTotals.costUSD, Decimal(string: "2.80")!)
        XCTAssertEqual(combinedTotals.requestCount, 6)

        let contDetail = try XCTUnwrap(convAgg.detail(key: continuedKey))
        XCTAssertEqual(contDetail.totals.inputTokens, 1_600)
        XCTAssertEqual(contDetail.totals.outputTokens, 700)
        XCTAssertEqual(contDetail.totals.costUSD, Decimal(string: "1.80")!)
        XCTAssertEqual(contDetail.totals.requestCount, 4)
    }

    // MARK: - 3. Portable Path & macOS TCC Boundary Protection

    func testPortableHomePathExpansionAndTCCProtection() throws {
        let targetDay = day(2026, 11, 18)
        let receiverHome = tempDir.appendingPathComponent("receiver-home", isDirectory: true)
        let existingSafeRepo = receiverHome.appendingPathComponent("workspace/demo-app", isDirectory: true)
        let protectedDesktopRepo = receiverHome.appendingPathComponent("Desktop/secret-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: existingSafeRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protectedDesktopRepo, withIntermediateDirectories: true)

        XCTAssertEqual(CloudSyncMerger.portablePath("/Users/alice/workspace/demo-app", homePath: "/Users/alice"), "~/workspace/demo-app")
        XCTAssertEqual(CloudSyncMerger.expandPortablePath("~/workspace/demo-app", homePath: receiverHome.path), existingSafeRepo.path)

        let safeInfo = makeInfo(
            key: "claude:safe-1", id: "safe-1", app: .claude, title: "Safe Repo",
            projectPath: "/Users/alice/workspace/demo-app", at: targetDay
        )
        let tccInfo = makeInfo(
            key: "claude:tcc-1", id: "tcc-1", app: .claude, title: "Desktop Repo",
            projectPath: "/Users/alice/Desktop/secret-notes", at: targetDay
        )
        let missingInfo = makeInfo(
            key: "claude:missing-1", id: "missing-1", app: .claude, title: "Other Mac Only Repo",
            projectPath: "/Users/alice/workspace/only-on-mac-a", at: targetDay
        )

        let peerShard = CloudSyncMerger.makeLocalShard(
            deviceID: "peer-tcc",
            deviceName: "iMac",
            exportedAt: targetDay,
            homePath: "/Users/alice",
            localUsageBuckets: [],
            localConversations: (
                infos: [safeInfo, tccInfo, missingInfo],
                buckets: [
                    makeConvBucket(key: "claude:safe-1", app: .claude, day: targetDay, model: "claude-sonnet-4-5", input: 100, output: 50, cost: 1, requests: 1, at: targetDay),
                    makeConvBucket(key: "claude:tcc-1", app: .claude, day: targetDay, model: "claude-sonnet-4-5", input: 100, output: 50, cost: 1, requests: 1, at: targetDay),
                    makeConvBucket(key: "claude:missing-1", app: .claude, day: targetDay, model: "claude-sonnet-4-5", input: 100, output: 50, cost: 1, requests: 1, at: targetDay),
                ]
            ),
            localSessionRecords: [
                SessionHistoryRecord(
                    key: "claude:tcc-1",
                    sessionID: "tcc-1",
                    origin: .claudeCode,
                    cwd: "/Users/alice/Desktop/secret-notes",
                    projectName: "secret-notes",
                    lastActiveAt: targetDay,
                    createdAt: targetDay,
                    title: "Desktop Repo",
                    summary: nil,
                    firstPrompt: "整理桌面笔记",
                    latestPrompt: nil,
                    isSubagent: false,
                    permission: nil,
                    gitBranch: nil
                )
            ],
            calendar: calendar
        )

        let overlay = CloudSyncMerger.mergePeers(
            peers: [peerShard],
            localConversations: (infos: [], buckets: []),
            localSessionKeys: [],
            homePath: receiverHome.path,
            calendar: calendar
        )

        let byKey = Dictionary(uniqueKeysWithValues: overlay.syncedInfos.map { ($0.key, $0) })
        XCTAssertEqual(byKey["claude:safe-1"]?.projectPath, existingSafeRepo.path)
        XCTAssertEqual(byKey["claude:safe-1"]?.projectStatus, .available)

        XCTAssertEqual(byKey["claude:tcc-1"]?.projectPath, protectedDesktopRepo.path)
        XCTAssertEqual(byKey["claude:tcc-1"]?.projectStatus, .unverified, "Desktop path must skip filesystem probe and stay .unverified")

        XCTAssertEqual(byKey["claude:missing-1"]?.projectStatus, .unverified, "Non-local path from another Mac must be .unverified rather than deleted/unavailable")

        let remoteDesktopSession = try XCTUnwrap(overlay.syncedSessionRecords.first)
        XCTAssertTrue(remoteDesktopSession.isRemoteSynced)
        XCTAssertFalse(remoteDesktopSession.cwdIsMissing, "Remote synced session must never warn that local cwd is missing")
    }

    // MARK: - 4. Remote-Only Resume Command Suppression

    func testRemoteOnlyConversationSuppressesLocalResumeCommand() throws {
        let now = Date()
        let emptyRoots = SessionHistoryRoots(
            codexHome: tempDir.appendingPathComponent("empty-codex", isDirectory: true),
            antigravityRoots: [],
            homePath: tempDir.path
        )
        let service = SessionHistoryService(roots: emptyRoots, cacheFileURL: nil)

        let remoteKey = "codex:remote-only-uuid"
        let remoteWithoutSessionKey = "claude:remote-info-only"
        let localKey = "codex:local-uuid"

        service.isRemoteOnlyConversation = { key in
            key == remoteKey || key == remoteWithoutSessionKey
        }
        service.replaceSyncedRecords([
            SessionHistoryRecord(
                key: remoteKey,
                sessionID: "remote-only-uuid",
                origin: .codex,
                cwd: tempDir.path,
                projectName: "demo",
                lastActiveAt: now,
                createdAt: now,
                title: "远端会话",
                summary: nil,
                firstPrompt: "远端提问",
                latestPrompt: nil,
                isSubagent: false,
                permission: nil,
                gitBranch: nil,
                syncedDeviceName: "Mac Studio"
            )
        ])

        let remoteInfo1 = makeInfo(key: remoteKey, id: "remote-only-uuid", app: .codex, title: "远端会话", projectPath: tempDir.path, at: now)
        let remoteInfo2 = makeInfo(key: remoteWithoutSessionKey, id: "remote-info-only", app: .claude, title: "远端仅账单对话", projectPath: tempDir.path, at: now)
        let localInfo = makeInfo(key: localKey, id: "local-uuid", app: .codex, title: "本机会话", projectPath: tempDir.path, at: now)

        XCTAssertNil(service.resumeCommand(for: remoteInfo1), "Synced session record must not produce a local terminal resume command")
        XCTAssertNil(service.resumeCommand(for: remoteInfo2), "Remote-only ConversationInfo must not produce a fallback local resume command")
        XCTAssertNotNil(service.resumeCommand(for: localInfo), "Local conversation must still produce a resume command")
    }

    // MARK: - 5. End-to-End Directory Shard Sync, Peer Removal & Disable Cleanup

    func testEndToEndCloudSyncServiceShardWriteMergeRemoveAndDisable() async throws {
        let targetDay = day(2026, 11, 18)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDay)!
        let syncRoot = tempDir.appendingPathComponent("CCBarSync", isDirectory: true)

        let settings = SettingsStore(defaults: suiteDefaults)
        settings.cloudSyncDirectoryMode = .custom
        settings.cloudSyncCustomDirectory = syncRoot.path
        settings.cloudSyncDeviceName = "Mac A"
        settings.cloudSyncEnabled = true

        let syncService = CloudSyncService(settings: settings)
        let appState = AppState()

        // Seed Mac A local state
        let localKey = "codex:local-e2e"
        appState.usageService.aggregator.load(from: [
            UsageBucket(
                app: .codex, model: "gpt-5", speed: .standard, day: targetDay,
                inputTokens: 500, outputTokens: 200, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: Decimal(string: "0.50")!, requestCount: 1, hasUnpricedUsage: false
            )
        ])
        appState.usageService.conversationAggregator.load(
            infos: [makeInfo(key: localKey, id: "local-e2e", app: .codex, title: "本机任务", projectPath: nil, at: targetDay)],
            buckets: [makeConvBucket(key: localKey, app: .codex, day: targetDay, model: "gpt-5", input: 500, output: 200, cost: Decimal(string: "0.50")!, requests: 1, at: targetDay)]
        )

        // Pre-populate peer shard file in <syncRoot>/devices/device-peer-mac-b.json
        let peerKey = "claude:peer-e2e"
        let peerShard = CloudSyncMerger.makeLocalShard(
            deviceID: "peer-mac-b",
            deviceName: "Mac B",
            exportedAt: targetDay.addingTimeInterval(100),
            homePath: "/Users/bob",
            localUsageBuckets: [],
            localConversations: (
                infos: [makeInfo(key: peerKey, id: "peer-e2e", app: .claude, title: "另一台 Mac 的对话", projectPath: nil, at: targetDay)],
                buckets: [makeConvBucket(key: peerKey, app: .claude, day: targetDay, model: "claude-sonnet-4-5", input: 900, output: 300, cost: Decimal(string: "2.25")!, requests: 2, at: targetDay)]
            ),
            localSessionRecords: [],
            calendar: calendar
        )
        let devicesDir = CloudSyncService.devicesDirectoryURL(in: syncRoot)
        try FileManager.default.createDirectory(at: devicesDir, withIntermediateDirectories: true)
        let peerFileURL = CloudSyncService.shardFileURL(in: syncRoot, deviceID: "peer-mac-b")
        try JSONEncoder().encode(peerShard).write(to: peerFileURL, options: .atomic)

        // 1) Run syncNow: exports local shard AND merges peer shard
        await syncService.syncNow(appState: appState)
        XCTAssertNil(syncService.lastError)
        XCTAssertEqual(syncService.peerStatuses.count, 1)
        XCTAssertEqual(syncService.peerStatuses.first?.deviceName, "Mac B")

        let localShardURL = CloudSyncService.shardFileURL(in: syncRoot, deviceID: settings.cloudSyncDeviceID)
        let exportedLocalShard = try JSONDecoder().decode(CCBarDeviceSyncShard.self, from: Data(contentsOf: localShardURL))
        XCTAssertEqual(exportedLocalShard.conversationInfos.map(\.key), [localKey], "Local shard must NEVER re-export peer conversations")

        XCTAssertEqual(
            appState.usageService.aggregator.totals(app: .claude, from: targetDay, to: nextDay).costUSD,
            Decimal(string: "2.25")!
        )
        XCTAssertEqual(appState.usageService.conversationAggregator.syncedDeviceName(forKey: peerKey), "Mac B")

        // 2) Remove peer shard -> deletes peer file and restores local-only totals
        await syncService.removePeerShard(deviceID: "peer-mac-b", appState: appState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: peerFileURL.path))
        XCTAssertTrue(syncService.peerStatuses.isEmpty)
        XCTAssertEqual(appState.usageService.aggregator.totals(app: .claude, from: targetDay, to: nextDay).totalTokens, 0)

        // 3) Re-add peer shard, sync, then disable cloud sync -> clears in-memory overlay while keeping disk shard intact
        try JSONEncoder().encode(peerShard).write(to: peerFileURL, options: .atomic)
        await syncService.syncNow(appState: appState)
        XCTAssertEqual(appState.usageService.aggregator.totals(app: .claude, from: targetDay, to: nextDay).inputTokens, 900)

        settings.cloudSyncEnabled = false
        await syncService.syncNow(appState: appState)
        XCTAssertEqual(appState.usageService.aggregator.totals(app: .claude, from: targetDay, to: nextDay).totalTokens, 0)
        XCTAssertEqual(appState.usageService.aggregator.totals(app: .codex, from: targetDay, to: nextDay).inputTokens, 500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: peerFileURL.path), "Disabling sync must not delete cloud files")
    }

    // MARK: - Helpers

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeInfo(
        key: String,
        id: String,
        app: UsageApp,
        title: String?,
        projectPath: String?,
        sourcePaths: [String] = [],
        at date: Date
    ) -> ConversationInfo {
        if let projectPath {
            let name = URL(fileURLWithPath: projectPath).lastPathComponent
            return ConversationInfo(
                key: key,
                conversationID: id,
                app: app,
                title: title,
                projectKey: "path:\(projectPath)",
                projectName: name,
                projectPath: projectPath,
                projectStatus: .available,
                projectSource: .cwd,
                gitBranch: "custom",
                sourcePaths: sourcePaths,
                firstAt: date,
                lastAt: date,
                includesSubtasks: false,
                cacheCreationAvailable: true
            )
        }
        return ConversationInfo(
            key: key,
            conversationID: id,
            app: app,
            title: title,
            projectKey: ConversationProject.unassigned.key,
            projectName: "",
            projectPath: "",
            projectStatus: .unassigned,
            projectSource: .unassigned,
            gitBranch: nil,
            sourcePaths: sourcePaths,
            firstAt: date,
            lastAt: date,
            includesSubtasks: false,
            cacheCreationAvailable: true
        )
    }

    private func makeConvBucket(
        key: String,
        app: UsageApp,
        day: Date,
        model: String,
        input: Int,
        output: Int,
        cost: Decimal,
        requests: Int,
        at date: Date
    ) -> ConversationUsageBucket {
        ConversationUsageBucket(
            conversationKey: key,
            app: app,
            day: day,
            model: model,
            speed: .standard,
            firstAt: date,
            lastAt: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            requestCount: requests,
            costUSD: cost,
            inputCostUSD: cost,
            outputCostUSD: 0,
            cacheReadCostUSD: 0,
            cacheCreationCostUSD: 0,
            hasUnpricedUsage: false
        )
    }
}
