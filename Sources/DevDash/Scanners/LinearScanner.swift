import Foundation

// MARK: - Public model types

struct LinearTeam: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let key: String
}

struct LinearProject: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

struct LinearState: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let type: String    // triage | backlog | unstarted | started | completed | canceled
    let position: Double
}

struct LinearIssue: Identifiable, Codable, Hashable {
    let id: String
    let identifier: String   // e.g. "ENG-42"
    let title: String
    let description: String?
    let url: String
    let stateId: String
    let stateName: String
    let stateType: String
    let parentId: String?
    let createdAt: Date?
    let startedAt: Date?
    let completedAt: Date?
}

// MARK: - State cache (per-team, 5-min TTL)

private actor LinearStateCache {
    static let shared = LinearStateCache()
    private var entries: [String: (fetchedAt: Date, states: [LinearState])] = [:]
    private let ttl: TimeInterval = 5 * 60

    func get(_ teamId: String) -> [LinearState]? {
        guard let e = entries[teamId], Date().timeIntervalSince(e.fetchedAt) < ttl else { return nil }
        return e.states
    }

    func set(_ teamId: String, states: [LinearState]) {
        entries[teamId] = (Date(), states)
    }

    func clear() { entries.removeAll() }
}

// MARK: - Errors

enum LinearError: Error {
    case noAPIKey
    case httpError(Int)
    case graphQLErrors([String])
    case decodingError(Error)
}

// MARK: - Date parsing

/// Linear DateTime values use ISO 8601 with fractional seconds
/// (e.g. "2024-01-15T10:30:00.000Z"). A plain ISO8601DateFormatter
/// rejects fractional seconds, so we try the fractional form first
/// and fall back to the non-fractional form.
private func parseLinearDate(_ string: String) -> Date? {
    let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    let withoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    return withFractional.date(from: string) ?? withoutFractional.date(from: string)
}

// MARK: - Scanner

enum LinearScanner {
    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

    // MARK: - HTTP helper

    private static func graphQL(_ query: String, variables: [String: Any] = [:]) async throws -> Data {
        guard let key = KeychainStore.linearKey() else { throw LinearError.noAPIKey }

        var body: [String: Any] = ["query": query]
        if !variables.isEmpty { body["variables"] = variables }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw LinearError.httpError(http.statusCode)
        }

