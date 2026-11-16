import Foundation
import Observation

// MARK: - Scan Roots

nonisolated struct LocalSkillRootSpec: Sendable, Hashable {
    enum ScanMode: Sendable, Hashable {
        case directChildren(skipNames: Set<String>)
        case nestedPacks(maxDepth: Int)
    }

    var kind: LocalSkillSourceKind
    var url: URL
    var mode: ScanMode

    /// 仅扫描隐藏 dot 目录与 `Application Support` 下的明确 Skill 目录，绝不触碰受 TCC 保护的个人文件夹。
    static func defaultRoots(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LocalSkillRootSpec] {
        [
            LocalSkillRootSpec(
                kind: .agentsShared,
                url: homeURL.appendingPathComponent(".agents/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .codexUser,
                url: homeURL.appendingPathComponent(".codex/skills", isDirectory: true),
                mode: .directChildren(skipNames: [".system"])
            ),
            LocalSkillRootSpec(
                kind: .codexSystem,
                url: homeURL.appendingPathComponent(".codex/skills/.system", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .codexVendor,
                url: homeURL.appendingPathComponent(".codex/vendor_imports/skills", isDirectory: true),
                mode: .nestedPacks(maxDepth: 3)
            ),
            LocalSkillRootSpec(
                kind: .claudeUser,
                url: homeURL.appendingPathComponent(".claude/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .claudePlugins,
                url: homeURL.appendingPathComponent(".claude/plugins", isDirectory: true),
                mode: .nestedPacks(maxDepth: 4)
            ),
            LocalSkillRootSpec(
                kind: .antigravityUser,
                url: homeURL.appendingPathComponent(".gemini/antigravity/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .geminiUser,
                url: homeURL.appendingPathComponent(".gemini/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .geminiUser,
                url: homeURL.appendingPathComponent(".gemini/config/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .antigravityBuiltin,
                url: homeURL.appendingPathComponent(".gemini/antigravity/builtin/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .antigravityCLIBuiltin,
                url: homeURL.appendingPathComponent(".gemini/antigravity-cli/builtin/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .cursorUser,
                url: homeURL.appendingPathComponent(".cursor/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .cursorBuiltin,
                url: homeURL.appendingPathComponent(".cursor/skills-cursor", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .opencodeUser,
                url: homeURL.appendingPathComponent(".config/opencode/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .opencodeUser,
                url: homeURL.appendingPathComponent(".config/opencode/skill", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .opencodeUser,
                url: homeURL.appendingPathComponent(".opencode/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .opencodeUser,
                url: homeURL.appendingPathComponent(".opencode/skill", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .piUser,
                url: homeURL.appendingPathComponent(".pi/agent/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .qwenWork,
                url: homeURL.appendingPathComponent(".qwenwork/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .qwenWork,
                url: homeURL.appendingPathComponent(".qwenworkcn/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .minimaxUser,
                url: homeURL.appendingPathComponent(".minimax/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .minimaxBuiltin,
                url: homeURL.appendingPathComponent(".minimax/.builtin-skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .minimaxBuiltin,
                url: homeURL.appendingPathComponent(".minimax/.internal-skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
            LocalSkillRootSpec(
                kind: .aionUi,
                url: homeURL.appendingPathComponent("Library/Application Support/AionUi/config/skills", isDirectory: true),
                mode: .directChildren(skipNames: [])
            ),
        ]
    }
}

// MARK: - Read-Only Scanner

nonisolated enum LocalSkillScanner {
    static let ignoredDirectoryNames: Set<String> = [
        ".git",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        ".DS_Store",
        ".pytest_cache",
        ".mypy_cache",
        "dist",
        "build",
    ]

    private static let maxSkillFileBytes = 128 * 1024
    private static let maxBodyUTF8Bytes = 64 * 1024

    static func scan(
        roots: [LocalSkillRootSpec],
        homePath: String
    ) -> [LocalSkillRecord] {
        let fm = FileManager.default
        let normalizedHome = standardizePathString(homePath)
        var scannedRootKeys: Set<String> = []
        var seenSkillIDs: Set<String> = []
        var records: [LocalSkillRecord] = []

        for root in roots {
            let rootPath = root.url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let canonicalRoot = root.url.resolvingSymlinksInPath().standardizedFileURL.path
            let rootDedupKey = "\(root.kind.sourceGroupID):\(canonicalRoot)"
            guard scannedRootKeys.insert(rootDedupKey).inserted else {
                continue
            }

            let candidateDirs: [URL]
            switch root.mode {
            case .directChildren(let skipNames):
                candidateDirs = collectDirectSkillDirectories(
                    at: root.url,
                    skipNames: skipNames,
                    fileManager: fm
                )
            case .nestedPacks(let maxDepth):
                candidateDirs = collectNestedSkillDirectories(
                    at: root.url,
                    maxDepth: maxDepth,
                    fileManager: fm
                )
            }

            for dirURL in candidateDirs {
                guard let record = parseSkillDirectory(
                    dirURL,
                    sourceKind: root.kind,
                    homePath: normalizedHome,
                    fileManager: fm
                ) else {
                    continue
                }
                if seenSkillIDs.insert(record.id).inserted {
                    records.append(record)
                }
            }
        }

        records.sort { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin {
                return !lhs.isBuiltin
            }
            let cmp = lhs.name.localizedStandardCompare(rhs.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.id < rhs.id
        }
        return records
    }

    private static func collectDirectSkillDirectories(
        at rootURL: URL,
        skipNames: Set<String>,
        fileManager fm: FileManager
    ) -> [URL] {
        guard let children = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }

        var dirs: [URL] = []
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || skipNames.contains(name) || ignoredDirectoryNames.contains(name) {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if resolveSkillFileURL(in: child, fileManager: fm) != nil {
                dirs.append(child)
            }
        }
        return dirs
    }

    private static func collectNestedSkillDirectories(
        at rootURL: URL,
        maxDepth: Int,
        fileManager fm: FileManager
    ) -> [URL] {
        var found: [URL] = []
        var visitedCanonicalDirs: Set<String> = []

        func walk(_ dirURL: URL, depth: Int) {
            let canonical = dirURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard visitedCanonicalDirs.insert(canonical).inserted else { return }

            if depth > 0, resolveSkillFileURL(in: dirURL, fileManager: fm) != nil {
                found.append(dirURL)
                return
            }

            guard depth < maxDepth else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                return
            }

            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || ignoredDirectoryNames.contains(name) {
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                walk(child, depth: depth + 1)
            }
        }

        walk(rootURL, depth: 0)
        return found
    }

    private static func resolveSkillFileURL(in dirURL: URL, fileManager fm: FileManager) -> URL? {
        for candidate in ["SKILL.md", "skill.md"] {
            let fileURL = dirURL.appendingPathComponent(candidate, isDirectory: false)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                return fileURL
            }
        }
        return nil
    }

    private static func parseSkillDirectory(
        _ dirURL: URL,
        sourceKind: LocalSkillSourceKind,
        homePath: String,
        fileManager fm: FileManager
    ) -> LocalSkillRecord? {
        guard let skillFileURL = resolveSkillFileURL(in: dirURL, fileManager: fm) else {
            return nil
        }

        let directoryPath = standardizePathString(dirURL.standardizedFileURL.path)
        let skillFilePath = standardizePathString(skillFileURL.standardizedFileURL.path)
        let folderName = dirURL.lastPathComponent

        let markdown = readUTF8Prefix(at: skillFileURL, maxBytes: maxSkillFileBytes)
        let parsed = LocalSkillFrontmatterParser.parse(markdown: markdown, fallbackName: folderName)
        let cappedBody = capUTF8(parsed.body, maxBytes: maxBodyUTF8Bytes)

        let dirAttrs = try? fm.attributesOfItem(atPath: directoryPath)
        let isSymlink = (dirAttrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        var symlinkTarget: String?
        if isSymlink, let rawTarget = try? fm.destinationOfSymbolicLink(atPath: directoryPath) {
            let resolvedTarget: String
            if rawTarget.hasPrefix("/") {
                resolvedTarget = standardizePathString(rawTarget)
            } else {
                let parentURL = dirURL.deletingLastPathComponent()
                resolvedTarget = standardizePathString(
                    parentURL.appendingPathComponent(rawTarget).standardizedFileURL.path
                )
            }
            symlinkTarget = abbreviateHome(resolvedTarget, homePath: homePath)
        }

        let fileAttrs = try? fm.attributesOfItem(atPath: skillFileURL.resolvingSymlinksInPath().path)
        let modifiedAt = fileAttrs?[.modificationDate] as? Date
        let fileSizeBytes = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? Int64(markdown.utf8.count)

        let resources = collectResources(in: dirURL, fileManager: fm)

        return LocalSkillRecord(
            id: "\(sourceKind.rawValue):\(directoryPath)",
            name: parsed.name,
            folderName: folderName,
            description: parsed.description,
            metadata: parsed.metadata,
            sourceKind: sourceKind,
            directoryPath: directoryPath,
            skillFilePath: skillFilePath,
            displayPath: abbreviateHome(directoryPath, homePath: homePath),
            isSymlink: isSymlink,
            symlinkTarget: symlinkTarget,
            modifiedAt: modifiedAt,
            fileSizeBytes: fileSizeBytes,
            lineCount: parsed.lineCount,
            bodyMarkdown: cappedBody,
            rawFrontmatter: parsed.rawFrontmatter,
            resources: resources
        )
    }

    private static func collectResources(in dirURL: URL, fileManager fm: FileManager) -> [LocalSkillResourceEntry] {
        let resolvedDir = dirURL.resolvingSymlinksInPath()
        guard let children = try? fm.contentsOfDirectory(
            at: resolvedDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var entries: [LocalSkillResourceEntry] = []
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || ignoredDirectoryNames.contains(name) {
                continue
            }
            if name.caseInsensitiveCompare("SKILL.md") == .orderedSame {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else {
                continue
            }
            let childCount: Int
            if isDir.boolValue,
               let subEntries = try? fm.contentsOfDirectory(atPath: child.path) {
                childCount = subEntries.filter { !$0.hasPrefix(".") && !ignoredDirectoryNames.contains($0) }.count
            } else {
                childCount = 0
            }
            entries.append(
                LocalSkillResourceEntry(
                    name: name,
                    path: standardizePathString(child.path),
                    isDirectory: isDir.boolValue,
                    childCount: childCount
                )
            )
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    private static func readUTF8Prefix(at url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func capUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let prefixBytes = text.utf8.prefix(maxBytes)
        return String(decoding: prefixBytes, as: UTF8.self) + "\n\n…"
    }

    private static func standardizePathString(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    private static func abbreviateHome(_ path: String, homePath: String) -> String {
        guard !homePath.isEmpty else { return path }
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }
}

// MARK: - Observable Service

@Observable
@MainActor
final class LocalSkillService {
    private(set) var skills: [LocalSkillRecord] = []
    private(set) var isScanning = false
    private(set) var lastScanAt: Date?
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private let roots: [LocalSkillRootSpec]
    @ObservationIgnored private let homePath: String
    @ObservationIgnored private let usesDefaultRoots: Bool
    @ObservationIgnored private var activeScanTask: Task<Void, Never>?
    @ObservationIgnored private var queuedRescan = false

    init(roots: [LocalSkillRootSpec]? = nil, homePath: String? = nil) {
        self.usesDefaultRoots = (roots == nil)
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? LocalSkillRootSpec.defaultRoots(homeURL: homeURL)
        self.homePath = homePath ?? homeURL.standardizedFileURL.path
    }

    func refreshInBackground(minAge: TimeInterval = 5.0) {
        if usesDefaultRoots && AppRuntime.isRunningUnitTests { return }
        if activeScanTask != nil { return }
        if let lastScanAt, Date().timeIntervalSince(lastScanAt) < minAge { return }
        Task { [weak self] in
            await self?.refreshNow()
        }
    }

    func refreshNow() async {
        if usesDefaultRoots && AppRuntime.isRunningUnitTests { return }
        if let activeScanTask {
            queuedRescan = true
            await activeScanTask.value
            return
        }

        let runner = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeScanTask = nil
                self.isScanning = false
            }
            self.isScanning = true
            repeat {
                self.queuedRescan = false
                let scanRoots = self.roots
                let scanHome = self.homePath
                let scanned = await Task.detached(priority: .utility) {
                    LocalSkillScanner.scan(roots: scanRoots, homePath: scanHome)
                }.value
                if self.skills != scanned {
                    self.skills = scanned
                    self.revision &+= 1
                }
                self.lastScanAt = Date()
            } while self.queuedRescan
        }
        activeScanTask = runner
        await runner.value
    }

    func siblings(of skill: LocalSkillRecord) -> [LocalSkillRecord] {
        let needle = skill.name.lowercased()
        return skills.filter { $0.id != skill.id && $0.name.lowercased() == needle }
    }
}
