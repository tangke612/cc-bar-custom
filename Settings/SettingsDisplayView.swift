import SwiftUI

// MARK: - Display & Privacy View

struct SettingsDisplayView: View {
    let settings: SettingsStore
    let highlightedSection: String?
    let onNavigateToServices: () -> Void
    let onShowGoogleAPISheet: () -> Void

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsPageHeader(category: .display)

            // 主题外观
            SettingsCard(
                title: "Theme",
                chinese: "主题外观",
                isHighlighted: highlightedSection == "display-theme"
            ) {
                SettingsRow(
                    label: "Appearance",
                    chinese: "界面外观",
                    desc: "Applies to the hover panel, floating HUD, and main window while keeping the menu bar icon matched to macOS.",
                    chineseDesc: "作用于悬停面板、桌面悬浮窗与主窗口，菜单栏图标仍自动适配系统顶栏"
                ) {
                    Picker("", selection: $settings.appAppearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(tr(mode.englishTitle, mode.chineseTitle)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .id("display-theme")

            // 菜单栏
            SettingsCard(
                title: "Menu Bar",
                chinese: "菜单栏",
                isHighlighted: highlightedSection == "display-menubar"
            ) {
                SettingsRow(
                    label: "Quota period",
                    chinese: "额度周期",
                    desc: "Choose which quota window appears alongside agent icons in the menu bar.",
                    chineseDesc: "选择菜单栏图标旁展示的额度窗口"
                ) {
                    Picker("", selection: $settings.menuBarWindow) {
                        Text(tr("Main", "主额度")).tag(MenuBarWindowChoice.primary)
                        Text(tr("Weekly", "周额度")).tag(MenuBarWindowChoice.weekly)
                        Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .id("display-menubar")

            // 弹出面板
            SettingsCard(
                title: "Popover",
                chinese: "弹出面板",
                isHighlighted: highlightedSection == "display-popover"
            ) {
                SettingsRow(
                    label: "Official status dot",
                    chinese: "官方状态圆点",
                    desc: "Show live operational status indicators next to agent names.",
                    chineseDesc: "在 Agent 名称旁显示官方运行状态圆点"
                ) {
                    Toggle("", isOn: $settings.showServiceStatus)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Recent conversations",
                    chinese: "最近对话",
                    desc: "Conversations active today, sorted by most recent activity.",
                    chineseDesc: "今天有活动的对话，按最近活动时间排序"
                ) {
                    HStack(spacing: 10) {
                        if settings.showRecentConversations {
                            Picker("", selection: $settings.recentConversationLimit) {
                                ForEach(Array(SettingsStore.recentConversationLimitRange), id: \.self) { count in
                                    Text(tr("\(count)", "\(count) 条")).tag(count)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: SettingsLayout.compactMenuPickerWidth)
                            .help(tr("Maximum shown", "最多显示条数"))
                        }
                        Toggle("", isOn: $settings.showRecentConversations)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    label: "Show email in popover",
                    chinese: "弹出面板显示邮箱",
                    desc: "Always hidden while privacy mode is enabled.",
                    chineseDesc: "开启隐私模式时始终隐藏"
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.popoverShowsEmail && !settings.privacyMode },
                        set: { settings.popoverShowsEmail = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(settings.privacyMode)
                }
            }
            .id("display-popover")

            // 悬停面板与会话恢复
            SettingsCard(
                title: "Hover Panel & Resume",
                chinese: "悬停面板与会话恢复",
                isHighlighted: highlightedSection == "display-hover-resume"
            ) {
                SettingsRow(
                    label: "Open on hover",
                    chinese: "悬停自动弹出",
                    desc: "Hover the menu bar icon to open the panel without stealing focus.",
                    chineseDesc: "鼠标停在菜单栏图标上即弹出面板，不抢终端焦点"
                ) {
                    HStack(spacing: 8) {
                        if settings.popoverHoverOpenEnabled {
                            Picker("", selection: $settings.popoverHoverOpenDelayMs) {
                                ForEach(SettingsStore.popoverHoverOpenDelayChoices, id: \.self) { ms in
                                    Text(ms == 0 ? tr("Instant", "立即") : "\(ms) ms").tag(ms)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help(tr("Hover delay", "悬停延迟"))
                        }
                        Toggle("", isOn: $settings.popoverHoverOpenEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    label: "Auto-close after leaving",
                    chinese: "移开后自动收起",
                    desc: "Close when the pointer leaves the icon and panel. Pinned panels stay open.",
                    chineseDesc: "鼠标离开图标和面板后自动收起；点图钉固定的面板不收起"
                ) {
                    Picker("", selection: $settings.popoverAutoCloseDelayMs) {
                        ForEach(SettingsStore.popoverAutoCloseDelayChoices, id: \.self) { ms in
                            Text("\(ms) ms").tag(ms)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(
                    label: "Clicking the icon pins the panel",
                    chinese: "点击图标即固定面板",
                    desc: "Off: clicking opens a panel that still auto-closes.",
                    chineseDesc: "关闭时，点击打开的面板同样会在移开后自动收起"
                ) {
                    Toggle("", isOn: $settings.popoverClickPins)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Global shortcut ⌃⌥K",
                    chinese: "全局快捷键 ⌃⌥K",
                    desc: "Open the panel and focus session search from anywhere.",
                    chineseDesc: "在任意位置打开面板并聚焦会话搜索"
                ) {
                    Toggle("", isOn: $settings.quickPanelHotKeyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }

                SettingsDivider()

                SettingsRow(
                    label: "Gemini CLI quick launch",
                    chinese: "Google API 快速启动快捷键",
                    desc: "Launch Gemini CLI with your Google API key in terminal from anywhere.",
                    chineseDesc: "在任意位置按下快捷键打开终端并用 Google API Key 启动 gemini"
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: $settings.googleAPIHotKeyPreset) {
                            ForEach(GoogleAPIQuickHotKeyPreset.allCases) { preset in
                                Text(preset.symbol).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(!settings.googleAPIHotKeyEnabled)

                        Button(tr("Configure…", "配置…")) {
                            onShowGoogleAPISheet()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Toggle("", isOn: $settings.googleAPIHotKeyEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    label: "Resume permissions",
                    chinese: "恢复命令权限",
                    desc: "Inherit: reuse the original session's approval / sandbox / YOLO flags.",
                    chineseDesc: "继承：沿用原会话的审批、沙箱与 YOLO（跳过权限确认）参数"
                ) {
                    Picker("", selection: $settings.resumePermissionMode) {
                        Text(tr("Inherit original", "继承原会话")).tag(ResumePermissionMode.inherit)
                        Text(tr("Always full access (YOLO)", "始终完全放行（YOLO）")).tag(ResumePermissionMode.fullAccess)
                        Text(tr("CLI defaults", "不附加（按 CLI 默认）")).tag(ResumePermissionMode.standard)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(
                    label: "Terminal for “Resume in…”",
                    chinese: "「在终端中恢复」使用",
                    desc: "Used by the right-click menu on session rows.",
                    chineseDesc: "会话行右键菜单中的「在终端中恢复」"
                ) {
                    Picker("", selection: $settings.resumeTerminalApp) {
                        ForEach(ResumeTerminalApp.allCases) { app in
                            Text(app.displayName).tag(app)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .id("display-hover-resume")

            // 桌面悬浮窗
            SettingsCard(
                title: "Floating HUD",
                chinese: "桌面悬浮窗",
                isHighlighted: highlightedSection == "display-floating"
            ) {
                SettingsRow(
                    label: "Show floating window",
                    chinese: "显示桌面悬浮窗",
                    desc: "Keep an always-on-top mini quota bar visible on your desktop.",
                    chineseDesc: "在桌面置顶显示精简额度条，具体显示哪些 Agent 可在「Agent 与账号」中勾选"
                ) {
                    HStack(spacing: 10) {
                        Button(tr("Manage Agents", "管理 Agent")) {
                            onNavigateToServices()
                        }
                        .buttonStyle(.bordered)
                        .focusEffectDisabled()

                        Toggle("", isOn: Binding(
                            get: { settings.floatingEnabled },
                            set: { newValue in
                                settings.floatingEnabled = newValue
                                FloatingPanelController.shared.sync()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                    }
                }
            }
            .id("display-floating")

            // 时间与隐私
            SettingsCard(
                title: "Time & Privacy",
                chinese: "时间与隐私",
                isHighlighted: highlightedSection == "display-privacy"
            ) {
                SettingsRow(
                    label: "Reset time format",
                    chinese: "重置时间格式",
                    desc: "Hovering any reset label still reveals the alternate format.",
                    chineseDesc: "悬停任意重置时间标签时仍可查看另一种格式"
                ) {
                    Picker("", selection: $settings.resetTimeDisplay) {
                        Text(tr("Remaining", "剩余时长")).tag(ResetTimeDisplay.relative)
                        Text(tr("Exact time", "具体时间")).tag(ResetTimeDisplay.absolute)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(
                    label: "Privacy mode",
                    chinese: "隐私模式",
                    desc: "Hide account emails, project names and conversation titles for screenshots. Usage numbers remain visible.",
                    chineseDesc: "隐藏账号邮箱、项目名和对话标题，用量数字照常显示，方便截图分享"
                ) {
                    Toggle("", isOn: $settings.privacyMode)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.green)
                }
            }
            .id("display-privacy")
        }
    }
}