        // Surface GraphQL-level errors before the caller tries to decode data.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = obj["errors"] as? [[String: Any]], !errors.isEmpty {
            let msgs = errors.compactMap { $0["message"] as? String }
            throw LinearError.graphQLErrors(msgs)
        }

        return data
    }

    // MARK: - Teams

    static func fetchTeams() async -> [LinearTeam] {
        let query = """
        query { teams { nodes { id name key } } }
        """
        guard let data = try? await graphQL(query) else { return [] }
        struct R: Decodable {
            struct D: Decodable { struct T: Decodable { let nodes: [LinearTeam] }; let teams: T }
            let data: D
        }
        return (try? JSONDecoder().decode(R.self, from: data))?.data.teams.nodes ?? []
    }

    // MARK: - Projects

    static func fetchProjects(teamId: String) async -> [LinearProject] {
        let query = """
        query($id:String!){ team(id:$id){ projects { nodes { id name } } } }
        """
        guard let data = try? await graphQL(query, variables: ["id": teamId]) else { return [] }
        struct R: Decodable {
            struct D: Decodable {
                struct T: Decodable { struct P: Decodable { let nodes: [LinearProject] }; let projects: P }
                let team: T
            }
            let data: D
        }
        return (try? JSONDecoder().decode(R.self, from: data))?.data.team.projects.nodes ?? []
    }

    // MARK: - Workflow states

    static func fetchStates(teamId: String) async -> [LinearState] {
        if let cached = await LinearStateCache.shared.get(teamId) { return cached }

        let query = """
        query($id:String!){ team(id:$id){ states { nodes { id name type position } } } }
        """
        guard let data = try? await graphQL(query, variables: ["id": teamId]) else { return [] }
        struct StateNode: Decodable {
            let id: String; let name: String; let type: String; let position: Double
        }
        struct R: Decodable {
            struct D: Decodable {
                struct T: Decodable { struct S: Decodable { let nodes: [StateNode] }; let states: S }
                let team: T
            }
            let data: D
        }
        guard let nodes = (try? JSONDecoder().decode(R.self, from: data))?.data.team.states.nodes else {
            return []
        }
        let states = nodes.map { LinearState(id: $0.id, name: $0.name, type: $0.type, position: $0.position) }
        await LinearStateCache.shared.set(teamId, states: states)
        return states
    }

    // MARK: - Issues

    static func fetchIssues(teamId: String, projectId: String? = nil) async -> [LinearIssue] {
        // When a project is bound, filter by it via the project's issues endpoint.
        let query: String
        let variables: [String: Any]

        if let pid = projectId {
            query = """
            query($teamId:String!,$projectId:String!){
              team(id:$teamId){
                issues(first:100,filter:{project:{id:{eq:$projectId}}}){
                  nodes {
                    id identifier title description url
                    state { id name type }
                    parent { id }
                    createdAt startedAt completedAt
                  }
                }
              }
            }
            """
            variables = ["teamId": teamId, "projectId": pid]
        } else {
            query = """
            query($id:String!){
              team(id:$id){
                issues(first:100){
                  nodes {
                    id identifier title description url
                    state { id name type }
                    parent { id }
                    createdAt startedAt completedAt
                  }
                }
              }
            }
            """
            variables = ["id": teamId]
        }

        guard let data = try? await graphQL(query, variables: variables) else { return [] }

        struct RawState: Decodable { let id: String; let name: String; let type: String }
        struct RawParent: Decodable { let id: String }
        struct RawIssue: Decodable {
            let id: String
            let identifier: String
            let title: String
            let description: String?
            let url: String
            let state: RawState
            let parent: RawParent?
            let createdAt: String?
            let startedAt: String?
            let completedAt: String?
        }
        struct R: Decodable {
            struct D: Decodable {
                struct T: Decodable { struct I: Decodable { let nodes: [RawIssue] }; let issues: I }
                let team: T
            }
            let data: D
        }

        guard let nodes = (try? JSONDecoder().decode(R.self, from: data))?.data.team.issues.nodes else {
            return []
        }

        return nodes.map { raw in
            LinearIssue(
                id: raw.id,
                identifier: raw.identifier,
                title: raw.title,
                description: raw.description,
                url: raw.url,
                stateId: raw.state.id,
                stateName: raw.state.name,
                stateType: raw.state.type,
                parentId: raw.parent?.id,
                createdAt: raw.createdAt.flatMap { parseLinearDate($0) },
                startedAt: raw.startedAt.flatMap { parseLinearDate($0) },
                completedAt: raw.completedAt.flatMap { parseLinearDate($0) }
            )
        }
    }

    // MARK: - Mutations

    static func updateIssueState(issueId: String, stateId: String) async -> Bool {
        let mutation = """
        mutation($id:String!,$stateId:String!){
          issueUpdate(id:$id, input:{ stateId:$stateId }){
            success
            issue { id state { id name type } }
          }
        }
        """
        guard let data = try? await graphQL(mutation, variables: ["id": issueId, "stateId": stateId]) else {
            return false
        }
        struct R: Decodable {
            struct D: Decodable { struct U: Decodable { let success: Bool }; let issueUpdate: U }
            let data: D
        }
        return (try? JSONDecoder().decode(R.self, from: data))?.data.issueUpdate.success ?? false
    }

    static func createIssue(teamId: String, title: String, description: String? = nil,
                            stateId: String? = nil) async -> LinearIssue? {
        let mutation = """
        mutation($input:IssueCreateInput!){
          issueCreate(input:$input){
            success
            issue { id identifier url state { id name type } }
          }
        }
        """
        var input: [String: Any] = ["title": title, "teamId": teamId]
        if let d = description { input["description"] = d }
        if let s = stateId { input["stateId"] = s }

        guard let data = try? await graphQL(mutation, variables: ["input": input]) else { return nil }

        struct RawState: Decodable { let id: String; let name: String; let type: String }
        struct RawIssue: Decodable { let id: String; let identifier: String; let url: String; let state: RawState }
        struct R: Decodable {
            struct D: Decodable { struct C: Decodable { let success: Bool; let issue: RawIssue }; let issueCreate: C }
            let data: D
        }

        guard let raw = (try? JSONDecoder().decode(R.self, from: data))?.data.issueCreate,
              raw.success else { return nil }

        return LinearIssue(
            id: raw.issue.id,
            identifier: raw.issue.identifier,
            title: title,
            description: description,
            url: raw.issue.url,
            stateId: raw.issue.state.id,
            stateName: raw.issue.state.name,
            stateType: raw.issue.state.type,
            parentId: nil,
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil
        )
    }

    // MARK: - Status mapping

    /// Map a Linear workflow-state type to the app's TaskStatus.
    static func mapStatus(linearType: String) -> TaskStatus {
        switch linearType {
        case "started":   return .inProgress
        case "completed": return .done
        case "canceled":  return .skipped
        default:          return .open   // triage, backlog, unstarted
        }
    }

    /// Resolve the best Linear state ID for a given TaskStatus.
    /// States are sorted by position so the lowest-position match wins.
    static func stateId(for status: TaskStatus, in states: [LinearState]) -> String? {
        let sorted = states.sorted { $0.position < $1.position }
        switch status {
        case .open:
            // Prefer unstarted over backlog over triage.
            return sorted.first { $0.type == "unstarted" }?.id
                ?? sorted.first { $0.type == "backlog" }?.id
                ?? sorted.first { $0.type == "triage" }?.id
        case .inProgress:
            return sorted.first { $0.type == "started" }?.id
        case .blocked:
            return sorted.first { $0.type == "started" }?.id
        case .done:
            return sorted.first { $0.type == "completed" }?.id
        case .skipped:
            return sorted.first { $0.type == "canceled" }?.id
        }
    }

    // MARK: - Mapping to TaskItem

    static func toTaskItem(_ issue: LinearIssue) -> TaskItem {
        TaskItem(
            id: issue.id,
            title: issue.title,
            notes: issue.description,
            stage: nil,
            category: .engineering,
            source: .linear,
            status: mapStatus(linearType: issue.stateType),
            createdAt: issue.createdAt ?? Date(),
            startedAt: issue.startedAt,
            completedAt: issue.completedAt,
            ghIssueURL: nil,
            parentId: issue.parentId,
            owner: .none,
            hasAIRun: false,
            phases: nil,
            completedPhases: [],
            gstackPersonaOverride: nil,
            linkedDocPath: nil,
            linearIssueId: issue.id,
            linearIdentifier: issue.identifier,
            linearURL: issue.url
        )
    }
}
