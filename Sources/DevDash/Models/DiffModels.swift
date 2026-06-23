import Foundation

struct ChangedFile: Identifiable, Hashable {
    let path: String            // repo-relative
    let stagedStatus: Character?    // index (X) column; nil if unmodified there
    let unstagedStatus: Character?  // worktree (Y) column; nil if unmodified there
    let isUntracked: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct GitCommit: Identifiable, Hashable {
    let sha: String
    let shortSha: String
    let subject: String
    let author: String
    let relativeDate: String
    var id: String { sha }
}

enum FileDiffSource: Hashable {
    case unstaged
    case staged
    case commit(String)
}

struct PRSummary: Identifiable, Hashable {
    let number: Int
    let title: String
    let state: String          // OPEN / MERGED / CLOSED
    let author: String
    let headRefName: String
    var id: Int { number }
}
