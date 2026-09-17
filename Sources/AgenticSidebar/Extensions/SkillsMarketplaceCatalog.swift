import Foundation

/// One skill the marketplace tab offers with a single click.
///
/// `repository` is what makes the row work: it is the `owner/repo[/path]` the
/// installer fetches from, so a card can never point somewhere that does not
/// exist. An earlier version carried a decorative string here and installed
/// everything from one hard-coded repository instead, which meant every card in
/// the marketplace failed with "not found".
struct CuratedSkillEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let category: String
    let author: String
    /// `owner/repo` or `owner/repo/path-to-the-skill-folder`.
    let repository: String

    var skillFolder: String { name }
}

/// The skills offered on the marketplace tab.
///
/// Every entry is a folder that exists in a public repository, holds a valid
/// `SKILL.md`, and is small enough for the installer's limits (40 files, 512 KiB
/// per file, 4 MiB in total). The large bundles in the same repository — `docx`,
/// `pptx`, `xlsx`, `canvas-design`, `claude-api` — are deliberately not listed:
/// the fetcher would silently install only the first 40 of their files.
enum SkillsMarketplaceCatalog {
    static let curatedSkills: [CuratedSkillEntry] = [
        CuratedSkillEntry(
            id: "skill-creator",
            name: "skill-creator",
            displayName: "Skill Creator",
            description: "Create new skills, improve existing ones, and measure how well a skill performs.",
            category: "Authoring",
            author: "Anthropic",
            repository: "anthropics/skills/skills/skill-creator"
        ),
        CuratedSkillEntry(
            id: "mcp-builder",
            name: "mcp-builder",
            displayName: "MCP Server Builder",
            description: "Build high-quality Model Context Protocol servers that expose tools to an agent.",
            category: "Engineering",
            author: "Anthropic",
            repository: "anthropics/skills/skills/mcp-builder"
        ),
        CuratedSkillEntry(
            id: "open-code-review",
            name: "open-code-review",
            displayName: "Open Code Review",
            description: "Alibaba Cloud code review system. Deep inspection, defect detection, and actionable remediation plans.",
            category: "Engineering",
            author: "Alibaba Cloud",
            repository: "alibaba/open-code-review/skills/open-code-review"
        ),
        CuratedSkillEntry(
            id: "webapp-testing",
            name: "webapp-testing",
            displayName: "Web App Testing",
            description: "Drive and verify a local web application with Playwright, including debugging failures.",
            category: "Testing",
            author: "Anthropic",
            repository: "anthropics/skills/skills/webapp-testing"
        ),
        CuratedSkillEntry(
            id: "frontend-design",
            name: "frontend-design",
            displayName: "Frontend Design",
            description: "Guidance for distinctive, intentional visual design when building or reshaping a UI.",
            category: "Frontend",
            author: "Anthropic",
            repository: "anthropics/skills/skills/frontend-design"
        ),
        CuratedSkillEntry(
            id: "web-artifacts-builder",
            name: "web-artifacts-builder",
            displayName: "Web Artifacts Builder",
            description: "Build elaborate multi-component HTML artifacts with modern frontend frameworks.",
            category: "Frontend",
            author: "Anthropic",
            repository: "anthropics/skills/skills/web-artifacts-builder"
        ),
        CuratedSkillEntry(
            id: "pdf",
            name: "pdf",
            displayName: "PDF Toolkit",
            description: "Read, fill, split, merge and extract content from PDF files.",
            category: "Documents",
            author: "Anthropic",
            repository: "anthropics/skills/skills/pdf"
        ),
        CuratedSkillEntry(
            id: "doc-coauthoring",
            name: "doc-coauthoring",
            displayName: "Document Co-authoring",
            description: "A structured workflow for writing and revising documentation together with the agent.",
            category: "Documents",
            author: "Anthropic",
            repository: "anthropics/skills/skills/doc-coauthoring"
        ),
        CuratedSkillEntry(
            id: "theme-factory",
            name: "theme-factory",
            displayName: "Theme Factory",
            description: "Style slides, documents and HTML output with a consistent, reusable theme.",
            category: "Design",
            author: "Anthropic",
            repository: "anthropics/skills/skills/theme-factory"
        ),
        CuratedSkillEntry(
            id: "algorithmic-art",
            name: "algorithmic-art",
            displayName: "Algorithmic Art",
            description: "Generate algorithmic art with p5.js, seeded randomness and interactive parameters.",
            category: "Design",
            author: "Anthropic",
            repository: "anthropics/skills/skills/algorithmic-art"
        ),
        CuratedSkillEntry(
            id: "slack-gif-creator",
            name: "slack-gif-creator",
            displayName: "Slack GIF Creator",
            description: "Create animated GIFs that fit Slack's size and dimension constraints.",
            category: "Productivity",
            author: "Anthropic",
            repository: "anthropics/skills/skills/slack-gif-creator"
        ),
        CuratedSkillEntry(
            id: "internal-comms",
            name: "internal-comms",
            displayName: "Internal Communications",
            description: "Formats and templates for announcements, updates and other internal writing.",
            category: "Productivity",
            author: "Anthropic",
            repository: "anthropics/skills/skills/internal-comms"
        ),
        CuratedSkillEntry(
            id: "brand-guidelines",
            name: "brand-guidelines",
            displayName: "Brand Guidelines",
            description: "Apply a consistent brand palette and typography to generated artifacts.",
            category: "Design",
            author: "Anthropic",
            repository: "anthropics/skills/skills/brand-guidelines"
        )
    ]
}
