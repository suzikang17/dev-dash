import Foundation

enum GStackSkillLoader {
    static func persona(for skill: String, startingWith marker: String) -> String? {
        let path = NSHomeDirectory() + "/.claude/skills/gstack/\(skill)/SKILL.md"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let range = content.range(of: marker) else { return nil }
        return String(content[range.lowerBound...])
    }

    static var planPersona: String? {
        persona(for: "plan-eng-review", startingWith: "# Plan Review Mode")
    }

    static var reviewPersona: String? {
        persona(for: "review", startingWith: "You are running the `/review` workflow.")
    }

    static var securityPersona: String? {
        persona(for: "cso", startingWith: "You are a Chief Security Officer")
    }

    static var qaPersona: String? {
        persona(for: "qa", startingWith: "You are a QA engineer AND a bug-fix engineer.")
    }

    static var designPersona: String? {
        persona(for: "design-review", startingWith: "You are a senior product designer AND a frontend engineer.")
    }

    static var contentPersona: String? {
        persona(for: "document-release", startingWith: "You are running the `/document-release` workflow.")
    }

    static var shipPersona: String? {
        persona(for: "ship", startingWith: "You are running the `/ship` workflow.")
    }

    static var investigatePersona: String? {
        persona(for: "investigate", startingWith: "# Systematic Debugging")
    }
}
