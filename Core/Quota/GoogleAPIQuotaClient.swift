import Foundation

nonisolated struct GoogleAPIUsageSummary: Sendable, Equatable {
    var todayCostUSD: Decimal = 0
    var weekCostUSD: Decimal = 0
    var monthCostUSD: Decimal = 0
    var todayTokens: Int = 0
    var monthTokens: Int = 0
    var todayRequests: Int = 0
}

/// 增量扫描 Gemini CLI 本机对话日志（`~/.gemini/tmp/**/chats/*.jsonl` 与旧版 `session-*.json`），
/// 按消息 `id` 去重合并延迟写入的 `tokens` 记录，并调用 `Pricing.cost(app: .antigravity, ...)` 计算美元费用。
actor GoogleAPILocalUsage {
    static let shared = GoogleAPILocalUsage()

    nonisolated struct FileStamp: Equatable, Sendable {
        let size: UInt64
        let mtime: TimeInterval
    }

    nonisolated struct MessageSample: Equatable, Sendable {
        let timestamp: Date
        let model: String
        let input: Int
        let output: Int
        let cached: Int
        let thoughts: Int
    }

    private struct CachedFile {
        let stamp: FileStamp
        let samples: [MessageSample]
    }

    private var cache: [String: CachedFile] = [:]

    func scan(
        geminiRoot: URL = defaultGeminiRoot(),
        now: Date = Date()
    ) -> GoogleAPIUsageSummary {
        let tmpRoot = geminiRoot.appendingPathComponent("tmp", isDirectory: true)
        let files = Self.discoverChatFiles(under: tmpRoot)
        let cal = Self.gregorianCalendar()
        let cutoff = Self.historyLowerBound(now: now, calendar: cal)

        var nextCache: [String: CachedFile] = [:]
        nextCache.reserveCapacity(files.count)

        var allSamples: [MessageSample] = []
        for entry in files {
            // 只在首次发现或 (size, mtime) 变化时重新解析；历史窗口之前的文件保留空/已缓存条目跳过重读。
            if let existing = cache[entry.path], existing.stamp == entry.stamp {
                nextCache[entry.path] = existing
                allSamples.append(contentsOf: existing.samples)
                continue
            }
            if entry.stamp.mtime < cutoff.timeIntervalSince1970 {
                let empty = CachedFile(stamp: entry.stamp, samples: [])
                nextCache[entry.path] = empty
                continue
            }
            let parsed = Self.parseSessionFile(at: entry.url)
            let cached = CachedFile(stamp: entry.stamp, samples: parsed)
            nextCache[entry.path] = cached
            allSamples.append(contentsOf: parsed)
        }
        cache = nextCache

        return Self.summarize(samples: allSamples, now: now, calendar: cal)
    }

    // MARK: - 纯函数接口（便于单测与离线验证）

    nonisolated static func defaultGeminiRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
    }

    nonisolated static func gregorianCalendar(timeZone: TimeZone = .current) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    nonisolated static func periodBounds(
        now: Date = Date(),
        calendar: Calendar = gregorianCalendar()
    ) -> (todayStart: Date, tomorrowStart: Date, weekStart: Date, monthStart: Date, nextMonthStart: Date) {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let weekComps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = calendar.date(from: weekComps) ?? todayStart
        let monthComps = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: monthComps) ?? todayStart
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? tomorrowStart
        return (todayStart, tomorrowStart, weekStart, monthStart, nextMonthStart)
    }

    nonisolated private static func historyLowerBound(now: Date, calendar: Calendar) -> Date {
        let bounds = periodBounds(now: now, calendar: calendar)
        return min(bounds.weekStart, bounds.monthStart)
    }

    nonisolated private static func discoverChatFiles(under tmpRoot: URL) -> [(url: URL, path: String, stamp: FileStamp)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: tmpRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let walker = fm.enumerator(
            at: tmpRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(url: URL, path: String, stamp: FileStamp)] = []
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            let isChatJSONL = ext == "jsonl" && url.pathComponents.contains("chats")
            let isLegacySessionJSON = ext == "json" && name.hasPrefix("session-") && url.pathComponents.contains("chats")
            guard isChatJSONL || isLegacySessionJSON else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            results.append((url: url, path: url.path, stamp: FileStamp(size: size, mtime: mtime)))
        }
        return results
    }

    nonisolated static func parseSessionFile(at url: URL) -> [MessageSample] {
        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            return parseLegacyJSONFile(at: url)
        }
        return parseJSONLFile(at: url)
    }

    nonisolated private static func parseJSONLFile(at url: URL) -> [MessageSample] {
        var orderedIDs: [String] = []
        var samplesByID: [String: MessageSample] = [:]
        var fallbackLineIndex = 0

        _ = SessionHistoryScanner.streamAllJSONLLines(url: url) { batch in
            for line in batch {
                fallbackLineIndex += 1
                // Gemini CLI 先写一条 tokens=null 的消息，随后追加同一 msg.id 且包含 tokens 的记录。
                guard line.contains("\"tokens\""),
                      line.contains("\"gemini\""),
                      line.utf8.count <= 4 * 1024 * 1024,
                      let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let sample = parseMessageObject(obj)
                else { continue }

                let msgID = (obj["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "line:\(fallbackLineIndex)"
                if samplesByID[msgID] == nil {
                    orderedIDs.append(msgID)
                }
                samplesByID[msgID] = sample
            }
        }

        return orderedIDs.compactMap { samplesByID[$0] }
    }

    nonisolated private static func parseLegacyJSONFile(at url: URL) -> [MessageSample] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]]
        else { return [] }

        var orderedIDs: [String] = []
        var samplesByID: [String: MessageSample] = [:]
        for (index, obj) in messages.enumerated() {
            guard let sample = parseMessageObject(obj) else { continue }
            let msgID = (obj["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "msg:\(index)"
            if samplesByID[msgID] == nil {
                orderedIDs.append(msgID)
            }
            samplesByID[msgID] = sample
        }
        return orderedIDs.compactMap { samplesByID[$0] }
    }

    nonisolated private static func parseMessageObject(_ obj: [String: Any]) -> MessageSample? {
        guard (obj["type"] as? String) == "gemini",
              let tokens = obj["tokens"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = JSONLTimestamp.parse(tsString),
              let model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }

        let input = parseInt(tokens["input"])
        let output = parseInt(tokens["output"])
        let cached = parseInt(tokens["cached"])
        let thoughts = parseInt(tokens["thoughts"])
        guard input > 0 || output > 0 || cached > 0 || thoughts > 0 else { return nil }

        return MessageSample(
            timestamp: timestamp,
            model: model,
            input: input,
            output: output,
            cached: cached,
            thoughts: thoughts
        )
    }

    nonisolated private static func parseInt(_ value: Any?) -> Int {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return max(0, n.intValue)
        }
        if let s = value as? String, let v = Int(s) {
            return max(0, v)
        }
        return 0
    }

    nonisolated static func summarize(
        samples: [MessageSample],
        now: Date = Date(),
        calendar: Calendar = gregorianCalendar()
    ) -> GoogleAPIUsageSummary {
        let bounds = periodBounds(now: now, calendar: calendar)
        var summary = GoogleAPIUsageSummary()

        for sample in samples {
            guard sample.timestamp < bounds.tomorrowStart else { continue }
            let inToday = sample.timestamp >= bounds.todayStart
            let inWeek = sample.timestamp >= bounds.weekStart
            let inMonth = sample.timestamp >= bounds.monthStart
            guard inToday || inWeek || inMonth else { continue }

            let cached = max(0, sample.cached)
            let totalInput = max(0, sample.input)
            let nonCachedInput = max(0, totalInput - cached)
            let outputTotal = max(0, sample.output) + max(0, sample.thoughts)
            let totalTokens = totalInput + outputTotal

            let cost = Pricing.cost(
                app: .antigravity,
                model: sample.model,
                speed: .standard,
                input: nonCachedInput,
                output: outputTotal,
                cacheRead: cached,
                cacheCreation: 0,
                at: sample.timestamp,
                inputTotal: totalInput
            ) ?? 0

            if inToday {
                summary.todayCostUSD += cost
                summary.todayTokens += totalTokens
                summary.todayRequests += 1
            }
            if inWeek {
                summary.weekCostUSD += cost
            }
            if inMonth {
                summary.monthCostUSD += cost
                summary.monthTokens += totalTokens
            }
        }

        return summary
    }
}

