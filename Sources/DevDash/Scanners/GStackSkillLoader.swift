import Foundation

struct GStackPersona: Identifiable {
    let id: String
    let role: String
    let tagline: String
    let systemImage: String
    let marker: String

    var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.claude/skills/gstack/\(id)/SKILL.md"
        )
    }

    var content: String? {
        GStackSkillLoader.persona(for: id, startingWith: marker)
    }
}

enum GStackSkillLoader {

    // MARK: - Core loader

    static func persona(for skill: String, startingWith marker: String) -> String? {
        let path = NSHomeDirectory() + "/.claude/skills/gstack/\(skill)/SKILL.md"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let range = content.range(of: marker) else { return nil }
        return String(content[range.lowerBound...])
    }

    // MARK: - Persona catalog

    static let all: [GStackPersona] = [
        GStackPersona(
            id: "plan-eng-review",
            role: "Eng Manager",
            tagline: "Lock in architecture, data flow, diagrams, edge cases, and tests.",
            systemImage: "person.and.background.dotted",
            marker: "# Plan Review Mode"
        ),
        GStackPersona(
            id: "review",
            role: "Staff Engineer",
            tagline: "Find the bugs that pass CI but blow up in production.",
            systemImage: "magnifyingglass.circle",
            marker: "You are running the `/review` workflow."
        ),
        GStackPersona(
            id: "investigate",
            role: "Debugger",
            tagline: "Systematic root-cause debugging. No fixes without investigation.",
            systemImage: "stethoscope",
            marker: "# Systematic Debugging"
        ),
        GStackPersona(
            id: "design-review",
            role: "Designer Who Codes",
            tagline: "Design audit then fixes what it finds. Atomic commits, before/after screenshots.",
            systemImage: "paintbrush.pointed",
            marker: "You are a senior product designer AND a frontend engineer."
        ),
        GStackPersona(
            id: "design-consultation",
            role: "Design Partner",
            tagline: "Build a complete design system from scratch.",
            systemImage: "paintpalette",
            marker: "You are a senior product designer with strong opinions"
        ),
        GStackPersona(
            id: "qa",
            role: "QA Lead",
            tagline: "Test your app, find bugs, fix them with atomic commits, re-verify.",
            systemImage: "checkmark.shield",
            marker: "You are a QA engineer AND a bug-fix engineer."
        ),
        GStackPersona(
            id: "cso",
            role: "Chief Security Officer",
            tagline: "OWASP Top 10 + STRIDE threat model. 8/10+ confidence gate.",
            systemImage: "lock.shield",
            marker: "You are a Chief Security Officer"
        ),
        GStackPersona(
            id: "ship",
            role: "Release Engineer",
            tagline: "Sync main, run tests, audit coverage, push, open PR.",
            systemImage: "shippingbox",
            marker: "You are running the `/ship` workflow."
        ),
        GStackPersona(
            id: "document-release",
            role: "Technical Writer",
            tagline: "Update all project docs to match what you just shipped.",
            systemImage: "doc.richtext",
            marker: "You are running the `/document-release` workflow."
        ),
    ]

    // MARK: - Auto-selection

    static func autoPersona(for category: TaskCategory, hasAIRun: Bool) -> GStackPersona? {
        switch category {
        case .engineering:
            let id = hasAIRun ? "review" : "plan-eng-review"
            return all.first { $0.id == id && $0.isInstalled }
        case .design:
            return all.first { $0.id == "design-review" && $0.isInstalled }
        case .content, .marketing:
            return all.first { $0.id == "document-release" && $0.isInstalled }
        case .distribution:
            return all.first { $0.id == "ship" && $0.isInstalled }
        case .ops:
            return all.first { $0.id == "cso" && $0.isInstalled }
        case .research:
            return all.first { $0.id == "investigate" && $0.isInstalled }
        case .qa:
            return all.first { $0.id == "qa" && $0.isInstalled }
        case .other:
            return nil
        }
    }
}
