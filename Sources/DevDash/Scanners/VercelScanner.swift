import Foundation

/// One Vercel deployment, normalized from the REST API.
struct VercelDeployment: Identifiable, Hashable {
    let id: String
    let url: String             // host only, e.g. "myapp-abc123.vercel.app"
    let state: String           // READY / BUILDING / ERROR / QUEUED / CANCELED / INITIALIZING …
    let target: String?         // "production" — anything else (incl. nil) is a preview
    let createdAt: Date?
    let branch: String?         // meta.githubCommitRef
    let commitSha: String?      // meta.githubCommitSha
    let commitMessage: String?  // meta.githubCommitMessage
    let inspectorUrl: String?

    var isProduction: Bool { target == "production" }
    var deploymentURL: URL? { url.isEmpty ? nil : URL(string: "https://\(url)") }
}

/// `.vercel/project.json`, written by `vercel link`.
struct VercelProjectLink: Hashable {
    let projectId: String
    let orgId: String
}

/// Read-only Vercel integration. Auth piggybacks on the `vercel` CLI's stored
/// token (`vercel login`); data comes from the REST API (the CLI has no JSON
/// output). Every entry point fails soft so the UI can show a clear state.
enum VercelScanner {
    /// Outcome of a deployments fetch — lets the UI distinguish "set up Vercel"
    /// from "this project isn't linked" from a real error.
    enum FetchResult: Equatable {
        case notAuthenticated   // no `vercel login`
        case notLinked          // no `.vercel/project.json` in this project
        case ok([VercelDeployment])
        case failed(String)
    }

    // MARK: - Auth + linkage

    /// Bearer token the `vercel` CLI stored at login. nil if not logged in.
    static func authToken() -> String? {
        let path = NSHomeDirectory() + "/Library/Application Support/com.vercel.cli/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    static var isAuthenticated: Bool { authToken() != nil }

    /// projectId + orgId for a linked project. Handles both link formats:
    /// `.vercel/project.json` (single-project `vercel link`) and
    /// `.vercel/repo.json` (repo-level `vercel link --repo`, incl. monorepos).
    static func projectLink(_ projectPath: String) -> VercelProjectLink? {
        let dir = projectPath + "/.vercel"

        // Single-project link.
        if let obj = readJSONObject(dir + "/project.json"),
           let projectId = obj["projectId"] as? String, !projectId.isEmpty {
            return VercelProjectLink(projectId: projectId, orgId: obj["orgId"] as? String ?? "")
        }

        // Repo-level link: pick the project mapped to the repo root (directory
        // "."), else the first. orgId lives per-project, falling back to top level.
        if let obj = readJSONObject(dir + "/repo.json"),
           let projects = obj["projects"] as? [[String: Any]], !projects.isEmpty {
            let chosen = projects.first { ($0["directory"] as? String) == "." } ?? projects[0]
            if let id = chosen["id"] as? String, !id.isEmpty {
                let org = (chosen["orgId"] as? String) ?? (obj["orgId"] as? String) ?? ""
                return VercelProjectLink(projectId: id, orgId: org)
            }
        }
        return nil
    }

    private static func readJSONObject(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isLinked(_ projectPath: String) -> Bool { projectLink(projectPath) != nil }

    // MARK: - Deployments

    /// Fetch recent deployments for a linked project. Optional filters map to the
    /// REST API's `target` / `branch` / `sha` query params.
    static func deployments(projectPath: String, limit: Int = 20,
                            target: String? = nil, branch: String? = nil,
                            sha: String? = nil) async -> FetchResult {
        guard let token = authToken() else { return .notAuthenticated }
        guard let link = projectLink(projectPath) else { return .notLinked }

        var comps = URLComponents(string: "https://api.vercel.com/v6/deployments")!
        var items = [
            URLQueryItem(name: "projectId", value: link.projectId),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        // orgId is a team id only when it has the team_ prefix; personal accounts
        // omit teamId entirely.
        if link.orgId.hasPrefix("team_") {
            items.append(URLQueryItem(name: "teamId", value: link.orgId))
        }
        if let target { items.append(URLQueryItem(name: "target", value: target)) }
        if let branch { items.append(URLQueryItem(name: "branch", value: branch)) }
        if let sha { items.append(URLQueryItem(name: "sha", value: sha)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 401 || http.statusCode == 403 { return .notAuthenticated }
                return .failed("Vercel API returned \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(DeploymentsResponse.self, from: data)
            return .ok(decoded.deployments.map { $0.normalized })
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Convenience: the single most relevant preview deployment for a branch
    /// (used to link a PR to its Vercel preview). nil when none/unavailable.
    static func latestPreview(projectPath: String, branch: String) async -> VercelDeployment? {
        // The branch filter also matches production deployments of that ref, so
        // fetch a few and prefer the newest non-production (true preview) one.
        if case let .ok(deps) = await deployments(projectPath: projectPath, limit: 5, branch: branch) {
            return deps.first { !$0.isProduction } ?? deps.first
        }
        return nil
    }
}

// MARK: - REST decoding

private struct DeploymentsResponse: Decodable {
    let deployments: [Raw]

    struct Raw: Decodable {
        let uid: String
        let url: String?
        let state: String?
        let readyState: String?
        let target: String?
        let createdAt: Double?
        let created: Double?
        let inspectorUrl: String?
        let meta: Meta?

        struct Meta: Decodable {
            let githubCommitRef: String?
            let githubCommitSha: String?
            let githubCommitMessage: String?
        }

        var normalized: VercelDeployment {
            let ms = createdAt ?? created
            return VercelDeployment(
                id: uid,
                url: url ?? "",
                state: state ?? readyState ?? "UNKNOWN",
                target: target,
                createdAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
                branch: meta?.githubCommitRef,
                commitSha: meta?.githubCommitSha,
                commitMessage: meta?.githubCommitMessage,
                inspectorUrl: inspectorUrl
            )
        }
    }
}
