import XCTest
import SQLite3
@testable import CCBar

final class SessionResumeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-resume-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Shell Path Escaping & Command Generation

    func testShellSingleQuoteEscaping() {
        XCTAssertEqual(
            ShellPathEscaper.singleQuoted("/Users/tangke/My Project"),
            "'/Users/tangke/My Project'"
        )
        XCTAssertEqual(
            ShellPathEscaper.singleQuoted("/Users/tangke/ke's repo"),
            #"'/Users/tangke/ke'\''s repo'"#
        )
        XCTAssertEqual(
            ShellPathEscaper.singleQuoted("/Users/tangke/'quoted'/dir$1"),
            #"'/Users/tangke/'\''quoted'\''/dir$1'"#
        )
    }

    func testResumeCommandGenerationByOrigin() {
        let codexWithCwd = SessionResumeCommand.build(
            origin: .codex,
            sessionID: "019d7923-a274-7162-a264-1744015f4cf2",
            cwd: "/Users/tangke/ke's app"
        )
        XCTAssertEqual(
            codexWithCwd.command,
            #"cd '/Users/tangke/ke'\''s app' && codex resume 019d7923-a274-7162-a264-1744015f4cf2"#
        )

        let codexWithoutCwd = SessionResumeCommand.build(
            origin: .codex,
            sessionID: "019d7923-a274-7162-a264-1744015f4cf2",
            cwd: nil
        )
        XCTAssertEqual(
            codexWithoutCwd.command,
            "codex resume 019d7923-a274-7162-a264-1744015f4cf2"
        )

        let agyCLIWithCwd = SessionResumeCommand.build(
            origin: .antigravityCLI,
            sessionID: "c09da653-14dc-4d5c-89ec-fefe9234751b",
            cwd: "/Users/tangke/cc-bar-custom"
        )
        XCTAssertEqual(
            agyCLIWithCwd.command,
            "cd '/Users/tangke/cc-bar-custom' && agy --conversation c09da653-14dc-4d5c-89ec-fefe9234751b"
        )

        let agyCLIWithoutCwd = SessionResumeCommand.build(
            origin: .antigravityCLI,
            sessionID: "c09da653-14dc-4d5c-89ec-fefe9234751b",
            cwd: "   "
        )
        XCTAssertEqual(
            agyCLIWithoutCwd.command,
            "agy --conversation c09da653-14dc-4d5c-89ec-fefe9234751b"
        )

        let agyDesktop = SessionResumeCommand.build(
            origin: .antigravityDesktop,
            sessionID: "desk-123",
            cwd: "/Users/tangke/Desktop Project"
        )
        XCTAssertEqual(agyDesktop.command, "cd '/Users/tangke/Desktop Project' && agy")
        XCTAssertTrue(agyDesktop.requiresDesktopResumeHint)
    }

    // MARK: - Codex & Antigravity Incremental Scanner + CWD Recovery

    func testCodexAndAntigravityScanningAndCwdRecovery() throws {
        let fakeHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let codexHome = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent("sessions/2026/11/15", isDirectory: true)
        let agyCLIRoot = fakeHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let agyDesktopRoot = fakeHome.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let realProjectDir = fakeHome.appendingPathComponent("cc-bar-custom", isDirectory: true)

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agyCLIRoot.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agyDesktopRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realProjectDir.appendingPathComponent(".git"), withIntermediateDirectories: true)

        // 1. Codex fixture
        let codexUUID = "11111111-2222-3333-4444-555555555555"
        let indexJSONL = """
        {"id":"\(codexUUID)","thread_name":"悬停配额定制","updated_at":"2026-11-15T07:30:00Z"}
        """
        try indexJSONL.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let rolloutJSONL = """
        {"timestamp":"2026-11-15T07:10:00Z","type":"session_meta","payload":{"id":"\(codexUUID)","cwd":"\(realProjectDir.path)"}}
        {"timestamp":"2026-11-15T07:10:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\\n<cwd>\(realProjectDir.path)</cwd>\\n</environment_context>"}]}}
        {"timestamp":"2026-11-15T07:11:00Z","type":"event_msg","payload":{"type":"user_message","message":"请实现 NSStatusItem 鼠标悬停配额弹窗"}}
        {"timestamp":"2026-11-15T07:25:00Z","type":"event_msg","payload":{"type":"user_message","message":"再补上单引号路径转义测试"}}
        """
        let rolloutURL = sessionsDir.appendingPathComponent("rollout-2026-11-15T07-10-00-\(codexUUID).jsonl")
        try rolloutJSONL.write(to: rolloutURL, atomically: true, encoding: .utf8)

        // 2. Antigravity CLI fixture (workspace in SQLite is generic fakeHome, real project recovered from transcript tool_calls!)
        let cliID = "aaaa1111-bbbb-2222-cccc-333333333333"
        try createSummariesDB(
            at: agyCLIRoot.appendingPathComponent("conversation_summaries.db"),
            rows: [(
                id: cliID,
                title: "Antigravity CLI 会话测试",
                preview: "修复 SQLite 只读还原 cwd",
                modified: "2026-11-15T07:28:00Z",
                workspaceURIs: "[\"file://\(fakeHome.path)\"]",
                source: "CORTEX_TRAJECTORY_SOURCE_CLI",
                appDataDir: "antigravity-cli"
            )]
        )
        let transcriptDir = agyCLIRoot
            .appendingPathComponent("brain/\(cliID)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcriptJSONL = """
        {"step_index":0,"type":"USER_INPUT","created_at":"2026-11-15T07:20:00Z","content":"<USER_REQUEST>\\n帮我检查 AGENTS.md\\n</USER_REQUEST>"}
        {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-15T07:21:00Z","tool_calls":[{"name":"read_file","arguments":{"Path":"\(realProjectDir.path)/AGENTS.md"}}]}
        {"step_index":2,"type":"USER_INPUT","created_at":"2026-11-15T07:28:00Z","content":"<USER_REQUEST>\\n生成可运行的 Release 包\\n</USER_REQUEST>"}
        """
        try transcriptJSONL.write(
            to: transcriptDir.appendingPathComponent("transcript.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        // 3. Antigravity Desktop fixture
        let deskID = "dddd4444-eeee-5555-ffff-666666666666"
        let deskProjectPath = fakeHome.appendingPathComponent("Documents/MyDeskApp", isDirectory: true).path
        try createSummariesDB(
            at: agyDesktopRoot.appendingPathComponent("conversation_summaries.db"),
            rows: [(
                id: deskID,
                title: "桌面端重构任务",
                preview: "调整桌面端 UI 细节",
                modified: "2026-11-15T07:15:00Z",
                workspaceURIs: "[\"file://\(deskProjectPath)\"]",
                source: "CORTEX_TRAJECTORY_SOURCE_CASCADE",
                appDataDir: "antigravity"
            )]
        )

        let roots = SessionHistoryRoots(
            codexHome: codexHome,
            antigravityRoots: [agyCLIRoot, agyDesktopRoot],
            homePath: fakeHome.standardizedFileURL.path
        )

        let firstScan = SessionHistoryScanner.scan(previous: nil, roots: roots)
        XCTAssertEqual(firstScan.records.count, 3)

        let byKey = Dictionary(uniqueKeysWithValues: firstScan.records.map { ($0.key, $0) })

        let codexRecord = try XCTUnwrap(byKey["codex:\(codexUUID)"])
        XCTAssertEqual(codexRecord.origin, .codex)
        XCTAssertEqual(codexRecord.cwd, realProjectDir.standardizedFileURL.path)
        XCTAssertEqual(codexRecord.projectName, "cc-bar-custom")
        XCTAssertEqual(codexRecord.title, "悬停配额定制")
        XCTAssertEqual(codexRecord.firstPrompt, "请实现 NSStatusItem 鼠标悬停配额弹窗")
        XCTAssertEqual(codexRecord.latestPrompt, "再补上单引号路径转义测试")
        XCTAssertTrue(codexRecord.matches(lowercasedQuery: "单引号路径转义"))

        let cliRecord = try XCTUnwrap(byKey["antigravity:\(cliID)"])
        XCTAssertEqual(cliRecord.origin, .antigravityCLI)
        XCTAssertEqual(cliRecord.cwd, realProjectDir.standardizedFileURL.path)
        XCTAssertEqual(cliRecord.projectName, "cc-bar-custom")
        XCTAssertEqual(cliRecord.firstPrompt, "帮我检查 AGENTS.md")
        XCTAssertEqual(cliRecord.latestPrompt, "生成可运行的 Release 包")
        XCTAssertEqual(
            cliRecord.resumeCommand.command,
            "cd '\(realProjectDir.standardizedFileURL.path)' && agy --conversation \(cliID)"
        )

        let deskRecord = try XCTUnwrap(byKey["antigravity:\(deskID)"])
        XCTAssertEqual(deskRecord.origin, .antigravityDesktop)
        XCTAssertEqual(deskRecord.projectName, "MyDeskApp")
        XCTAssertEqual(deskRecord.resumeCommand.command, "cd '\(deskProjectPath)' && agy")

        // 增量缓存验证：文件未变动时二次扫描状态与结果完全一致
        let secondScan = SessionHistoryScanner.scan(previous: firstScan.state, roots: roots)
        XCTAssertEqual(secondScan.state, firstScan.state)
        XCTAssertEqual(secondScan.records, firstScan.records)
    }

    // MARK: - SQLite Fixture Helper

    private func createSummariesDB(
        at url: URL,
        rows: [(id: String, title: String, preview: String, modified: String, workspaceURIs: String, source: String, appDataDir: String)]
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to create test SQLite DB")
            return
        }
        defer { sqlite3_close(db) }
        let createSQL = """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            last_modified_time TEXT,
            created_time TEXT,
            workspace_uris TEXT,
            source TEXT,
            app_data_dir TEXT,
            parent_conversation_id TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)

        let insertSQL = """
        INSERT INTO conversation_summaries
        (conversation_id, title, preview, last_modified_time, created_time, workspace_uris, source, app_data_dir, parent_conversation_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '');
        """
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, row.id, -1, transient)
            sqlite3_bind_text(stmt, 2, row.title, -1, transient)
            sqlite3_bind_text(stmt, 3, row.preview, -1, transient)
            sqlite3_bind_text(stmt, 4, row.modified, -1, transient)
            sqlite3_bind_text(stmt, 5, row.modified, -1, transient)
            sqlite3_bind_text(stmt, 6, row.workspaceURIs, -1, transient)
            sqlite3_bind_text(stmt, 7, row.source, -1, transient)
            sqlite3_bind_text(stmt, 8, row.appDataDir, -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }
}
