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

/// Parsed summary of a single Claude session, cached on disk so we don't
/// re-read multi-MB JSONLs every refresh.
struct SessionDigest: Codable, Identifiable, Hashable {
    let id: String                    // sessionId
    let projectPath: String
    let projectName: String
    let title: String?                // from `ai-title` line if present
    let firstUserMessage: String?
    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolCallsByName: [String: Int]
    let filesTouched: [FileTouch]
    let commandsRun: [CommandRun]
    let tokens: TokenUsage
    let parsedAt: Date

    struct FileTouch: Codable, Hashable {
        let path: String
        let reads: Int
        let writes: Int
        var total: Int { reads + writes }
    }

    struct CommandRun: Codable, Hashable {
        let command: String
        let timestamp: Date?
    }

    struct TokenUsage: Codable, Hashable {
        var input: Int = 0
        var output: Int = 0
        var cacheCreate: Int = 0
        var cacheRead: Int = 0
        var total: Int { input + output + cacheCreate + cacheRead }
    }
}

/// Full ordered transcript of a session, parsed on demand for the detail view.
struct SessionTranscript {
    let id: String
    let projectPath: String
    let projectName: String
    let turns: [Turn]

    struct Turn: Identifiable {
        let id: String
        let role: Role
        let timestamp: Date?
        let blocks: [Block]
        let tokens: SessionDigest.TokenUsage?

        enum Role: String { case user, assistant, system, tool, attachment }
    }

    enum Block {
        case text(String)
        case thinking(String)
        case toolUse(name: String, summary: String, fullInput: String)
        case toolResult(text: String, isError: Bool)
        case attachment(name: String, content: String)
    }
}

struct Todo: Identifiable, Codable, Hashable {
    let id: String
    var text: String
    var done: Bool
    var createdAt: String
    var doneAt: String?
}

// MARK: - Structured tasks (v2: stage + category + source)

enum TaskCategory: String, Codable, CaseIterable, Hashable {
    case engineering, design, content, marketing, distribution, ops, research, qa, other

    var label: String {
        switch self {
        case .qa: return "QA"
        default: return rawValue.capitalized
        }
    }
    var systemImage: String {
        switch self {
        case .engineering: return "hammer"
        case .design: return "paintbrush"
        case .content: return "doc.richtext"
        case .marketing: return "megaphone"
        case .distribution: return "shippingbox"
        case .ops: return "gearshape.2"
        case .research: return "magnifyingglass"
        case .qa: return "checkmark.shield"
        case .other: return "circle.dashed"
        }
    }
    var tint: String {
        switch self {
        case .engineering: return "blue"
        case .design: return "pink"
        case .content: return "purple"
        case .marketing: return "orange"
        case .distribution: return "teal"
        case .ops: return "gray"
        case .research: return "indigo"
        case .qa: return "red"
        case .other: return "secondary"
        }
    }
}

enum TaskSource: String, Codable, Hashable {
    case local, template, suggested, github

    var label: String {
        switch self {
        case .local: return "Local"
        case .template: return "Template"
        case .suggested: return "Suggested"
        case .github: return "GitHub"
        }
    }
}

enum TaskStatus: String, Codable, Hashable {
    case open
    case inProgress = "in_progress"   // legacy — migrated to open+ai in TaskStore
    case blocked
    case done
    case skipped

    var label: String {
        switch self {
        case .open:       return "Open"
        case .inProgress: return "In Progress"
        case .blocked:    return "Blocked"
        case .done:       return "Done"
        case .skipped:    return "Skipped"
        }
    }
}

enum TaskOwner: String, Codable, Hashable {
    case human, ai, none
}

enum KanbanColumn: String, CaseIterable {
    case backlog, speccing, aiWorking, blocked, reviewQA, done

    var label: String {
        switch self {
        case .backlog:   return "Backlog"
        case .speccing:  return "Speccing"
        case .aiWorking: return "AI Working"
        case .blocked:   return "Blocked"
        case .reviewQA:  return "Review & QA"
        case .done:      return "Done"
        }
    }

    var ownerIsHuman: Bool {
        switch self {
        case .backlog, .speccing, .blocked, .reviewQA: return true
        case .aiWorking, .done: return false
        }
    }
}

