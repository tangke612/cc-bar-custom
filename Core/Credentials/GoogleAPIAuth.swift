import Carbon.HIToolbox
import CryptoKit
import Foundation
import Security

nonisolated enum GoogleAPICredentialPreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic
    case manual

    var id: String { rawValue }
}

nonisolated enum GoogleAPIMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto
    case aiStudio
    case vertexExpress

    nonisolated enum ResolvedMode: String, Sendable, Equatable, Codable {
        case aiStudio
        case vertexExpress

        var displayLabel: String {
            switch self {
            case .aiStudio: return "AI Studio"
            case .vertexExpress: return "Vertex Express"
            }
        }
    }

    var id: String { rawValue }

    func resolve(for apiKey: String) -> ResolvedMode {
        switch self {
        case .auto:
            return apiKey.hasPrefix("AQ.") ? .vertexExpress : .aiStudio
        case .aiStudio:
            return .aiStudio
        case .vertexExpress:
            return .vertexExpress
        }
    }
}

nonisolated enum GoogleAPIQuickHotKeyPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case ctrlOptG
    case ctrlShiftG
    case cmdShiftG
    case ctrlOptJ

    var id: String { rawValue }

    var keyCode: Int {
        switch self {
        case .ctrlOptG, .ctrlShiftG, .cmdShiftG:
            return kVK_ANSI_G
        case .ctrlOptJ:
            return kVK_ANSI_J
        }
    }

    var modifiers: Int {
        switch self {
        case .ctrlOptG, .ctrlOptJ:
            return controlKey | optionKey
        case .ctrlShiftG:
            return controlKey | shiftKey
        case .cmdShiftG:
            return cmdKey | shiftKey
        }
    }

    var symbol: String {
        switch self {
        case .ctrlOptG: return "⌃⌥G"
        case .ctrlShiftG: return "⌃⇧G"
        case .cmdShiftG: return "⌘⇧G"
        case .ctrlOptJ: return "⌃⌥J"
        }
    }
}

nonisolated struct GoogleAPIAuthSession: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case geminiDotEnv = "gemini-dotenv"
        case environment = "env"
        case manualKeychain = "keychain"

        var displayName: String {
            switch self {
            case .geminiDotEnv: return "~/.gemini/.env"
            case .environment: return "环境变量"
            case .manualKeychain: return "手动 API Key"
            }
        }
    }

    var apiKey: String
    var source: Source
    var resolvedMode: GoogleAPIMode.ResolvedMode

    /// 摘要同时绑定模式与 Key：切 Key 或从 AI Studio 切到 Vertex Express 时都清空旧缓存。
    var accountKey: String {
        let payload = "\(resolvedMode.rawValue):\(apiKey)"
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var planLabel: String {
        resolvedMode.displayLabel
    }
}

