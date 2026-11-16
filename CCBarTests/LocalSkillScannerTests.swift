import XCTest
@testable import CCBar

final class LocalSkillScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Frontmatter Parsing

    func testParseSingleLineFrontmatterAndChineseText() {
        let markdown = """
        ---
        name: anjian
        description: 按用户最新修改的Word蓝本和案件材料制作、修正行政处罚文书。
        ---

        # 行政案件文档制作

        正文说明第一段。
        """

        let parsed = LocalSkillFrontmatterParser.parse(markdown: markdown, fallbackName: "fallback-slug")
        XCTAssertEqual(parsed.name, "anjian")
        XCTAssertEqual(parsed.description, "按用户最新修改的Word蓝本和案件材料制作、修正行政处罚文书。")
        XCTAssertTrue(parsed.body.hasPrefix("# 行政案件文档制作"))
        XCTAssertNotNil(parsed.rawFrontmatter)
    }

    func testParseFoldedAndLiteralBlockScalarsAndMetadata() {
        let foldedMarkdown = """
        \u{FEFF}---
        name: swarm
        description: >-
          Run a swarm: several agents working in parallel on
          one task, collaborating through a shared board.
        metadata:
          icon: hub
          short-description: Multi-agent parallel swarm
        ---

        Body line
        """

        let folded = LocalSkillFrontmatterParser.parse(markdown: foldedMarkdown, fallbackName: "swarm")
        XCTAssertEqual(folded.name, "swarm")
        XCTAssertEqual(
            folded.description,
            "Run a swarm: several agents working in parallel on one task, collaborating through a shared board."
        )
        XCTAssertEqual(folded.metadata["icon"], "hub")
        XCTAssertEqual(folded.metadata["short-description"], "Multi-agent parallel swarm")

        let literalMarkdown = """
        ---
        name: notes
        description: |-
          Line one
          Line two
        ---

        Details
        """
        let literal = LocalSkillFrontmatterParser.parse(markdown: literalMarkdown, fallbackName: "notes")
        XCTAssertEqual(literal.description, "Line one\nLine two")
    }

    func testParseMissingFrontmatterFallsBackToFolderAndFirstParagraph() {
        let markdown = """
        # Heading Title

        First body paragraph explains what this skill does.

        Second paragraph should not be included.
        """

        let parsed = LocalSkillFrontmatterParser.parse(markdown: markdown, fallbackName: "custom-folder")
        XCTAssertEqual(parsed.name, "custom-folder")
        XCTAssertEqual(parsed.description, "First body paragraph explains what this skill does.")
        XCTAssertNil(parsed.rawFrontmatter)
    }

    // MARK: - Scanner

    func testScanUserBuiltinSymlinksResourcesAndPinyinSearch() throws {
        let fm = FileManager.default
        let homeURL = tempDir.appendingPathComponent("home", isDirectory: true)
        let agentsDir = homeURL.appendingPathComponent(".agents/skills/anjian", isDirectory: true)
        let codexDir = homeURL.appendingPathComponent(".codex/skills", isDirectory: true)
        let codexSystemDir = codexDir.appendingPathComponent(".system/skill-creator", isDirectory: true)
        let agyBuiltinDir = homeURL.appendingPathComponent(".gemini/antigravity-cli/builtin/skills/native_swarm", isDirectory: true)

        try fm.createDirectory(at: agentsDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir.appendingPathComponent(".venv/lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexSystemDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agyBuiltinDir, withIntermediateDirectories: true)

        try """
        ---
        name: anjian
        description: 制作行政处罚案件文书
        ---

        # Anjian
        """.write(to: agentsDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3\n".write(
            to: agentsDir.appendingPathComponent("scripts/helper.py"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored".write(
            to: agentsDir.appendingPathComponent(".venv/lib/site.py"),
            atomically: true,
            encoding: .utf8
        )

        // Symlink inside ~/.codex/skills pointing to ~/.agents/skills/anjian
        let codexSymlink = codexDir.appendingPathComponent("anjian")
        try fm.createSymbolicLink(at: codexSymlink, withDestinationURL: agentsDir)

        try """
        ---
        name: skill-creator
        description: Create or update a Codex skill.
        ---

        # Skill Creator
        """.write(to: codexSystemDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        try """
        ---
        name: swarm
        description: Parallel swarm agents.
        ---

        # Swarm
        """.write(to: agyBuiltinDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let roots = LocalSkillRootSpec.defaultRoots(homeURL: homeURL)
        let scanned = LocalSkillScanner.scan(roots: roots, homePath: homeURL.standardizedFileURL.path)

        XCTAssertEqual(scanned.count, 4)

        let agentsSkill = try XCTUnwrap(scanned.first { $0.sourceKind == .agentsShared && $0.name == "anjian" })
        XCTAssertFalse(agentsSkill.isBuiltin)
        XCTAssertFalse(agentsSkill.isSymlink)
        XCTAssertEqual(agentsSkill.displayPath, "~/.agents/skills/anjian")
        XCTAssertEqual(agentsSkill.resources.map(\.name), ["scripts"])
        XCTAssertEqual(agentsSkill.resources.first?.childCount, 1)
        XCTAssertTrue(agentsSkill.matches(usageApp: .codex))
        XCTAssertTrue(agentsSkill.matches(usageApp: .antigravity))
        XCTAssertFalse(agentsSkill.matches(usageApp: .claude))
        XCTAssertTrue(agentsSkill.matches(lowercasedQuery: "xzcf")) // 行政处罚 Pinyin initials
        XCTAssertTrue(agentsSkill.matches(lowercasedQuery: "anjian"))

        let codexLinked = try XCTUnwrap(scanned.first { $0.sourceKind == .codexUser && $0.name == "anjian" })
        XCTAssertTrue(codexLinked.isSymlink)
        XCTAssertEqual(codexLinked.symlinkTarget, "~/.agents/skills/anjian")
        XCTAssertTrue(codexLinked.matches(usageApp: .codex))
        XCTAssertFalse(codexLinked.matches(usageApp: .antigravity))

        let sysSkill = try XCTUnwrap(scanned.first { $0.sourceKind == .codexSystem })
        XCTAssertTrue(sysSkill.isBuiltin)
        XCTAssertEqual(sysSkill.name, "skill-creator")

        let agySkill = try XCTUnwrap(scanned.first { $0.sourceKind == .antigravityCLIBuiltin })
        XCTAssertTrue(agySkill.isBuiltin)
        XCTAssertTrue(agySkill.matches(usageApp: .antigravity))
    }
}
