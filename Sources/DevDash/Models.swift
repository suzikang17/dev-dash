import Foundation

struct Service: Identifiable, Hashable {
    let id: String
    let pid: Int32
    let port: Int
    let name: String
    let cwd: String
    let framework: String
    let isInfra: Bool
    var url: String? { isInfra ? nil : "http://localhost:\(port)" }

    enum Role: String {
        case frontend, backend, unknown
        var label: String {
            switch self {
            case .frontend: return "Web"
            case .backend: return "API"
            case .unknown: return ""
            }
        }
        var systemImage: String {
            switch self {
            case .frontend: return "globe"
            case .backend: return "server.rack"
            case .unknown: return "circle.fill"
            }
        }
    }

    var role: Role {
        let f = framework.lowercased()
        let frontend: Set<String> = ["next.js", "vite", "nuxt", "cra", "angular",
                                     "sveltekit", "svelte", "astro", "remix"]
        let backend:  Set<String> = ["express", "fastify", "hono", "django",
                                     "flask", "rails", "ruby"]
        if frontend.contains(f) { return .frontend }
        if backend.contains(f)  { return .backend  }
        return .unknown
    }
}

struct RecentCommit: Identifiable, Hashable {
    let hash: String
    let subject: String
    let time: Date
    let author: String
    let projectPath: String
    let projectName: String

    var id: String { "\(projectPath)#\(hash)" }
    var shortHash: String { String(hash.prefix(7)) }
}

struct Project: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let stack: String?
    let framework: String
    let health: HealthStatus
    let lastCommitAt: Date?
    let branch: String?
    let githubURL: URL?
    let isGit: Bool

    var daysSinceCommit: Int? {
        guard let last = lastCommitAt else { return nil }
        return Calendar.current.dateComponents([.day], from: last, to: Date()).day
    }
}

enum HealthStatus: String, CaseIterable {
    case active, moderate, stale, archived, noGit

    var label: String {
        switch self {
        case .active: return "Active"
        case .moderate: return "Moderate"
        case .stale: return "Stale"
        case .archived: return "Archived"
        case .noGit: return "No git"
        }
    }
}

struct ClaudeSession: Identifiable, Hashable {
    let id: String   // sessionId
    let projectName: String
    let projectPath: String
    let lastActivity: Date?
    let messageCount: Int
    let firstUserMessage: String?
}

struct Todo: Identifiable, Codable, Hashable {
    let id: String
    var text: String
    var done: Bool
    var createdAt: String
    var doneAt: String?
}

struct Issue: Identifiable, Hashable {
    let number: Int
    let title: String
    let url: URL
    let state: String
    let updatedAt: Date?
    let labels: [String]

    var id: Int { number }
}

struct ProjectTasks: Identifiable, Hashable {
    let projectPath: String
    let projectName: String
    let repo: String?
    var todos: [Todo]
    var issues: [Issue]

    var id: String { projectPath }
}

enum Selection: Hashable {
    case home
    case service(serviceID: String)
    case project(path: String)

    var key: String {
        switch self {
        case .home: return "home"
        case .service(let id): return "service:\(id)"
        case .project(let path): return "project:\(path)"
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case info, preview, claude, tasks, docs, files, logs
    var id: String { rawValue }

    var label: String {
        switch self {
        case .info: return "Info"
        case .preview: return "Preview"
        case .claude: return "Claude"
        case .tasks: return "Tasks"
        case .docs: return "Docs"
        case .files: return "Files"
        case .logs: return "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .info: return "info.circle"
        case .preview: return "globe"
        case .claude: return "sparkles"
        case .tasks: return "checklist"
        case .docs: return "book"
        case .files: return "folder"
        case .logs: return "terminal"
        }
    }
}

struct FileNode: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?  // nil for files, lazy for directories

    var id: String { path }
}

struct ProjectRecap: Codable, Equatable {
    var summary: String
    var generatedAt: Date
    var includedSessions: [String]
    var includedCommits: [String]
}

struct ClaudeTask: Identifiable, Hashable {
    let id: UUID
    let projectPath: String
    let prompt: String
    let allowEdits: Bool
    let kind: Kind
    var output: [String]   // streaming lines
    var startedAt: Date
    var finishedAt: Date?
    var status: ClaudeTaskStatus
    var sessionId: String? // captured from claude output if available

    enum ClaudeTaskStatus: String {
        case running, completed, failed, cancelled
    }

    enum Kind: String, Codable {
        case general, recap, releaseNotes

        var label: String {
            switch self {
            case .general: return "Task"
            case .recap: return "Recap"
            case .releaseNotes: return "Release notes"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "sparkles"
            case .recap: return "newspaper"
            case .releaseNotes: return "tag"
            }
        }

        var tint: String {
            switch self {
            case .general: return "purple"
            case .recap: return "indigo"
            case .releaseNotes: return "teal"
            }
        }
    }
}