/// Google 官方 API（AI Studio & Vertex AI Express）：
/// - AI Studio：`GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=20`（零计费探测 Key 有效性）
/// - Vertex AI Express：`POST https://aiplatform.googleapis.com/v1beta1/publishers/google/models/gemini-3-flash-preview:countTokens`（若模型 404 再降级探测 `gemini-2.5-flash`）
/// - 用量与预算进度：结合 `GoogleAPILocalUsage` 计算当日 / 本周 / 本月消费与日/月预算剩余百分比。
nonisolated enum GoogleAPIQuotaClient {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let aiStudioModelsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=20")!
    private static let vertexExpressV1Beta1CountTokensURL = URL(string: "https://aiplatform.googleapis.com/v1beta1/publishers/google/models/gemini-3-flash-preview:countTokens")!
    private static let vertexExpressLegacyV1CountTokensURL = URL(string: "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:countTokens")!

    static func fetch(
        session: GoogleAPIAuthSession,
        dailyBudgetUSD: Double,
        monthlyBudgetUSD: Double,
        geminiRoot: URL = GoogleAPILocalUsage.defaultGeminiRoot(),
        urlSession: URLSession? = nil,
        dataLoader: DataLoader? = nil,
        now: Date = Date()
    ) async -> Result<(snapshot: QuotaSnapshot, usage: GoogleAPIUsageSummary, resolvedMode: GoogleAPIMode.ResolvedMode), QuotaError> {
        let validation = await validateKey(session: session, urlSession: urlSession, dataLoader: dataLoader)
        guard case .success(let actualMode) = validation else {
            if case .failure(let error) = validation {
                return .failure(error)
            }
            return .failure(.transport("unexpected validation state"))
        }

        let usage = await GoogleAPILocalUsage.shared.scan(geminiRoot: geminiRoot, now: now)
        let snapshot = makeSnapshot(
            mode: actualMode,
            usage: usage,
            dailyBudgetUSD: dailyBudgetUSD,
            monthlyBudgetUSD: monthlyBudgetUSD,
            now: now
        )
        return .success((snapshot, usage, actualMode))
    }

    static func validateKey(
        session: GoogleAPIAuthSession,
        urlSession: URLSession? = nil,
        dataLoader: DataLoader? = nil
    ) async -> Result<GoogleAPIMode.ResolvedMode, QuotaError> {
        let loader: DataLoader = dataLoader ?? { request in
            try await NetworkProxy.data(for: request, session: urlSession)
        }

        let primary = await probeEndpoint(mode: session.resolvedMode, apiKey: session.apiKey, loader: loader)
        if case .success = primary {
            return .success(session.resolvedMode)
        }

        guard case .failure(let primaryError) = primary else {
            return .success(session.resolvedMode)
        }

        if session.configuredMode == .auto,
           let status = primaryError.httpStatusCode,
           [400, 401, 403, 404].contains(status),
           !primaryError.looksLikeInterceptedResponse {
            let alternate: GoogleAPIMode.ResolvedMode = (session.resolvedMode == .vertexExpress) ? .aiStudio : .vertexExpress
            if case .success = await probeEndpoint(mode: alternate, apiKey: session.apiKey, loader: loader) {
                return .success(alternate)
            }
        }

        return .failure(primaryError)
    }

    private static func probeEndpoint(
        mode: GoogleAPIMode.ResolvedMode,
        apiKey: String,
        loader: DataLoader
    ) async -> Result<Void, QuotaError> {
        switch mode {
        case .aiStudio:
            var req = URLRequest(url: aiStudioModelsURL)
            req.httpMethod = "GET"
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            return await executeProbe(req, loader: loader)

        case .vertexExpress:
            let primaryReq = makeVertexCountTokensRequest(url: vertexExpressV1Beta1CountTokensURL, apiKey: apiKey)
            let primaryResult = await executeProbe(primaryReq, loader: loader)
            if case .failure(let err) = primaryResult, err.httpStatusCode == 404 {
                let fallbackReq = makeVertexCountTokensRequest(url: vertexExpressLegacyV1CountTokensURL, apiKey: apiKey)
                return await executeProbe(fallbackReq, loader: loader)
            }
            return primaryResult
        }
    }

    private static func makeVertexCountTokensRequest(url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data(#"{"contents":[{"role":"user","parts":[{"text":"ping"}]}]}"#.utf8)
        req.timeoutInterval = 10
        return req
    }

    private static func executeProbe(_ request: URLRequest, loader: DataLoader) async -> Result<Void, QuotaError> {
        do {
            let (body, response) = try await loader(request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-http response"))
            }
            guard (200...299).contains(http.statusCode) else {
                let message = String(data: body, encoding: .utf8) ?? "status \(http.statusCode)"
                if http.statusCode == 400, isInvalidAPIKeyBody(message) {
                    return .failure(.http(401, message))
                }
                return .failure(.http(http.statusCode, message))
            }
            return .success(())
        } catch {
            return .failure(.from(transport: error))
        }
    }

    static func isServiceBlockedError(_ error: QuotaError) -> Bool {
        guard case .http(let code, let body) = error, code == 403 else { return false }
        let upper = body.uppercased()
        return upper.contains("API_KEY_SERVICE_BLOCKED")
            || upper.contains("SERVICE_DISABLED")
            || upper.contains("HAS NOT BEEN USED IN PROJECT")
    }

    static func isUnsupportedAPIKeyForVertexError(_ error: QuotaError) -> Bool {
        guard case .http(let code, let body) = error, [400, 401, 403].contains(code) else { return false }
        let upper = body.uppercased()
        return upper.contains("API KEYS ARE NOT SUPPORTED")
            || upper.contains("EXPECTED OAUTH2 ACCESS TOKEN")
    }

    static func isInvalidKeyError(_ error: QuotaError) -> Bool {
        guard case .http(let code, let body) = error, [400, 401, 403].contains(code) else { return false }
        return isInvalidAPIKeyBody(body)
    }

    static func makeSnapshot(
        mode: GoogleAPIMode.ResolvedMode,
        usage: GoogleAPIUsageSummary,
        dailyBudgetUSD: Double,
        monthlyBudgetUSD: Double,
        now: Date = Date(),
        calendar: Calendar = GoogleAPILocalUsage.gregorianCalendar()
    ) -> QuotaSnapshot {
        let bounds = GoogleAPILocalUsage.periodBounds(now: now, calendar: calendar)
        let sanitizedDaily = dailyBudgetUSD > 0 ? dailyBudgetUSD : 0
        let sanitizedMonthly = monthlyBudgetUSD > 0 ? monthlyBudgetUSD : 0

        let dailyLimit: QuotaLimit? = sanitizedDaily > 0 ? {
            let costDouble = NSDecimalNumber(decimal: usage.todayCostUSD).doubleValue
            let usedPercent = min(100, max(0, (costDouble / sanitizedDaily) * 100))
            return QuotaLimit(
                id: "google-api-daily",
                kind: .unknown,
                displayName: "DAILY",
                window: QuotaWindow(
                    usedPercent: usedPercent,
                    resetsAt: bounds.tomorrowStart,
                    windowSeconds: 86_400
                )
            )
        }() : nil

        let monthlyLimit: QuotaLimit? = sanitizedMonthly > 0 ? {
            let costDouble = NSDecimalNumber(decimal: usage.monthCostUSD).doubleValue
            let usedPercent = min(100, max(0, (costDouble / sanitizedMonthly) * 100))
            let monthSeconds = max(86_400, Int(bounds.nextMonthStart.timeIntervalSince(bounds.monthStart)))
            return QuotaLimit(
                id: "google-api-monthly",
                kind: .unknown,
                displayName: "MONTHLY",
                window: QuotaWindow(
                    usedPercent: usedPercent,
                    resetsAt: bounds.nextMonthStart,
                    windowSeconds: monthSeconds
                )
            )
        }() : nil

        if dailyLimit == nil, monthlyLimit == nil {
            let unlimitedPrimary = QuotaLimit(
                id: "google-api-daily",
                kind: .unknown,
                displayName: "DAILY",
                window: QuotaWindow(
                    usedPercent: 0,
                    resetsAt: bounds.tomorrowStart,
                    windowSeconds: 86_400
                )
            )
            return QuotaSnapshot(
                app: .googleAPI,
                primaryLimit: unlimitedPrimary,
                secondaryLimit: nil,
                isUnlimited: true,
                planType: mode.displayLabel,
                fetchedAt: now
            )
        }

        let primary = dailyLimit ?? monthlyLimit
        let secondary = dailyLimit != nil ? monthlyLimit : nil
        return QuotaSnapshot(
            app: .googleAPI,
            primaryLimit: primary,
            secondaryLimit: secondary,
            isUnlimited: false,
            planType: mode.displayLabel,
            fetchedAt: now
        )
    }

    private static func isInvalidAPIKeyBody(_ body: String) -> Bool {
        let upper = body.uppercased()
        return upper.contains("API_KEY_INVALID")
            || upper.contains("API KEY NOT VALID")
    }
}
