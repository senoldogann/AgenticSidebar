import Foundation

struct CuratedSkillEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let category: String
    let author: String
    let repository: String

    var skillFolder: String { name }
}

enum SkillsMarketplaceCatalog {
    static let curatedSkills: [CuratedSkillEntry] = [
        CuratedSkillEntry(
            id: "chrome-devtools",
            name: "chrome-devtools",
            displayName: "Chrome DevTools Automation",
            description: "Automate browser testing, inspect network logs, performance traces, and run DOM automation.",
            category: "Browser & Web",
            author: "Google / Antigravity",
            repository: "chrome-devtools-plugin"
        ),
        CuratedSkillEntry(
            id: "code-review",
            name: "code-review",
            displayName: "Deep Code Reviewer",
            description: "Automated codebase reviews, style enforcement, concurrency checks, and test coverage validation.",
            category: "Engineering",
            author: "OpenCode",
            repository: "code-review-plugin"
        ),
        CuratedSkillEntry(
            id: "memory-leak-debugging",
            name: "memory-leak-debugging",
            displayName: "Memory Leak Diagnostics",
            description: "Diagnose and resolve memory leaks in JavaScript and Node.js applications with heap analysis.",
            category: "Performance",
            author: "Web Dev Tools",
            repository: "chrome-devtools-plugin"
        ),
        CuratedSkillEntry(
            id: "debug-optimize-lcp",
            name: "debug-optimize-lcp",
            displayName: "LCP Performance Optimizer",
            description: "Analyze and optimize Largest Contentful Paint (LCP) and Core Web Vitals using Chrome DevTools.",
            category: "Performance",
            author: "Web Dev Tools",
            repository: "chrome-devtools-plugin"
        ),
        CuratedSkillEntry(
            id: "a11y-debugging",
            name: "a11y-debugging",
            displayName: "Accessibility (a11y) Auditing",
            description: "Audits ARIA attributes, semantic HTML, color contrast, keyboard navigation, and tap targets.",
            category: "Accessibility",
            author: "Web Dev Tools",
            repository: "chrome-devtools-plugin"
        ),
        CuratedSkillEntry(
            id: "modern-web-guidance",
            name: "modern-web-guidance",
            displayName: "Modern Web Guidance",
            description: "Best practices for modern CSS, View Transitions, Container Queries, and Fetch Priority.",
            category: "Frontend",
            author: "Web Guidance Team",
            repository: "modern-web-guidance-plugin"
        ),
        CuratedSkillEntry(
            id: "android-cli",
            name: "android-cli",
            displayName: "Android CLI Orchestrator",
            description: "Orchestrate Android development tasks, SDK management, device emulation, and diagnostics.",
            category: "Mobile",
            author: "Mobile Tools",
            repository: "android-cli-plugin"
        ),
        CuratedSkillEntry(
            id: "google-antigravity-sdk",
            name: "google-antigravity-sdk",
            displayName: "Google Antigravity Agent SDK",
            description: "Design, implement, and debug autonomous AI agents and multi-agent workflows.",
            category: "AI & Agents",
            author: "Google Deepmind",
            repository: "google-antigravity-sdk"
        )
    ]
}
