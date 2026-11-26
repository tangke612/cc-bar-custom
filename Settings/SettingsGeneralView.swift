import AppKit
import SwiftUI

// MARK: - General & About View

struct SettingsGeneralView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore
    let updater: AppUpdater
    let highlightedSection: String?
    @Binding var launchAtLoginMessage: String?
    @Binding var launchAtLoginMessageIsError: Bool
    @Binding var isExportingDiagnostics: Bool
    @Binding var diagnosticsMessage: String?
    @Binding var diagnosticsMessageIsError: Bool
    @Binding var showDiagnosticsConfirm: Bool

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .general)

            // 版本与更新
            aboutHeroCard

            // 系统偏好
            SettingsCard(
                title: "System",
                chinese: "系统偏好",
                isHighlighted: highlightedSection == "general-system"
            ) {
                SettingsRow(
                    label: "Language",
                    chinese: "界面语言",
                    desc: "Choose the display language for menus, statistics and settings.",
                    chineseDesc: "切换菜单栏、统计与设置界面的显示语言"
                ) {
                    Picker("", selection: $settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: SettingsLayout.languagePickerWidth)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Launch at login",
                    chinese: "开机自动启动",
                    desc: "Start CCBar automatically when you log in to your Mac.",
                    chineseDesc: "登录 macOS 时自动在后台启动 CCBar",
                    detail: launchAtLoginDetail
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { newValue in
                            do {
                                try settings.setLaunchAtLogin(newValue)
                                if settings.launchAtLoginRequiresApproval {
                                    launchAtLoginMessage = launchAtLoginApprovalMessage
                                    launchAtLoginMessageIsError = false
                                } else {
                                    launchAtLoginMessage = nil
                                }
                            } catch {
                                settings.syncLaunchAtLoginStatus()
                                launchAtLoginMessage = launchAtLoginErrorMessage(error)
                                launchAtLoginMessageIsError = true
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                }
            }

            // 多设备云同步
            cloudSyncCard(settings: settings)

            // 诊断与日志
            SettingsCard(
                title: "Diagnostics",
                chinese: "诊断与日志",
                isHighlighted: highlightedSection == "general-diagnostics"
            ) {
                SettingsRow(
                    label: "Export diagnostics",
                    chinese: "导出诊断日志",
                    desc: "Creates a local redacted zip archive for reporting issues. Nothing is uploaded automatically.",
                    chineseDesc: "在本机生成脱敏的 zip 诊断包用于反馈问题，不会自动上传"
                ) {
                    HStack(spacing: 8) {
                        if let diagnosticsMessage {
                            Text(diagnosticsMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    diagnosticsMessageIsError
                                        ? SettingsSemanticTone.danger.foreground
                                        : SettingsSemanticTone.success.foreground
                                )
                        }
                        Button {
                            showDiagnosticsConfirm = true
                        } label: {
                            if isExportingDiagnostics {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(tr("Export…", "导出…"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExportingDiagnostics)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    label: "Reveal log folder",
                    chinese: "打开日志目录",
                    desc: "~/Library/Logs/CCBar",
                    chineseDesc: "~/Library/Logs/CCBar"
                ) {
                    Button(tr("Open in Finder", "在 Finder 中打开")) {
                        DiagnosticsBundle.revealLogDirectory()
                    }
                    .buttonStyle(.bordered)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Verbose logging",
                    chinese: "详细日志",
                    desc: "Turn on while troubleshooting an issue, then turn off to keep logs compact.",
                    chineseDesc: "排查问题时开启，排查完成后建议关闭"
                ) {
                    Toggle("", isOn: $settings.verboseLogging)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }
        }
    }

    // MARK: - About Hero & Updates Card

    private var aboutHeroCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9.5, style: .continuous))

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("CCBar")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("v\(appVersion)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if updater.hasUpdate {
                            Text("· \(tr("Update available", "有新版本"))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(tr("Last checked:", "上次检查："))
                            .foregroundStyle(.secondary)
                        if let date = updater.lastCheckedAt {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }

                Spacer()

                if updater.hasUpdate {
                    Button(updateButtonTitle) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(updateButtonTitle) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
            .padding(.vertical, 15)

            SettingsDivider()

            SettingsRow(
                label: "Automatically check for updates",
                chinese: "自动检查更新",
                desc: "Periodically check GitHub releases for newer CCBar builds.",
                chineseDesc: "定期在后台检查 CCBar 新版本"
            ) {
                Toggle("", isOn: Binding(
                    get: { updater.automaticChecks },
                    set: { updater.setAutomaticChecks($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
        }
        .ccPanel(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(highlightedSection == "general-updates" ? 0.65 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.25), value: highlightedSection)
        )
    }

    // MARK: - Multi-Device Cloud Sync

    private func cloudSyncCard(settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        let folderHint = cloudSyncFolderDescription(settings: settings)
        return SettingsCard(
            title: "Multi-Device Cloud Sync",
            chinese: "多设备云同步",
            desc: "Sync conversation summaries and token billing across Macs via conflict-free per-device shards. Raw logs and credentials stay local.",
            chineseDesc: "按设备独立分片同步对话列表摘要与 Token 账单，原始日志与账号凭据绝不上传",
            isHighlighted: highlightedSection == "general-cloud-sync"
        ) {
            SettingsRow(
                label: "Sync conversations & billing",
                chinese: "同步对话摘要与账单",
                desc: "Each Mac writes only its own shard file and merges other Macs in memory.",
                chineseDesc: "每台 Mac 仅写入自身分片文件，读取合并其他设备数据，零写锁冲突"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.cloudSyncEnabled },
                    set: { enabled in
                        settings.cloudSyncEnabled = enabled
                        if enabled {
                            Task { await appState.cloudSync.syncNow(appState: appState) }
                        } else {
                            appState.cloudSync.disableAndClearOverlay(appState: appState)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }

            if settings.cloudSyncEnabled {
                SettingsDivider()
                SettingsRow(
                    label: "Sync folder",
                    chinese: "同步目录",
                    desc: folderHint,
                    chineseDesc: folderHint
                ) {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { settings.cloudSyncDirectoryMode },
                            set: { mode in
                                settings.cloudSyncDirectoryMode = mode
                                if mode == .custom && settings.cloudSyncCustomDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    chooseCloudSyncDirectory(settings: settings)
                                } else {
                                    Task { await appState.cloudSync.syncNow(appState: appState) }
                                }
                            }
                        )) {
                            Text("iCloud Drive").tag(CloudSyncDirectoryMode.icloudDrive)
                            Text(tr("Custom folder", "自定义目录")).tag(CloudSyncDirectoryMode.custom)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()

                        if settings.cloudSyncDirectoryMode == .custom {
                            Button(tr("Choose…", "选择…")) {
                                chooseCloudSyncDirectory(settings: settings)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if let url = settings.resolvedCloudSyncDirectoryURL {
                            Button {
                                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(tr("Open sync folder in Finder", "在访达中打开同步目录"))
                        }
                    }
                }

                SettingsDivider()
                SettingsRow(
                    label: "This Mac's name",
                    chinese: "本机名称",
                    desc: "Displayed as the source badge on your other Macs.",
                    chineseDesc: "在其他设备上标识仅在本机产生的对话来源"
                ) {
                    TextField(
                        SettingsStore.defaultCloudSyncDeviceName,
                        text: $settings.cloudSyncDeviceName
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit {
                        Task { await appState.cloudSync.syncNow(appState: appState) }
                    }
                }

                SettingsDivider()
                SettingsRow(
                    label: "Sync status",
                    chinese: "同步状态",
                    detail: cloudSyncStatusDetail
                ) {
                    Button {
                        Task { await appState.cloudSync.syncNow(appState: appState) }
                    } label: {
                        if appState.cloudSync.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(tr("Sync Now", "立即同步"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.cloudSync.isSyncing)
                }

                if !appState.cloudSync.peerStatuses.isEmpty {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Synced Macs", "已发现的其他设备"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(appState.cloudSync.peerStatuses) { peer in
                            HStack(spacing: 8) {
                                Image(systemName: peer.isDownloadingFromICloud ? "icloud.and.arrow.down" : "laptopcomputer")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(PrivacyDisplay.isEnabled ? tr("Other Mac", "其他设备") : peer.deviceName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                if peer.isDownloadingFromICloud && peer.conversationCount == 0 {
                                    Text(tr("Downloading from iCloud…", "正在从 iCloud 下载…"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text(
                                        tr(
                                            "\(peer.conversationCount) conversations · \(StatsFormatter.day(peer.exportedAt)) \(StatsFormatter.time(peer.exportedAt))",
                                            "\(peer.conversationCount) 条对话 · \(StatsFormatter.day(peer.exportedAt)) \(StatsFormatter.time(peer.exportedAt))"
                                        )
                                    )
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                }
                                Button {
                                    Task {
                                        await appState.cloudSync.removePeerShard(
                                            deviceID: peer.deviceID,
                                            appState: appState
                                        )
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(tr("Remove this retired device's shard file", "移除该旧设备的同步分片文件"))
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, SettingsLayout.cardHorizontalPadding)
                }
            }
        }
    }

    private func cloudSyncFolderDescription(settings: SettingsStore) -> String? {
        if PrivacyDisplay.isEnabled { return nil }
        switch settings.cloudSyncDirectoryMode {
        case .icloudDrive:
            return "~/Library/Mobile Documents/com~apple~CloudDocs/CCBarSync"
        case .custom:
            let trimmed = settings.cloudSyncCustomDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? tr("No folder selected", "尚未选择同步目录")
                : CloudSyncMerger.portablePath(trimmed, homePath: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        }
    }

    private var cloudSyncStatusDetail: AnyView? {
        if let err = appState.cloudSync.lastError, !err.isEmpty {
            return AnyView(
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsSemanticTone.danger.foreground)
            )
        }
        if let syncedAt = appState.cloudSync.lastSyncedAt {
            let peerCount = appState.cloudSync.peerStatuses.count
            let summary = peerCount == 0
                ? tr(
                    "Last synced \(StatsFormatter.time(syncedAt)) · Turn on Cloud Sync on another Mac using the same iCloud Drive / folder",
                    "上次同步 \(StatsFormatter.time(syncedAt)) · 在另一台 Mac 开启相同目录的云同步即可自动汇合"
                )
                : tr(
                    "Last synced \(StatsFormatter.time(syncedAt)) · \(peerCount) other Mac(s) merged",
                    "上次同步 \(StatsFormatter.time(syncedAt)) · 已合并 \(peerCount) 台其他设备"
                )
            return AnyView(
                Text(summary)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            )
        }
        return nil
    }

    private func chooseCloudSyncDirectory(settings: SettingsStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Select Sync Folder", "选择同步目录")
        if panel.runModal() == .OK, let url = panel.url {
            settings.cloudSyncCustomDirectory = url.standardizedFileURL.path
            settings.cloudSyncDirectoryMode = .custom
            Task { await appState.cloudSync.syncNow(appState: appState) }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var updateButtonTitle: String {
        updater.hasUpdate || updater.isWorking
            ? tr("View Update", "查看更新")
            : tr("Check for Updates", "检查更新")
    }

    private var launchAtLoginApprovalMessage: String {
        tr(
            "Approve CCBar in System Settings > General > Login Items & Extensions.",
            "请在「系统设置 > 通用 > 登录项与扩展」中允许 CCBar。"
        )
    }

    private func launchAtLoginErrorMessage(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
        if description.localizedCaseInsensitiveContains("operation not permitted") {
            return tr(
                "macOS rejected this change. Export a signed CCBar.app, move it to /Applications, launch it there, then try again.",
                "macOS 拒绝了这次更改。请导出签名后的 CCBar.app，拖到 /Applications 后从那里启动，再重试。"
            )
        }
        return description
    }

    private var launchAtLoginDetail: AnyView? {
        guard let launchAtLoginMessage else { return nil }
        return AnyView(
            Text(launchAtLoginMessageIsError ? PrivacyDisplay.error(launchAtLoginMessage) : launchAtLoginMessage)
                .font(.system(size: 11))
                .foregroundStyle(launchAtLoginMessageIsError ? SettingsSemanticTone.danger.foreground : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        )
    }
}