struct TaskItem: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var notes: String?
    var stage: String?              // template stage id; nil = unstaged
    var category: TaskCategory
    var source: TaskSource
    var status: TaskStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var ghIssueURL: URL?
    /// Optional parent task id. Top-level tasks have parentId=nil. A parent
    /// with children behaves as the "initiative" / "feature" grouping.
    var parentId: String? = nil
    var owner: TaskOwner = .none
    var hasAIRun: Bool = false
    var phases: [String]? = nil
    var completedPhases: [String] = []
    var gstackPersonaOverride: String? = nil

    var kanbanColumn: KanbanColumn {
        switch (status, owner, hasAIRun) {
        case (.done, _, _):                          return .done
        case (.blocked, _, _):                       return .blocked
        case (.open, .ai, _), (.inProgress, _, _):   return .aiWorking
        case (.open, .human, false):                 return .speccing
        case (.open, .human, true):                  return .reviewQA
        case (.skipped, _, _):                       return .done
        case (.open, .none, _):                      return .backlog
        }
    }
}

struct LiveFileEvent: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let operation: Operation
    let timestamp: Date

    enum Operation {
        case read, write, edit
        var systemImage: String {
            switch self {
            case .read:  return "eye"
            case .write: return "square.and.pencil"
            case .edit:  return "pencil"
            }
        }
        var label: String {
            switch self { case .read: return "read"; case .write: return "write"; case .edit: return "edit" }
        }
    }
}

/// Per-project metadata persisted to `.devdash/project.json`. Drives stage
/// gating and template application in the Tasks tab.
struct ProjectMeta: Codable, Hashable {
    var templateId: String?
    var currentStageId: String?
    var stageStartedAt: Date?
    var checkedExitCriteria: Set<String>  // keys: "<stageId>:<criterion>"
    var stageAnswers: [String: [String: String]]  // stageId → question → answer
    var roadmapPath: String?              // resolved at first scan
    var roadmapLastSeenMtime: Date?
    var notes: String?
    var customDevServerURL: String?
    var updatedAt: Date

    static let empty = ProjectMeta(
        templateId: nil, currentStageId: nil, stageStartedAt: nil,
        checkedExitCriteria: [], stageAnswers: [:], roadmapPath: nil,
        roadmapLastSeenMtime: nil, notes: nil, customDevServerURL: nil, updatedAt: Date()
    )

    func answer(for stageId: String, question: String) -> String {
        stageAnswers[stageId]?[question] ?? ""
    }
}

// MARK: - Launch templates
// Templates encode a methodology — sequence of stages, exit criteria,
// guiding questions. They never auto-create tasks. Tasks come from the
// user (with the tool's help) answering the questions.

struct LaunchTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let methodology: String     // overall philosophy; later seeds AI prompts
    let stages: [TemplateStage]
}

struct TemplateStage: Identifiable, Hashable {
    let id: String
    let title: String
    let purpose: String
    let methodology: String       // stage-level philosophy
    let guidingQuestions: [String]
    let exitCriteria: [String]
    let validationChecks: [HealthCheckSpec]   // sensible defaults per stage

    init(
        id: String,
        title: String,
        purpose: String,
        methodology: String,
        guidingQuestions: [String],
        exitCriteria: [String],
        validationChecks: [HealthCheckSpec] = []
    ) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.methodology = methodology
        self.guidingQuestions = guidingQuestions
        self.exitCriteria = exitCriteria
        self.validationChecks = validationChecks
    }
}

// MARK: - Validation / health checks

/// Template-defined check spec — the command to run for a given stage.
/// Intentionally constrained to template-defined commands for v1 (no
/// user-editable shell field) to keep the security surface tight.
struct HealthCheckSpec: Hashable {
    let id: String        // stable id, e.g. "build", "test", "lighthouse"
    let name: String      // human label, e.g. "Build"
    let stageId: String?  // nil = project-wide
    let command: String   // shell command run via /bin/zsh -ic
    let timeoutSeconds: Int
    let expectedExit: Int32

