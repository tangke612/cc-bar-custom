import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import CCBar

final class GoogleAPITests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - 能力与模式自动识别

    func testDescriptorCapabilitiesAndModeAutoDetection() {
        XCTAssertNil(QuotaApp.googleAPI.usageApp)
        let desc = QuotaProviderDescriptor.descriptor(for: .googleAPI)
        XCTAssertEqual(desc?.title, "Google API")
        XCTAssertEqual(desc?.showsCost, true)
        XCTAssertEqual(desc?.supportsMenuBar, true)
        XCTAssertEqual(desc?.supportsFloatingHUD, true)

        let aiKey = "AIza" + "SyTestFakeKey1234567890"
        let vertexKey = "AQ." + "Ab8RN6TestFakeVertexExpressKey123"
        XCTAssertEqual(GoogleAPIMode.auto.resolve(for: aiKey), .aiStudio)
        XCTAssertEqual(GoogleAPIMode.auto.resolve(for: vertexKey), .vertexExpress)
        XCTAssertEqual(GoogleAPIMode.aiStudio.resolve(for: vertexKey), .aiStudio)
        XCTAssertEqual(GoogleAPIMode.vertexExpress.resolve(for: aiKey), .vertexExpress)
    }

    // MARK: - .env 与安全启动脚本

    func testLoadsFromGeminiDotEnvBeforeEnvironment() throws {
        let envURL = tempHome.appendingPathComponent(".gemini/.env")
        try FileManager.default.createDirectory(at: envURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dotEnvKey = "AIza" + "SyDotEnvKey_1234567890"
        let ignoredEnvKey = "AQ." + "FallbackIgnored_123456"
        let content = """
        # Comment line
        export GEMINI_API_KEY="\(dotEnvKey)" # inline comment
        GOOGLE_API_KEY='\(ignoredEnvKey)'
        """
        try content.write(to: envURL, atomically: true, encoding: .utf8)

        let session = GoogleAPIAuth.load(
            homeDirectory: tempHome,
            environment: ["GEMINI_API_KEY": "AIza" + "SyProcessEnvKey_9999999"],
            preference: .automatic,
            mode: .auto
        )
        XCTAssertEqual(session?.source, .geminiDotEnv)
        XCTAssertEqual(session?.apiKey, dotEnvKey)
        XCTAssertEqual(session?.resolvedMode, .aiStudio)

        try FileManager.default.removeItem(at: envURL)
        let envSession = GoogleAPIAuth.load(
            homeDirectory: tempHome,
            environment: ["GOOGLE_API_KEY": "AQ." + "VertexExpressEnvKey_987654321"],
            preference: .automatic,
            mode: .auto
        )
        XCTAssertEqual(envSession?.source, .environment)
        XCTAssertEqual(envSession?.resolvedMode, .vertexExpress)
    }

    func testSyncLaunchEnvFilePermissionsAndCommandSafety() throws {
        let envFile = tempHome.appendingPathComponent("CCBar/google-api.env")
        let aiKey = "AIza" + "SySecretUnitTestKey_12345678"
        let aiSession = GoogleAPIAuthSession(apiKey: aiKey, source: .manualKeychain, resolvedMode: .aiStudio)

        XCTAssertTrue(GoogleAPIAuth.syncLaunchEnvFile(session: aiSession, envFileURL: envFile))
        let attrs = try FileManager.default.attributesOfItem(atPath: envFile.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)

        let aiContents = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertTrue(aiContents.contains("export GEMINI_CLI_AUTH_OVERRIDE='gemini-api-key'"))
        XCTAssertTrue(aiContents.contains("export GEMINI_API_KEY='\(aiKey)'"))
        XCTAssertTrue(aiContents.contains("unset GOOGLE_GENAI_USE_VERTEXAI"))

        let vertexKey = "AQ." + "Ab8RN6SecretVertexKey_87654321"
        let vertexSession = GoogleAPIAuthSession(apiKey: vertexKey, source: .manualKeychain, resolvedMode: .vertexExpress)
        XCTAssertTrue(GoogleAPIAuth.syncLaunchEnvFile(session: vertexSession, envFileURL: envFile))
        let vertexContents = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertTrue(vertexContents.contains("export GEMINI_CLI_AUTH_OVERRIDE='vertex-ai'"))
        XCTAssertTrue(vertexContents.contains("export GOOGLE_GENAI_USE_VERTEXAI='true'"))
        XCTAssertTrue(vertexContents.contains("export GOOGLE_API_KEY='\(vertexKey)'"))
        XCTAssertTrue(vertexContents.contains("unset GEMINI_API_KEY"))
        XCTAssertTrue(vertexContents.contains("unset GOOGLE_CLOUD_PROJECT"))
        XCTAssertTrue(vertexContents.contains("unset GOOGLE_CLOUD_LOCATION"))

        let command = GoogleAPIAuth.buildQuickLaunchCommand(
            envFileURL: envFile,
            directory: "~/My Projects/app's",
            model: "gemini-2.5-pro",
            yoloEnabled: true,
            homeDirectory: tempHome
        )
        XCTAssertFalse(command.contains(vertexKey), "明文 API Key 绝不能进入启动命令或剪贴板")
        XCTAssertTrue(command.contains("cd '\(tempHome.path)/My Projects/app'\\''s'"))
        XCTAssertTrue(command.contains("source '\(envFile.path)'"))
        XCTAssertTrue(command.contains("gemini -y -m 'gemini-2.5-pro'"))
    }

    // MARK: - Gemini CLI JSONL 去重与费用计算

    func testJSONLDeduplicatesByMessageIDAndSummarizesPeriods() throws {
        let chatsDir = tempHome.appendingPathComponent(".gemini/tmp/demo-project/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        var cal = GoogleAPILocalUsage.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        cal.firstWeekday = 2 // Monday
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12, minute: 0))!
        let earlierToday = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9, minute: 0))!
        let earlierThisMonth = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10, minute: 0))!

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // msg-1 先写 tokens:null，再写完整 tokens（含 1M input 与 500K cached），不能重复计费。
        let sessionURL = chatsDir.appendingPathComponent("session-2026-11-15.jsonl")
        let lines = [
            #"{"id":"u1","timestamp":"\#(iso.string(from: earlierToday))","type":"user","content":"hello"}"#,
            #"{"id":"m1","timestamp":"\#(iso.string(from: earlierToday))","type":"gemini","model":"gemini-2.5-flash","tokens":null}"#,
            #"{"id":"m1","timestamp":"\#(iso.string(from: earlierToday))","type":"gemini","model":"gemini-2.5-flash","tokens":{"input":100000,"output":20000,"cached":40000,"thoughts":5000,"tool":0,"total":125000}}"#,
            #"{"id":"m2","timestamp":"\#(iso.string(from: earlierThisMonth))","type":"gemini","model":"gemini-2.5-flash","tokens":{"input":100000,"output":10000,"cached":0,"thoughts":0,"tool":0,"total":110000}}"#,
        ].joined(separator: "\n")
        try lines.write(to: sessionURL, atomically: true, encoding: .utf8)

        let samples = GoogleAPILocalUsage.parseSessionFile(at: sessionURL)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].input, 100_000)
        XCTAssertEqual(samples[0].cached, 40_000)
        XCTAssertEqual(samples[0].thoughts, 5_000)

        let summary = GoogleAPILocalUsage.summarize(samples: samples, now: now, calendar: cal)
        XCTAssertEqual(summary.todayRequests, 1)
        XCTAssertEqual(summary.todayTokens, 125_000)
        XCTAssertEqual(summary.monthTokens, 235_000)
        XCTAssertTrue(summary.todayCostUSD > 0)
        XCTAssertTrue(summary.monthCostUSD > summary.todayCostUSD)
    }

    // MARK: - 预算快照与日志脱敏

    func testBudgetSnapshotUnlimitedVsCapped() {
        let now = Date()
        let usage = GoogleAPIUsageSummary(todayCostUSD: Decimal(2.5), weekCostUSD: Decimal(5), monthCostUSD: Decimal(20))

        let unlimited = GoogleAPIQuotaClient.makeSnapshot(
            mode: .vertexExpress,
            usage: usage,
            dailyBudgetUSD: 0,
            monthlyBudgetUSD: 0,
            now: now
        )
        XCTAssertEqual(unlimited.isUnlimited, true)
        XCTAssertEqual(unlimited.planType, "Vertex Express")
        XCTAssertNotNil(unlimited.primaryLimit)
        XCTAssertNil(unlimited.secondaryLimit)

        let capped = GoogleAPIQuotaClient.makeSnapshot(
            mode: .aiStudio,
            usage: usage,
            dailyBudgetUSD: 10,
            monthlyBudgetUSD: 100,
            now: now
        )
        XCTAssertEqual(capped.isUnlimited, false)
        XCTAssertEqual(capped.primaryLimit?.id, "google-api-daily")
        XCTAssertEqual(capped.primaryLimit?.window.remainingPercent ?? -1, 75, accuracy: 0.01)
        XCTAssertEqual(capped.secondaryLimit?.id, "google-api-monthly")
        XCTAssertEqual(capped.secondaryLimit?.window.remainingPercent ?? -1, 80, accuracy: 0.01)
    }

    func testRedactScrubsGoogleAPIKeys() {
        let aiKey = "AIza" + String(repeating: "Ab12", count: 8) + "Xyz"
        let vertexKey = "AQ." + String(repeating: "Vx98", count: 7)
        let output = Redact.scrub("failed with \(aiKey) and \(vertexKey)")
        XCTAssertFalse(output.contains(aiKey))
        XCTAssertFalse(output.contains(vertexKey))
        XCTAssertFalse(output.contains(String(aiKey.suffix(12))))
        XCTAssertFalse(output.contains(String(vertexKey.suffix(12))))
    }

    @MainActor func testGlobalHotKeyAssignsDistinctIDs() {
        let hk1 = GlobalHotKey(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey) {}
        let hk2 = GlobalHotKey(keyCode: kVK_ANSI_G, modifiers: controlKey | optionKey) {}
        XCTAssertNotEqual(hk1.id, hk2.id)
    }

    @MainActor func testAppAppearanceModeDefaultsToDarkAndPersists() {
        let suiteName = "ccbar.tests.appearance.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let initial = SettingsStore(defaults: suite)
        XCTAssertEqual(initial.appAppearanceMode, .dark)

        initial.appAppearanceMode = .light
        XCTAssertEqual(SettingsStore(defaults: suite).appAppearanceMode, .light)

        initial.appAppearanceMode = .system
        XCTAssertEqual(SettingsStore(defaults: suite).appAppearanceMode, .system)

        XCTAssertNil(AppAppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppAppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearanceMode.dark.nsAppearance?.name, .darkAqua)
        XCTAssertNil(AppAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(AppAppearanceMode.light.preferredColorScheme, ColorScheme.light)
        XCTAssertEqual(AppAppearanceMode.dark.preferredColorScheme, ColorScheme.dark)
    }

    // MARK: - 在线探测自动降级与模式缓存

    func testAutoModeFallsBackFromBlockedVertexToAIStudioForAQKey() async throws {
        let aqKey = "AQ." + "Ab8RN6Fallback" + "TestKey_1234567890"
        let session = GoogleAPIAuthSession(
            apiKey: aqKey,
            source: .manualKeychain,
            resolvedMode: .vertexExpress,
            configuredMode: .auto
        )

        let loader: GoogleAPIQuotaClient.DataLoader = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "aiplatform.googleapis.com" {
                let body = Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"API_KEY_SERVICE_BLOCKED"}]}}"#.utf8)
                let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
            if url.host == "generativelanguage.googleapis.com" {
                let body = Data(#"{"models":[]}"#.utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
            XCTFail("Unexpected host: \(url)")
            throw URLError(.badURL)
        }

        let result = await GoogleAPIQuotaClient.fetch(
            session: session,
            dailyBudgetUSD: 0,
            monthlyBudgetUSD: 0,
            geminiRoot: tempHome,
            dataLoader: loader
        )

        switch result {
        case .success(let fetched):
            XCTAssertEqual(fetched.resolvedMode, .aiStudio)
            XCTAssertEqual(fetched.snapshot.planType, "AI Studio")
        case .failure(let error):
            XCTFail("Expected fallback to AI Studio, got failure: \(error)")
        }
    }

    func testExplicitVertexModeDoesNotFallbackAndDetectsServiceBlocked() async throws {
        let aqKey = "AQ." + "Ab8RN6Explicit" + "VertexKey_123456789"
        let session = GoogleAPIAuthSession(
            apiKey: aqKey,
            source: .manualKeychain,
            resolvedMode: .vertexExpress,
            configuredMode: .vertexExpress
        )

        let loader: GoogleAPIQuotaClient.DataLoader = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "aiplatform.googleapis.com" {
                let body = Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"API_KEY_SERVICE_BLOCKED"}]}}"#.utf8)
                let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
            XCTFail("Explicit vertex mode must not probe AI Studio: \(url)")
            throw URLError(.badURL)
        }

        let result = await GoogleAPIQuotaClient.fetch(
            session: session,
            dailyBudgetUSD: 0,
            monthlyBudgetUSD: 0,
            geminiRoot: tempHome,
            dataLoader: loader
        )

        switch result {
        case .success:
            XCTFail("Expected failure when explicit Vertex Express mode is blocked")
        case .failure(let error):
            XCTAssertTrue(GoogleAPIQuotaClient.isServiceBlockedError(error))
        }
    }

    func testRememberAutoResolvedModePersistsOnlyKeyHash() {
        let suiteName = "ccbar.tests.googleapi.mode.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let aqKey = "AQ." + "Ab8RN6CachedMode" + "TestKey_987654321"
        GoogleAPIAuth.rememberAutoResolvedMode(.aiStudio, for: aqKey, defaults: suite)

        let session = GoogleAPIAuth.load(
            homeDirectory: tempHome,
            environment: ["GOOGLE_API_KEY": aqKey],
            preference: .automatic,
            mode: .auto,
            defaults: suite
        )
        XCTAssertEqual(session?.resolvedMode, .aiStudio)
        XCTAssertEqual(session?.configuredMode, .auto)
        XCTAssertFalse(suite.dictionaryRepresentation().description.contains(aqKey))
    }

    func testStandardAIzaKeyRejectedOnVertexDetectsUnsupportedAPIKeyError() async {
        let aiZaKey = "AIza" + "SyTestUnsupportedVertexKey123456"
        let vertexSession = GoogleAPIAuthSession(
            apiKey: aiZaKey,
            source: .manualKeychain,
            resolvedMode: .vertexExpress,
            configuredMode: .vertexExpress
        )

        let unsupportedResult = await GoogleAPIQuotaClient.fetch(
            session: vertexSession,
            dailyBudgetUSD: 0,
            monthlyBudgetUSD: 0,
            dataLoader: { request in
                let body = """
                {"error":{"code":401,"message":"API keys are not supported by this API. Expected OAuth2 access token or other authentication credentials that assert a principal.","status":"UNAUTHENTICATED"}}
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
        )

        guard case .failure(let unsupportedError) = unsupportedResult else {
            return XCTFail("Expected Vertex AI rejection error")
        }
        XCTAssertTrue(GoogleAPIQuotaClient.isUnsupportedAPIKeyForVertexError(unsupportedError))
        XCTAssertFalse(GoogleAPIQuotaClient.isInvalidKeyError(unsupportedError))
        XCTAssertFalse(GoogleAPIQuotaClient.isServiceBlockedError(unsupportedError))

        let invalidResult = await GoogleAPIQuotaClient.validateKey(
            session: GoogleAPIAuthSession(
                apiKey: aiZaKey,
                source: .manualKeychain,
                resolvedMode: .aiStudio,
                configuredMode: .aiStudio
            ),
            dataLoader: { request in
                let body = """
                {"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
        )

        guard case .failure(let invalidError) = invalidResult else {
            return XCTFail("Expected invalid API key error")
        }
        XCTAssertTrue(GoogleAPIQuotaClient.isInvalidKeyError(invalidError))
        XCTAssertFalse(GoogleAPIQuotaClient.isUnsupportedAPIKeyForVertexError(invalidError))
    }
}
