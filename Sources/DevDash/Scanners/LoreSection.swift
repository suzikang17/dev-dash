import Foundation

/// A lore doc type surfaced as an editable section in the living document.
/// `dir` ≠ `loreType`: the folder is plural (docs/decisions), the lore CLI type
/// is the schema's singular `name` (decision). Mixing them breaks every CLI call
/// (`lore reindex decisions` → "unknown type"), so they are kept distinct.
struct LoreSection: Hashable {
    let dir: String                 // docs/<dir> — plural folder
    let loreType: String            // lore CLI type — singular schema name
    let label: String               // tab label
    let bodyIsFree: Bool            // true = `free` schema, false = `sections`
    let requiredSections: [String]  // required H2s (sections schema) — Swift section check
    let newDocFields: [String]      // `--field k=v` args so an authored doc validates

    static let all: [LoreSection] = [
        LoreSection(dir: "decisions", loreType: "decision", label: "Decisions",
                    bodyIsFree: false,
                    requiredSections: ["Why this choice", "Options considered", "Tradeoffs"],
                    newDocFields: []),   // decision also needs `date`; supplied at create time
        LoreSection(dir: "ideas", loreType: "idea", label: "Ideas",
                    bodyIsFree: true,
                    requiredSections: [],
                    newDocFields: ["status=raw"]),
        // Label is "Knowledge" (not "Notes") to avoid colliding with the existing
        // outliner Notes tab (sections/notes.html, which the Blocks view reads).
        LoreSection(dir: "notes", loreType: "note", label: "Knowledge",
                    bodyIsFree: true,
                    requiredSections: [],
                    newDocFields: []),   // local `note` type (docs/.lore/types/note.schema.yaml)
    ]

    /// Lookup by the plural folder name (e.g. derived from a doc's path).
    static func byDir(_ dir: String) -> LoreSection? {
        all.first { $0.dir == dir }
    }
}