/// Google 官方 API Key（AI Studio `AIza...` 与 Vertex AI Express `AQ....`）凭据读写与安全启动命令生成。
/// - 只读 `~/.gemini/.env` 或环境变量，绝不修改 `~/.gemini/settings.json`（保留用户原本的 OAuth 配置）。
/// - 启动 Gemini CLI 时只通过 `0600` 权限环境文件 + `GEMINI_CLI_AUTH_OVERRIDE` 注入密钥，明文 Key 不进命令行、剪贴板和 shell 历史。
nonisolated enum GoogleAPIAuth {
    private static let keychainService = "com.nanvon.ccbar.google-api"
    private static let keychainAccount = "primary"

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: GoogleAPICredentialPreference = .automatic,
        mode: GoogleAPIMode = .auto
    ) -> GoogleAPIAuthSession? {
        if preference == .manual {
            guard let manualKey = loadFromKeychain(), let key = sanitizeKey(manualKey) else { return nil }
            return GoogleAPIAuthSession(
                apiKey: key,
                source: .manualKeychain,
                resolvedMode: mode.resolve(for: key)
            )
        }

        // 1. ~/.gemini/.env（Gemini CLI 官方支持的环境文件）
        let dotEnvURL = homeDirectory.appendingPathComponent(".gemini/.env")
        if let key = readKeyFromDotEnv(at: dotEnvURL) {
            return GoogleAPIAuthSession(
                apiKey: key,
                source: .geminiDotEnv,
                resolvedMode: mode.resolve(for: key)
            )
        }

        // 2. 进程环境变量 GEMINI_API_KEY / GOOGLE_API_KEY
        if let key = sanitizeKey(environment["GEMINI_API_KEY"]) ?? sanitizeKey(environment["GOOGLE_API_KEY"]) {
            return GoogleAPIAuthSession(
                apiKey: key,
                source: .environment,
                resolvedMode: mode.resolve(for: key)
            )
        }

        // 3. 自动模式降级读取 Keychain 手动配置
        if let manualKey = loadFromKeychain(), let key = sanitizeKey(manualKey) {
            return GoogleAPIAuthSession(
                apiKey: key,
                source: .manualKeychain,
                resolvedMode: mode.resolve(for: key)
            )
        }

        return nil
    }

    // MARK: - .env 解析

    static func readKeyFromDotEnv(at url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let entries = parseDotEnv(content)
        return sanitizeKey(entries["GEMINI_API_KEY"]) ?? sanitizeKey(entries["GOOGLE_API_KEY"])
    }

    static func parseDotEnv(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let rest = value.dropFirst()
                if let closing = rest.firstIndex(of: quote) {
                    value = String(rest[..<closing])
                }
            } else if let hashIndex = value.firstIndex(of: "#") {
                value = String(value[..<hashIndex]).trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    // MARK: - 安全启动环境文件（chmod 0600）

    static func defaultEnvFileURL(supportDirectory: URL? = nil) -> URL {
        let base = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("CCBar", isDirectory: true)
            .appendingPathComponent("google-api.env")
    }

    static func launchEnvFileContents(for session: GoogleAPIAuthSession) -> String {
        let quotedKey = ShellPathEscaper.singleQuoted(session.apiKey)
        switch session.resolvedMode {
        case .aiStudio:
            return [
                "# Managed by CCBar (chmod 600). Do not commit or share.",
                "export GEMINI_CLI_AUTH_OVERRIDE='gemini-api-key'",
                "export GEMINI_API_KEY=\(quotedKey)",
                "unset GOOGLE_GENAI_USE_VERTEXAI",
                "unset GOOGLE_API_KEY",
                "",
            ].joined(separator: "\n")
        case .vertexExpress:
            return [
                "# Managed by CCBar (chmod 600). Do not commit or share.",
                "export GEMINI_CLI_AUTH_OVERRIDE='vertex-ai'",
                "export GOOGLE_GENAI_USE_VERTEXAI='true'",
                "export GOOGLE_API_KEY=\(quotedKey)",
                "unset GEMINI_API_KEY",
                "",
            ].joined(separator: "\n")
        }
    }

    @discardableResult
    static func syncLaunchEnvFile(
        session: GoogleAPIAuthSession?,
        envFileURL: URL = defaultEnvFileURL()
    ) -> Bool {
        let fm = FileManager.default
        guard let session else {
            if fm.fileExists(atPath: envFileURL.path) {
                try? fm.removeItem(at: envFileURL)
            }
            return true
        }

        let directory = envFileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        guard let data = launchEnvFileContents(for: session).data(using: .utf8) else { return false }
        let tempURL = directory.appendingPathComponent(".\(envFileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
        guard fm.createFile(atPath: tempURL.path, contents: data, attributes: attrs) else {
            return false
        }
        do {
            if fm.fileExists(atPath: envFileURL.path) {
                _ = try fm.replaceItemAt(envFileURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: envFileURL)
            }
            try fm.setAttributes(attrs, ofItemAtPath: envFileURL.path)
            return true
        } catch {
            try? fm.removeItem(at: tempURL)
            return false
        }
    }

    // MARK: - 快速启动命令构建

    static func expandTilde(
        _ rawPath: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        if trimmed == "~" {
            return homeDirectory.path
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return homeDirectory.appendingPathComponent(suffix).path
        }
        return trimmed
    }

    static func buildQuickLaunchCommand(
        envFileURL: URL = defaultEnvFileURL(),
        directory: String?,
        model: String?,
        yoloEnabled: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var segments: [String] = []
        if let dir = expandTilde(directory, homeDirectory: homeDirectory) {
            segments.append("cd \(ShellPathEscaper.singleQuoted(dir))")
        }
        segments.append("source \(ShellPathEscaper.singleQuoted(envFileURL.path))")

        var geminiParts = ["gemini"]
        if yoloEnabled {
            geminiParts.append("-y")
        }
        if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedModel.isEmpty {
            geminiParts.append("-m \(ShellPathEscaper.singleQuoted(trimmedModel))")
        }
        segments.append(geminiParts.joined(separator: " "))
        return segments.joined(separator: " && ")
    }

    // MARK: - Keychain 存取

    static func loadFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToKeychain(apiKey: String) -> Bool {
        guard let key = sanitizeKey(apiKey),
              let data = key.data(using: .utf8) else { return false }
        deleteFromKeychain()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteFromKeychain() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Key 清洗

    static func sanitizeKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            return nil
        }
        return trimmed
    }
}
