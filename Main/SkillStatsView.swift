import AppKit
import SwiftUI

// MARK: - Top bar status

struct SkillScanStatus: View {
    let count: Int
    let isScanning: Bool
    let isEmpty: Bool
    let lastScanAt: Date?

    @ViewBuilder
    var body: some View {
        if isScanning && isEmpty {
            Text(tr("Scanning local skills…", "正在扫描本机技能…"))
                .foregroundStyle(.secondary)
        } else if let lastScanAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(tr(
                    "\(count) skills · Updated \(relativeAge(lastScanAt, now: context.date)) ago",
                    "\(count) 个技能 · \(relativeAge(lastScanAt, now: context.date)) 前更新"
                ))
                .foregroundStyle(.secondary)
            }
        } else {
            Text(tr("\(count) skills", "\(count) 个技能"))
                .foregroundStyle(.secondary)
        }
    }

    private func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

// MARK: - SkillStatsView

struct SkillStatsView: View {
    @Environment(AppState.self) private var appState
    let serviceFilter: StatsServiceFilter

    @State private var search = ""
    @State private var selection: String?

    private var scopeFilter: LocalSkillScopeFilter {
        get { appState.mainWindowSession.skillScopeFilter }
        nonmutating set { appState.mainWindowSession.skillScopeFilter = newValue }
    }

    private var sourceFilter: String? {
        get { appState.mainWindowSession.skillSourceFilter }
        nonmutating set { appState.mainWindowSession.skillSourceFilter = newValue }
    }

    private var sort: LocalSkillSort {
        get { appState.mainWindowSession.skillSort }
        nonmutating set { appState.mainWindowSession.skillSort = newValue }
    }