    init(
        id: String,
        name: String,
        stageId: String? = nil,
        command: String,
        timeoutSeconds: Int = 120,
        expectedExit: Int32 = 0
    ) {
        self.id = id
        self.name = name
        self.stageId = stageId
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.expectedExit = expectedExit
    }
}

struct HealthRunResult: Codable, Hashable {
    let checkId: String
    let stageId: String?
    let command: String
    let startedAt: Date
    let finishedAt: Date
    let exitCode: Int32
    let timedOut: Bool
    let stdoutTail: String
    let stderrTail: String
    var passed: Bool { !timedOut && exitCode == 0 }
    var durationSeconds: Int { max(0, Int(finishedAt.timeIntervalSince(startedAt))) }
}

enum HealthCheckStatus: String, Hashable {
    case unknown, running, passed, failed
}

// MARK: - Per-question chats with Claude

struct QuestionChatMessage: Codable, Identifiable, Hashable {
    let id: String          // uuid
    let role: Role
    var content: String
    let timestamp: Date

    enum Role: String, Codable, Hashable { case user, assistant }
}

// MARK: - Providers (third-party services used by a project)

enum ProviderCategory: String, Codable, CaseIterable, Hashable {
    case hosting, database, payments, email, ai, analytics, auth, monitoring, storage, cdn, search, proxy, other

    var label: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .hosting: return "cloud"
        case .database: return "cylinder.split.1x2"
        case .payments: return "creditcard"
        case .email: return "envelope"
        case .ai: return "sparkles"
        case .analytics: return "chart.bar"
        case .auth: return "key"
        case .monitoring: return "waveform.path.ecg"
        case .storage: return "externaldrive"
        case .cdn: return "globe.americas"
        case .search: return "magnifyingglass"
        case .proxy: return "network"
        case .other: return "circle.dashed"
        }
    }
}

enum ProviderDetectionSource: Codable, Hashable {
    case packageJSON(name: String)
    case envFile(key: String)
    case manual

    var label: String {
        switch self {
        case .packageJSON(let n): return "package.json: \(n)"
        case .envFile(let k):     return ".env: \(k)"
        case .manual:             return "manual"
        }
    }

    var isManual: Bool {
        if case .manual = self { return true }
        return false
    }
}

struct Provider: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var category: ProviderCategory
    var detectedFrom: ProviderDetectionSource
    var dashboardURL: URL?
    var monthlyEstimateUSD: Double?
    var notes: String?
    var addedAt: Date
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
    case info, preview, claude, tasks, product, files, logs
    var id: String { rawValue }

    var label: String {
        switch self {
        case .info: return "Info"
        case .preview: return "Preview"
        case .claude: return "Claude"
        case .tasks: return "Tasks"
        case .product: return "Product"
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
        case .product: return "doc.richtext"
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
    var currentPhase: String? = nil
    var completedPhases: [String] = []
    var phases: [String]? = nil
    var liveFiles: [LiveFileEvent] = []    // in-memory only — not Codable
    var liveCommands: [String] = []        // in-memory only — not Codable
    var linkedTaskId: String? = nil

    enum ClaudeTaskStatus: String {
        case running, completed, failed, cancelled
    }

    enum Kind: String, Codable {
        case general, recap, releaseNotes, taskExecution, taskSuggestion, roadmapUpdate

        var label: String {
            switch self {
            case .general:        return "Task"
            case .recap:          return "Recap"
            case .releaseNotes:   return "Release notes"
            case .taskExecution:  return "Run task"
            case .taskSuggestion: return "Suggest tasks"
            case .roadmapUpdate:  return "Roadmap update"
            }
        }

        var systemImage: String {
            switch self {
            case .general:        return "sparkles"
            case .recap:          return "newspaper"
            case .releaseNotes:   return "tag"
            case .taskExecution:  return "play.circle"
            case .taskSuggestion: return "lightbulb"
            case .roadmapUpdate:  return "map"
            }
        }

        var tint: String {
            switch self {
            case .general:        return "purple"
            case .recap:          return "indigo"
            case .releaseNotes:   return "teal"
            case .taskExecution:  return "blue"
            case .taskSuggestion: return "orange"
            case .roadmapUpdate:  return "green"
            }
        }
    }
}
