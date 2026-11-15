import AppKit
import SwiftUI

/// Google 官方 API Key（AI Studio / Vertex AI Express）凭据、用量预算与 Gemini CLI 快速启动配置。
struct GoogleAPICredentialSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var preference: GoogleAPICredentialPreference = .automatic
    @State private var mode: GoogleAPIMode = .auto
    @State private var manualKeyInput: String = ""
    @State private var hasStoredKey: Bool = false

    @State private var dailyBudgetText: String = ""
    @State private var monthlyBudgetText: String = ""

    @State private var defaultDirectory: String = ""
    @State private var defaultModel: String = ""
    @State private var yoloEnabled: Bool = true
    @State private var hotKeyEnabled: Bool = true
    @State private var hotKeyPreset: GoogleAPIQuickHotKeyPreset = .ctrlOptG

    @State private var isSaving: Bool = false
    @State private var validationMessage: String?
    @State private var previewCopied: Bool = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    credentialSection
                    usageBudgetSection
                    quickLaunchSection
                }
                .padding(20)
            }

            Divider()
            footerBar
        }
        .frame(width: 500, height: 610)
        .onAppear(perform: loadInitialState)
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack {
            Text(tr("Google API & Quick Launch", "Google API 凭据与快速启动"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            Spacer()
            Button(tr("Cancel", "取消")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                saveAndDismiss()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(tr("Save & Apply", "保存并应用"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("API Key & Mode", "API Key 与接口模式"))
                .font(.system(size: 12.5, weight: .semibold))

            Picker(tr("Credential Source", "凭据来源"), selection: $preference) {
                Text(tr("Automatic", "自动读取（推荐）")).tag(GoogleAPICredentialPreference.automatic)
                Text(tr("Manual API Key", "手动 API Key")).tag(GoogleAPICredentialPreference.manual)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                if preference == .automatic {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.googleAPIAccount != nil ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        if let account = appState.googleAPIAccount {
                            Text(tr(
                                "Detected: \(account.source.displayName) · \(account.resolvedMode.displayLabel)",
                                "已检测到：\(account.source.displayName) · \(account.resolvedMode.displayLabel)"
                            ))
                            .font(.system(size: 11.5, weight: .medium))
                        } else {
                            Text(tr(
                                "No key found in ~/.gemini/.env, environment, or Keychain",
                                "未在 ~/.gemini/.env、环境变量或钥匙串检测到 Key"
                            ))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if preference == .manual || appState.googleAPIAccount == nil || hasStoredKey {
                    if hasStoredKey {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 12))
                            Text(tr("API Key saved in macOS Keychain", "Keychain 中已保存 API Key"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Remove", "清除")) {
                                GoogleAPIAuth.deleteFromKeychain()
                                hasStoredKey = false
                                manualKeyInput = ""
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        }
                    }

                    if preference == .manual || !hasStoredKey {
                        SecureField(
                            hasStoredKey
                                ? tr("Enter new API Key to replace", "输入新的 API Key 以替换")
                                : tr("Paste AI Studio (AIza…) or Vertex Express (AQ.…) API Key", "粘贴 AI Studio (AIza…) 或 Vertex Express (AQ.…) API Key"),
                            text: $manualKeyInput
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Text(tr("API Endpoint", "接口类型"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $mode) {
                        Text(tr("Auto-detect (Online probe, recommended)", "自动识别（联网探测，推荐）")).tag(GoogleAPIMode.auto)
                        Text("Google AI Studio").tag(GoogleAPIMode.aiStudio)
                        Text("Vertex AI Express").tag(GoogleAPIMode.vertexExpress)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Text(tr(
                    "Stored securely in macOS Keychain. Online validation uses zero-cost endpoints (models list / countTokens).",
                    "API Key 保存在 macOS 钥匙串中；联网状态检查使用零计费接口（models / countTokens）。"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private var usageBudgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Local Usage & Budgets (USD)", "本机用量监测与预算上限（USD）"))
                .font(.system(size: 12.5, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                let summary = appState.googleAPIUsageSummary ?? GoogleAPIUsageSummary()
                HStack(spacing: 14) {
                    statBadge(
                        title: tr("Today", "今日费用"),
                        value: formatUSD(summary.todayCostUSD),
                        detail: "\(formatTokens(summary.todayTokens)) tok"
                    )
                    Divider().frame(height: 28)
                    statBadge(
                        title: tr("This Month", "本月费用"),
                        value: formatUSD(summary.monthCostUSD),
                        detail: "\(formatTokens(summary.monthTokens)) tok"
                    )
                }

                Divider()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Daily Budget ($)", "每日预算 ($ USD)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField(tr("0 = Unlimited", "0 = 不设上限"), text: $dailyBudgetText)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Monthly Budget ($)", "每月预算 ($ USD)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField(tr("0 = Unlimited", "0 = 不设上限"), text: $monthlyBudgetText)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Text(tr(
                    "Scans ~/.gemini/tmp Gemini CLI logs on this Mac. Leave 0 for ∞; set >0 to show remaining % and enable low-budget alerts.",
                    "读取本机 ~/.gemini/tmp 中 Gemini CLI 对话日志估算费用。设为 0 显示 ∞ 不限；大于 0 时可展示剩余预算百分比并触发低额度提醒。"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private var quickLaunchSection: some View {
        let terminal = SettingsStore.shared.resumeTerminalApp
        let previewCommand = GoogleAPIAuth.buildQuickLaunchCommand(
            directory: defaultDirectory,
            model: defaultModel,
            yoloEnabled: yoloEnabled
        )
        let hasUnsavedManualInput = !manualKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canLaunchExistingSession = appState.googleAPIAccount != nil && !hasUnsavedManualInput

        return VStack(alignment: .leading, spacing: 10) {
            Text(tr("Gemini CLI Quick Launch", "Gemini CLI 快速启动与快捷键"))
                .font(.system(size: 12.5, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Toggle(tr("Global Shortcut", "全局快速启动快捷键"), isOn: $hotKeyEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.green)
                    Spacer()
                    Picker("", selection: $hotKeyPreset) {
                        ForEach(GoogleAPIQuickHotKeyPreset.allCases) { preset in
                            Text(preset.symbol).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!hotKeyEnabled)
                }

                HStack(spacing: 8) {
                    Text(tr("Working Dir", "默认目录"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    TextField(tr("Optional (e.g. ~/Projects)", "留空则在默认目录启动（支持 ~/...）"), text: $defaultDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button(tr("Browse…", "选择…")) {
                        chooseDirectory()
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Text(tr("Model", "默认模型"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    TextField(tr("Optional (e.g. gemini-3.1-pro-preview)", "留空按 CLI 默认（如 gemini-3.1-pro-preview）"), text: $defaultModel)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle(tr("Enable YOLO permission flag (-y)", "自动附加 -y（跳过工具权限确认）"), isOn: $yoloEnabled)
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Command Preview (raw API key stays in 0600 env file):", "启动命令预览（明文 Key 保存在 0600 环境文件中，不进入命令行）："))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(previewCommand)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                        .cornerRadius(6)

                    HStack(spacing: 8) {
                        Button(previewCopied ? tr("Copied", "已复制") : tr("Copy Command", "复制命令")) {
                            SessionActions.copy(previewCommand)
                            previewCopied = true
                            copyResetTask?.cancel()
                            copyResetTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                guard !Task.isCancelled else { return }
                                previewCopied = false
                            }
                        }
                        .controlSize(.small)

                        Button(tr("Test in \(terminal.displayName)", "在 \(terminal.displayName) 中测试启动")) {
                            if let session = appState.googleAPIAccount {
                                GoogleAPIAuth.syncLaunchEnvFile(session: session)
                                SessionActions.runShellCommandInTerminal(previewCommand)
                            }
                        }
                        .controlSize(.small)
                        .disabled(!canLaunchExistingSession)

                        if !canLaunchExistingSession {
                            Text(tr("Save Key first to test", "请先保存 Key 后测试启动"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Text(tr(
                    "Uses GEMINI_CLI_AUTH_OVERRIDE in memory; ~/.gemini/settings.json (e.g. OAuth) is untouched.",
                    "启动时通过 GEMINI_CLI_AUTH_OVERRIDE 临时覆盖鉴权模式，不改动 ~/.gemini/settings.json。"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    // MARK: - Helpers

    private func statBadge(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func loadInitialState() {
        let settings = SettingsStore.shared
        hasStoredKey = (GoogleAPIAuth.loadFromKeychain() != nil)
        if appState.googleAPIAccount == nil && !hasStoredKey && settings.googleAPICredentialPreference == .automatic {
            preference = .manual
        } else {
            preference = settings.googleAPICredentialPreference
        }
        mode = settings.googleAPIMode
        dailyBudgetText = settings.googleAPIDailyBudgetUSD > 0 ? formatBudgetInput(settings.googleAPIDailyBudgetUSD) : ""
        monthlyBudgetText = settings.googleAPIMonthlyBudgetUSD > 0 ? formatBudgetInput(settings.googleAPIMonthlyBudgetUSD) : ""
        defaultDirectory = settings.googleAPIDefaultDirectory
        defaultModel = settings.googleAPIDefaultModel
        yoloEnabled = settings.googleAPIYoloEnabled
        hotKeyEnabled = settings.googleAPIHotKeyEnabled
        hotKeyPreset = settings.googleAPIHotKeyPreset
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Select", "选择")
        if let expanded = GoogleAPIAuth.expandTilde(defaultDirectory) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            defaultDirectory = url.path
        }
    }

    private func parseBudget(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func formatBudgetInput(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func formatUSD(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d <= 0 { return "$0.00" }
        if d < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", d)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func candidateSessionForValidation(trimmedKey: String) -> GoogleAPIAuthSession? {
        let sanitizedInput = GoogleAPIAuth.sanitizeKey(trimmedKey)
        let manualKey = sanitizedInput ?? GoogleAPIAuth.sanitizeKey(GoogleAPIAuth.loadFromKeychain())

        let keyToValidate: String
        switch preference {
        case .manual:
            guard let manualKey else { return nil }
            keyToValidate = manualKey
        case .automatic:
            if let loaded = GoogleAPIAuth.load(preference: .automatic, mode: mode),
               loaded.source != .manualKeychain || sanitizedInput == nil {
                return loaded
            }
            guard let manualKey else { return nil }
            keyToValidate = manualKey
        }

        let cached = (mode == .auto) ? GoogleAPIAuth.cachedAutoResolvedMode(for: keyToValidate) : nil
        return GoogleAPIAuthSession(
            apiKey: keyToValidate,
            source: .manualKeychain,
            resolvedMode: mode.resolve(for: keyToValidate, cachedAutoMode: cached),
            configuredMode: mode
        )
    }

    private func saveAndDismiss() {
        validationMessage = nil
        guard let dailyBudget = parseBudget(dailyBudgetText),
              let monthlyBudget = parseBudget(monthlyBudgetText) else {
            validationMessage = tr("Budget must be a non-negative number (leave blank or 0 for unlimited).", "预算需为非负数字（留空或填 0 表示不设上限）")
            return
        }

        let trimmedKey = manualKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty, GoogleAPIAuth.sanitizeKey(trimmedKey) == nil {
            validationMessage = tr("Invalid API Key format (must be at least 16 visible ASCII characters).", "API Key 格式无效（至少 16 个可见 ASCII 字符且不含空格）")
            return
        }

        isSaving = true
        Task {
            if let candidate = candidateSessionForValidation(trimmedKey: trimmedKey) {
                let check = await GoogleAPIQuotaClient.validateKey(session: candidate)
                switch check {
                case .success(let actualMode):
                    if mode == .auto {
                        GoogleAPIAuth.rememberAutoResolvedMode(actualMode, for: candidate.apiKey)
                    }
                case .failure(let error) where !error.isNetworkFailure:
                    isSaving = false
                    validationMessage = appState.googleAPIAuthFailureMessage(
                        error,
                        mode: candidate.resolvedMode,
                        configuredMode: mode
                    )
                    return
                case .failure:
                    break
                }
            }

            let settings = SettingsStore.shared
            settings.googleAPICredentialPreference = preference
            settings.googleAPIMode = mode
            settings.googleAPIDailyBudgetUSD = dailyBudget
            settings.googleAPIMonthlyBudgetUSD = monthlyBudget
            settings.googleAPIDefaultDirectory = defaultDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.googleAPIDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.googleAPIYoloEnabled = yoloEnabled
            settings.googleAPIHotKeyEnabled = hotKeyEnabled
            settings.googleAPIHotKeyPreset = hotKeyPreset

            if !trimmedKey.isEmpty {
                GoogleAPIAuth.saveToKeychain(apiKey: trimmedKey)
            }

            await appState.loadGoogleAPI()
            if appState.googleAPIAccount != nil, !settings.isProviderEnabled(.googleAPI) {
                settings.setServiceEnabled(true, for: .googleAPI)
            }
            if settings.isProviderEnabled(.googleAPI) {
                await appState.refreshQuotas(reason: .userInitiated)
            }
            await appState.refreshGoogleAPILocalUsageIfNeeded()
            isSaving = false
            dismiss()
        }
    }
}
