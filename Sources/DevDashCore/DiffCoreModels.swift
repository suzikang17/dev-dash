import Foundation

public enum DiffRowKind: Equatable {
    case hunkHeader
    case context
    case added
    case removed
    case modified   // a removed line paired with an added line on one visual row
}

/// A changed character range within a single diff line, expressed as Character offsets.
public struct WordSpan: Equatable {
    public let start: Int
    public let length: Int
    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

/// One visual row of a side-by-side diff. `left*` is the base side, `right*` the new side.
public struct DiffRow: Equatable {
    public let kind: DiffRowKind
    public let leftLineNo: Int?
    public let leftText: String?
    public let rightLineNo: Int?
    public let rightText: String?
    public let leftSpans: [WordSpan]
    public let rightSpans: [WordSpan]
    public let headerText: String?   // only for .hunkHeader

    public init(kind: DiffRowKind,
                leftLineNo: Int? = nil, leftText: String? = nil,
                rightLineNo: Int? = nil, rightText: String? = nil,
                leftSpans: [WordSpan] = [], rightSpans: [WordSpan] = [],
                headerText: String? = nil) {
        self.kind = kind
        self.leftLineNo = leftLineNo
        self.leftText = leftText
        self.rightLineNo = rightLineNo
        self.rightText = rightText
        self.leftSpans = leftSpans
        self.rightSpans = rightSpans
        self.headerText = headerText
    }
}

public struct FileDiff: Equatable {
    public let rows: [DiffRow]
    public let isBinary: Bool
    public let tooLarge: Bool
    public init(rows: [DiffRow], isBinary: Bool = false, tooLarge: Bool = false) {
        self.rows = rows
        self.isBinary = isBinary
        self.tooLarge = tooLarge
    }

    /// Added-line count (added rows + the right side of modified rows).
    public var additions: Int {
        rows.reduce(0) { $0 + ($1.kind == .added || $1.kind == .modified ? 1 : 0) }
    }
    /// Removed-line count (removed rows + the left side of modified rows).
    public var deletions: Int {
        rows.reduce(0) { $0 + ($1.kind == .removed || $1.kind == .modified ? 1 : 0) }
    }
}

/// One file's diff within a multi-file diff (e.g. a whole commit).
public struct FileDiffSection: Equatable, Identifiable {
    public let path: String
    public let diff: FileDiff
    public var id: String { path }
    public init(path: String, diff: FileDiff) {
        self.path = path
        self.diff = diff
    }
}