    var body: some View {
        let state = filteredState
        VStack(spacing: 0) {
            HSplitView {
                skillListPane(state)
                    .frame(
                        minWidth: StatsSplitMetrics.listMinWidth,
                        idealWidth: StatsSplitMetrics.listWidth,
                        maxWidth: StatsSplitMetrics.listWidth,
                        maxHeight: .infinity,
                        alignment: .top
                    )

                detailPane(state)
                    .frame(
                        minWidth: StatsSplitMetrics.detailMinWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            appState.localSkills.refreshInBackground(minAge: 5.0)
        }
        .onAppear {
            reconcileSourceFilter(availableGroupIDs: state.availableGroupIDs)
            reconcileSelection(rows: state.rows)
        }
        .onChange(of: serviceFilter) { _, _ in
            if serviceFilter != .all, sourceFilter != nil {
                sourceFilter = nil
            }
            reconcileSelection(rows: filteredState.rows)
        }
        .onChange(of: scopeFilter) { _, _ in
            reconcileSelection(rows: filteredState.rows)
        }
        .onChange(of: sourceFilter) { _, _ in
            reconcileSelection(rows: filteredState.rows)
        }
        .onChange(of: sort) { _, _ in
            reconcileSelection(rows: filteredState.rows)
        }
        .onChange(of: search) { _, _ in
            reconcileSelection(rows: filteredState.rows)
        }
        .onChange(of: appState.localSkills.revision) { _, _ in
            let current = filteredState
            reconcileSourceFilter(availableGroupIDs: current.availableGroupIDs)
            reconcileSelection(rows: current.rows)
        }
    }

    // MARK: Filtering & Sorting

    private struct FilteredSkillsState {
        let serviceMatchedCount: Int
        let availableGroupIDs: [String]
        let groupCounts: [String: Int]
        let rows: [LocalSkillRecord]
    }

    private var filteredState: FilteredSkillsState {
        let allSkills = appState.localSkills.skills
        let targetApp = serviceFilter.usageApp
        let serviceScoped = allSkills.filter { $0.matches(usageApp: targetApp) }

        var counts: [String: Int] = [:]
        for skill in serviceScoped {
            counts[skill.sourceKind.sourceGroupID, default: 0] += 1
        }
        let orderedGroups = LocalSkillSourceKind.orderedGroupIDs.filter { (counts[$0] ?? 0) > 0 }

        let activeSourceFilter: String? = (serviceFilter == .all) ? sourceFilter : nil
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var rows = serviceScoped.filter { skill in
            switch scopeFilter {
            case .all:
                break
            case .user:
                if skill.isBuiltin { return false }
            case .builtin:
                if !skill.isBuiltin { return false }
            }
            if let activeSourceFilter, skill.sourceKind.sourceGroupID != activeSourceFilter {
                return false
            }
            return skill.matches(lowercasedQuery: query)
        }

        rows.sort { lhs, rhs in
            switch sort {
            case .name:
                if lhs.isBuiltin != rhs.isBuiltin { return !lhs.isBuiltin }
                let cmp = lhs.name.localizedStandardCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            case .recent:
                let lDate = lhs.modifiedAt ?? .distantPast
                let rDate = rhs.modifiedAt ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .source:
                let lOrder = LocalSkillSourceKind.orderedGroupIDs.firstIndex(of: lhs.sourceKind.sourceGroupID) ?? .max
                let rOrder = LocalSkillSourceKind.orderedGroupIDs.firstIndex(of: rhs.sourceKind.sourceGroupID) ?? .max
                if lOrder != rOrder { return lOrder < rOrder }
                if lhs.isBuiltin != rhs.isBuiltin { return !lhs.isBuiltin }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        return FilteredSkillsState(
            serviceMatchedCount: serviceScoped.count,
            availableGroupIDs: orderedGroups,
            groupCounts: counts,
            rows: rows
        )
    }

    private func reconcileSourceFilter(availableGroupIDs: [String]) {
        if serviceFilter != .all {
            if sourceFilter != nil { sourceFilter = nil }
            return
        }
        if let sourceFilter, !availableGroupIDs.contains(sourceFilter) {
            self.sourceFilter = nil
        }
    }

    private func reconcileSelection(rows: [LocalSkillRecord]) {
        if let selection, rows.contains(where: { $0.id == selection }) { return }
        selection = rows.first?.id
    }

    // MARK: List Pane

    private func skillListPane(_ state: FilteredSkillsState) -> some View {
        let rows = state.rows
        return VStack(spacing: 0) {
            filterHeader(state)

            if appState.localSkills.isScanning && appState.localSkills.skills.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text(tr("Scanning local skills…", "正在扫描本机技能…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                StatsListEmptyState(
                    systemImage: "puzzlepiece.extension",
                    title: tr("No skills found", "未找到技能"),
                    message: emptyStateMessage(serviceMatchedCount: state.serviceMatchedCount)
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    tr("No matching skills", "没有匹配的技能"),
                    systemImage: "magnifyingglass",
                    description: Text(tr("Try another keyword or clear filters.", "请换一个关键词或放宽筛选条件。"))
                )
            } else {
                let lowerQuery = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                StatsSelectionList(items: rows, selection: $selection) { skill in
                    SkillListRow(skill: skill, lowercasedSearch: lowerQuery)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func filterHeader(_ state: FilteredSkillsState) -> some View {
        @Bindable var session = appState.mainWindowSession
        return VStack(spacing: 6) {
            StatsSearchField(
                prompt: tr("Search skill name, description or path", "搜索技能名称、说明或路径"),
                text: $search
            )

            HStack(spacing: 6) {
                StatsFilterMenu(
                    items: LocalSkillScopeFilter.allCases,
                    label: { $0.label },
                    selection: $session.skillScopeFilter
                )

                if serviceFilter == .all, state.availableGroupIDs.count > 1 {
                    sourceFilterMenu(state)
                }

                Spacer(minLength: 0)

                StatsFilterMenu(
                    items: LocalSkillSort.allCases,
                    label: { $0.label },
                    selection: $session.skillSort
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func sourceFilterMenu(_ state: FilteredSkillsState) -> some View {
        let activeGroup = sourceFilter.flatMap { state.availableGroupIDs.contains($0) ? $0 : nil }
        let title = activeGroup.map { LocalSkillSourceKind.sourceGroupLabel(for: $0) }
            ?? tr("All sources", "全部来源")

        return Menu {
            Button {
                sourceFilter = nil
            } label: {
                menuItemLabel(
                    title: tr("All sources", "全部来源"),
                    count: state.serviceMatchedCount,
                    selected: activeGroup == nil
                )
            }

            Divider()

            ForEach(state.availableGroupIDs, id: \.self) { groupID in
                Button {
                    sourceFilter = groupID
                } label: {
                    menuItemLabel(
                        title: LocalSkillSourceKind.sourceGroupLabel(for: groupID),
                        count: state.groupCounts[groupID] ?? 0,
                        selected: activeGroup == groupID
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .help(tr("Filter skills by source directory", "按来源目录筛选技能"))
    }

    private func menuItemLabel(title: String, count: Int, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func emptyStateMessage(serviceMatchedCount: Int) -> String {
        if serviceMatchedCount > 0 {
            return tr(
                "No skills match the current type or source filter.",
                "当前类型或来源筛选下没有技能，可切换为「全部类型」或「全部来源」。"
            )
        }
        if let app = serviceFilter.usageApp {
            return tr(
                "No local skill folders containing SKILL.md were detected for \(app.displayName).",
                "未在本机检测到适用于 \(app.displayName) 的 SKILL.md 技能目录。"
            )
        }
        return tr(
            "CCBar scans standard skill directories such as ~/.agents/skills, ~/.codex/skills, ~/.claude/skills and ~/.gemini/skills.",
            "CCBar 会只读扫描 ~/.agents/skills、~/.codex/skills、~/.claude/skills、~/.gemini/skills 等本机技能目录。"
        )
    }

    // MARK: Detail Pane

    @ViewBuilder
    private func detailPane(_ state: FilteredSkillsState) -> some View {
        if let selection,
           let skill = state.rows.first(where: { $0.id == selection }) {
            SkillDetailPane(
                skill: skill,
                siblings: appState.localSkills.siblings(of: skill),
                onSelectSibling: { target in
                    selectSibling(target)
                }
            )
        } else {
            Text(state.rows.isEmpty ? "" : tr("Select a skill", "选择技能查看详情"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectSibling(_ target: LocalSkillRecord) {
        if serviceFilter != .all && !target.matches(usageApp: serviceFilter.usageApp) {
            appState.mainWindowSession.serviceFilter = .all
        }
        if let sourceFilter, sourceFilter != target.sourceKind.sourceGroupID {
            self.sourceFilter = nil
        }
        if (scopeFilter == .user && target.isBuiltin) || (scopeFilter == .builtin && !target.isBuiltin) {
            scopeFilter = .all
        }
        if !search.isEmpty {
            search = ""
        }
        selection = target.id
    }
}

// MARK: - Source Icon

private struct SkillSourceIcon: View {
    let sourceKind: LocalSkillSourceKind
    var size: CGFloat = 14

    var body: some View {
        if let app = sourceKind.primaryApp {
            ServiceTile(app: app, size: size)
        } else {
            Image(systemName: sourceKind.fallbackSymbol)
                .font(.system(size: (size * 0.62).rounded(), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
        }
    }
}

// MARK: - List Row

private struct SkillListRow: View {
    let skill: LocalSkillRecord
    let lowercasedSearch: String

    private var searchHighlight: String {
        PrivacyDisplay.isEnabled ? "" : lowercasedSearch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SkillSourceIcon(sourceKind: skill.sourceKind, size: 14)

                HighlightedText(text: skill.name, query: searchHighlight)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if skill.isSymlink {
                    Image(systemName: "link")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .help(tr("Symbolic link", "软链接"))
                }

                if skill.isBuiltin {
                    rowBadge(tr("Built-in", "内置"))
                }

                rowBadge(skill.sourceKind.sourceBadgeLabel)
            }

            if !skill.description.isEmpty {
                HighlightedText(text: skill.description, query: searchHighlight)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                PrivacySensitiveText(text: skill.displayPath, kind: .path, sensitive: true)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if let modifiedAt = skill.modifiedAt {
                    Text(Self.shortDateFormatter.string(from: modifiedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            SkillContextMenuItems(skill: skill)
        }
    }

    private func rowBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Context Menu

private struct SkillContextMenuItems: View {
    let skill: LocalSkillRecord

    var body: some View {
        if !PrivacyDisplay.isEnabled {
            Button(tr("Show in Finder", "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.skillFilePath)])
            }
            Button(tr("Open SKILL.md", "打开 SKILL.md")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: skill.skillFilePath))
            }

            Divider()
        }

        Button(tr("Copy Skill Name", "复制技能名称")) {
            SessionActions.copy(skill.name)
        }

        if !PrivacyDisplay.isEnabled {
            Button(tr("Copy Directory Path", "复制目录路径")) {
                SessionActions.copy(skill.directoryPath)
            }

            let editors = SessionActions.installedEditors
            if !editors.isEmpty {
                Divider()
                ForEach(editors) { editor in
                    Button(tr("Open Folder in \(editor.name)", "用 \(editor.name) 打开目录")) {
                        SessionActions.open(skill.directoryPath, with: editor)
                    }
                }
            }
        }
    }
}

// MARK: - Detail Pane

private struct SkillDetailPane: View {
    let skill: LocalSkillRecord
    let siblings: [LocalSkillRecord]
    let onSelectSibling: (LocalSkillRecord) -> Void

    @State private var copiedPath = false
    @State private var resetCopyTask: Task<Void, Never>?
    @State private var showRawSource = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                descriptionPanel
                metadataAndResourcesPanel

                if !siblings.isEmpty {
                    otherLocationsPanel
                }

                instructionsPanel
            }
            .padding(20)
        }
        .onChange(of: skill.id) { _, _ in
            copiedPath = false
            resetCopyTask?.cancel()
        }
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SkillSourceIcon(sourceKind: skill.sourceKind, size: 16)
                Text(skill.sourceKind.sourceBadgeLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                pillBadge(
                    skill.isBuiltin
                        ? tr("Built-in", "内置")
                        : tr("User", "用户安装")
                )

                if skill.isSymlink {
                    pillBadge(tr("Symlink", "软链接"))
                }

                Spacer(minLength: 8)

                if !PrivacyDisplay.isEnabled {
                    actionButtons
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(skill.name)
                    .font(.system(size: 18, weight: .semibold))
                    .textSelection(.enabled)

                if skill.folderName != skill.name {
                    Text("(\(skill.folderName))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: skill.isSymlink ? "link" : "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                PrivacySensitiveText(text: pathDisplayText, kind: .path, sensitive: true)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(PrivacyDisplay.help(pathHelpText))
            }
        }
    }

    private var pathDisplayText: String {
        if let target = skill.symlinkTarget {
            return "\(skill.displayPath) → \(target)"
        }
        return skill.displayPath
    }

    private var pathHelpText: String {
        if let target = skill.symlinkTarget {
            return "\(skill.directoryPath) → \(target)"
        }
        return skill.directoryPath
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button {
                SessionActions.copy(skill.directoryPath)
                copiedPath = true
                resetCopyTask?.cancel()
                resetCopyTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    copiedPath = false
                }
            } label: {
                Label(
                    copiedPath ? tr("Copied", "已复制") : tr("Copy Path", "复制路径"),
                    systemImage: copiedPath ? "checkmark" : "doc.on.doc"
                )
            }
            .controlSize(.small)
            .pointingHandCursor()

            Button(tr("Show in Finder", "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.skillFilePath)])
            }
            .controlSize(.small)
            .pointingHandCursor()

            Menu {
                Button(tr("Open SKILL.md", "打开 SKILL.md")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: skill.skillFilePath))
                }

                let editors = SessionActions.installedEditors
                if !editors.isEmpty {
                    Divider()
                    ForEach(editors) { editor in
                        Button(tr("Open in \(editor.name)", "用 \(editor.name) 打开")) {
                            SessionActions.open(skill.directoryPath, with: editor)
                        }
                    }
                }
            } label: {
                Label(tr("Open", "打开"), systemImage: "arrow.up.forward.square")
            }
            .controlSize(.small)
            .pointingHandCursor()
        }
    }

    private func pillBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    // MARK: Panels

    private var descriptionPanel: some View {
        SkillDetailCard(title: tr("Description", "功能说明")) {
            if skill.description.isEmpty {
                Text(tr("No description provided in SKILL.md.", "SKILL.md 中未提供功能说明。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Text(skill.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var metadataAndResourcesPanel: some View {
        SkillDetailCard(title: tr("Metadata & Bundled Resources", "属性与附属资源")) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    keyValueRow(
                        label: tr("Source", "来源"),
                        value: skill.sourceKind.sourceBadgeLabel
                    )
                    Divider()
                    keyValueRow(
                        label: tr("Scope", "安装类型"),
                        value: skill.isBuiltin
                            ? tr("Built-in", "内置技能")
                            : tr("User installed", "用户安装")
                    )
                    if let modifiedAt = skill.modifiedAt {
                        Divider()
                        keyValueRow(
                            label: tr("Last modified", "最近修改"),
                            value: Self.fullDateFormatter.string(from: modifiedAt)
                        )
                    }
                    Divider()
                    keyValueRow(
                        label: "SKILL.md",
                        value: tr(
                            "\(Self.byteCountFormatter.string(fromByteCount: skill.fileSizeBytes)) · \(skill.lineCount) lines",
                            "\(Self.byteCountFormatter.string(fromByteCount: skill.fileSizeBytes)) · \(skill.lineCount) 行"
                        )
                    )

                    ForEach(skill.metadata.keys.sorted(), id: \.self) { key in
                        if let value = skill.metadata[key] {
                            Divider()
                            keyValueRow(label: key, value: value)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Bundled files", "附属文件与目录"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if skill.resources.isEmpty {
                        Text(tr("SKILL.md only (no extra bundled files)", "仅包含 SKILL.md，无额外附属文件"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    } else {
                        FlowWrapLayout(spacing: 6) {
                            ForEach(skill.resources) { entry in
                                resourceChip(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func keyValueRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }

    private func resourceChip(_ entry: LocalSkillResourceEntry) -> some View {
        let caption = entry.isDirectory
            ? "\(entry.name)/ (\(entry.childCount))"
            : entry.name
        return Button {
            guard !PrivacyDisplay.isEnabled else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        } label: {
            HStack(spacing: 4) {
                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(PrivacyDisplay.isEnabled
            ? tr("Hidden for privacy", "隐私模式下已隐藏")
            : tr("Show in Finder: \(entry.path)", "在访达中显示：\(entry.path)"))
    }

    private var otherLocationsPanel: some View {
        SkillDetailCard(title: tr("Other Locations (\(siblings.count))", "其他安装位置 (\(siblings.count))")) {
            VStack(spacing: 0) {
                ForEach(Array(siblings.enumerated()), id: \.element.id) { index, sibling in
                    if index > 0 { Divider() }
                    Button {
                        onSelectSibling(sibling)
                    } label: {
                        HStack(spacing: 8) {
                            SkillSourceIcon(sourceKind: sibling.sourceKind, size: 14)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(sibling.sourceKind.sourceBadgeLabel)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    if sibling.isSymlink {
                                        pillBadge(tr("Symlink", "软链接"))
                                    }
                                }
                                PrivacySensitiveText(text: sibling.displayPath, kind: .path, sensitive: true)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            if let modifiedAt = sibling.modifiedAt {
                                Text(Self.fullDateFormatter.string(from: modifiedAt))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }

                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }

    private var instructionsPanel: some View {
        SkillDetailCard(
            title: tr("Instructions (SKILL.md)", "指令正文 (SKILL.md)"),
            trailing: AnyView(
                Picker("", selection: $showRawSource) {
                    Text(tr("Formatted", "排版预览")).tag(false)
                    Text(tr("Raw", "源码")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            )
        ) {
            if showRawSource {
                let rawText = reconstructedRawDocument
                if rawText.isEmpty {
                    Text(tr("SKILL.md is empty.", "SKILL.md 内容为空。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(rawText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } else if skill.bodyMarkdown.isEmpty {
                Text(tr("No instruction body after frontmatter.", "Frontmatter 之后没有正文内容。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                SkillMarkdownView(markdown: skill.bodyMarkdown)
            }
        }
    }

    private var reconstructedRawDocument: String {
        if let frontmatter = skill.rawFrontmatter {
            if skill.bodyMarkdown.isEmpty {
                return "---\n\(frontmatter)\n---"
            }
            return "---\n\(frontmatter)\n---\n\n\(skill.bodyMarkdown)"
        }
        return skill.bodyMarkdown
    }

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB]
        formatter.countStyle = .file
        return formatter
    }()
}

// MARK: - Reusable Detail Card & Layout Helpers

private struct SkillDetailCard<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .ccPanel(cornerRadius: 10)
    }
}

private struct FlowWrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxUsedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            maxUsedWidth = max(maxUsedWidth, currentX + size.width)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxUsedWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Lightweight Markdown Preview

private struct SkillMarkdownView: View {
    let markdown: String

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case code(id: Int, language: String, text: String)
        case quote(id: Int, text: String)
        case bullet(id: Int, marker: String, text: String)
        case divider(id: Int)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .code(let id, _, _),
                 .quote(let id, _),
                 .bullet(let id, _, _),
                 .divider(let id),
                 .paragraph(let id, _):
                return id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parsedBlocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    inlineText(text)
                        .font(.system(size: headingSize(for: level), weight: .semibold))
                        .padding(.top, level <= 2 ? 4 : 2)
                        .textSelection(.enabled)

                case .code(_, let language, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        if !language.isEmpty {
                            Text(language)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                case .quote(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2.5)
                        inlineText(text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                case .bullet(_, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        inlineText(text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 4)

                case .divider:
                    Divider()
                        .padding(.vertical, 2)

                case .paragraph(_, let text):
                    inlineText(text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 13.5
        default: return 12.5
        }
    }

    private func inlineText(_ raw: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: raw, options: options) {
            return Text(attr)
        }
        return Text(raw)
    }

    private var parsedBlocks: [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [Block] = []
        var nextID = 0
        var idx = 0

        func allocID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                idx += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                idx += 1
                var codeLines: [String] = []
                while idx < lines.count {
                    let current = lines[idx]
                    if current.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        idx += 1
                        break
                    }
                    codeLines.append(current)
                    idx += 1
                }
                blocks.append(.code(id: allocID(), language: lang, text: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider(id: allocID()))
                idx += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                if !hashes.isEmpty, hashes.count <= 6, trimmed.dropFirst(hashes.count).first == " " {
                    let text = String(trimmed.dropFirst(hashes.count + 1)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(id: allocID(), level: hashes.count, text: text))
                    idx += 1
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = String(t.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    idx += 1
                }
                blocks.append(.quote(id: allocID(), text: quoteLines.joined(separator: "\n")))
                continue
            }

            if let (marker, rest) = parseListMarker(trimmed) {
                blocks.append(.bullet(id: allocID(), marker: marker, text: rest))
                idx += 1
                continue
            }

            var paragraphLines: [String] = []
            while idx < lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                if t.isEmpty
                    || t.hasPrefix("```")
                    || t.hasPrefix("~~~")
                    || t.hasPrefix("#")
                    || t.hasPrefix(">")
                    || t == "---"
                    || t == "***"
                    || t == "___"
                    || parseListMarker(t) != nil {
                    break
                }
                paragraphLines.append(t)
                idx += 1
            }
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(id: allocID(), text: paragraphLines.joined(separator: " ")))
            } else {
                idx += 1
            }
        }

        return blocks
    }

    private func parseListMarker(_ trimmed: String) -> (String, String)? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return ("•", String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") {
                let rest = String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return ("\(digits).", rest)
            }
        }
        return nil
    }
}
