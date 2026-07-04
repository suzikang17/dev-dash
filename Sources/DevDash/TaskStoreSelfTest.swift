import Foundation

/// Headless deterministic checks for TaskStore. Invoked from `DevDashApp.init()`.
///   DevDash --selftest-taskstore
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum TaskStoreSelfTest {
    static func runIfRequested() {
        // Diagnostic: --dump-tasks <projectPath> prints TaskStore.read() results.
        if let i = CommandLine.arguments.firstIndex(of: "--dump-tasks"),
           i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let tasks = TaskStore.read(path)
            print("dump-tasks \(path): \(tasks.count) task(s)")
            for t in tasks { print("  [\(t.id)] [\(t.status.rawValue)/\(t.owner.rawValue)] \(t.title)") }
            exit(0)
        }
        // Diagnostic: --dump-projects prints the scanned project paths + task counts.
        if CommandLine.arguments.contains("--dump-projects") {
            let sem = DispatchSemaphore(value: 0)
            Task {
                let projs = await ProjectScanner.scanAll()
                print("scanned \(projs.count) project(s):")
                for p in projs.sorted(by: { $0.path < $1.path }) {
                    print("  \(p.path)  (\(TaskStore.read(p.path).count) tasks)")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        // Diagnostic: --migrate-tickets <projectPath>
        // Runs TicketMigrator on the given path (point at a COPY of real data),
        // then prints the resulting tickets and tasks, plus marker/backup existence.
        if let i = CommandLine.arguments.firstIndex(of: "--migrate-tickets"),
           i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            print("migrate-tickets: running on \(path)")
            let result = TicketMigrator.migrate(projectPath: path)
            if result.skipped {
                print("  (skipped — marker already present)")
            } else {
                print("  tickets created: \(result.ticketsCreated)")
                print("  tasks repointed: \(result.tasksRepointed)")
            }
            let markerPath = "\(path)/.devdash/.tickets-migrated"
            let backupDir  = "\(path)/.devdash/migrated-tasks"
            let fm = FileManager.default
            print("  marker exists:   \(fm.fileExists(atPath: markerPath))")
            print("  backup dir exists: \(fm.fileExists(atPath: backupDir))")
            let tickets = TicketStore.read(path)
            print("tickets (\(tickets.count)):")
            for t in tickets {
                print("  [\(t.id)] [\(t.status.rawValue)] \(t.title)")
            }
            let tasks = TaskStore.read(path)
            print("tasks (\(tasks.count)):")
            for t in tasks {
                let ticketTag = t.ticket.map { "ticket=\($0)" } ?? "ticket=nil"
                let parentTag = t.parentId.map { "parent=\($0)" } ?? "parent=nil"
                print("  [\(t.id)] [\(ticketTag)] [\(parentTag)] \(t.title)")
            }
            exit(0)
        }
        guard CommandLine.arguments.contains("--selftest-taskstore") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkFullFieldRoundTrip(check)
        checkBlockScalarFrontmatter(check)
        checkAdversarialEscaping(check)
        checkNotesWithSentinelLines(check)
        checkPhasesWithCommas(check)
        checkUnknownKeyPreservation(check)
        checkNumericIdTolerance(check)
        checkSetStatusHistory(check)
        checkMigrationOneTime(check)
        checkSetPR(check)
        checkWorktreeFieldRoundTrip(check)
        checkWorktreeSlugNaming(check)
        checkWorktreeCollisionClassifier(check)
        checkWorktreeGrouping(check)
        checkTicketRoundTrip(check)
        checkTaskItemTicketField(check)
        checkTicketMigration(check)
        checkMigrationInterruptedRerun(check)
        checkMigrationOrphanParent(check)
        checkMigrationNonNumericId(check)
        checkMigrationFourLevelChain(check)
        checkMigrationUnknownKeysPreserved(check)
        checkPRReviewTaskCreation(check)
        checkPRNumberFromURL(check)

        let msg = failures.isEmpty
            ? "taskstore-selftest: ALL PASS"
            : "taskstore-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Helpers

    private static func makeTempProject(_ suffix: String) -> String {
        let dir = NSTemporaryDirectory() + "devdash-taskstore-selftest-\(suffix)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Check a2: YAML block-scalar frontmatter (lore CLI writes `title: >-`)

    private static func checkBlockScalarFrontmatter(_ check: (Bool, String) -> Void) {
        // Folded scalar (>-): continuation lines join with spaces.
        let folded = """
        ---
        lore_type: task
        title: >-
          Hook events: run a real claude session in a hook-installed project; confirm
          live card + Recent Claude events populate
        ticket: '0004'
        owner: human
        ---
        body
        """
        let fm1 = TaskStore.parseTaskFrontmatter(folded)
        check(fm1["title"] == "Hook events: run a real claude session in a hook-installed project; confirm live card + Recent Claude events populate",
              "a2: folded >- title joined with spaces")
        check(fm1["ticket"] == "0004",  "a2: key after block scalar still parsed")
        check(fm1["owner"] == "human",  "a2: subsequent keys unaffected")
        check(fm1["Hook events"] == nil, "a2: continuation line not misread as a key")

        // Literal scalar (|): continuation lines keep newlines.
        let literal = """
        ---
        title: |
          line one
          line two
        status: open
        ---
        """
        let fm2 = TaskStore.parseTaskFrontmatter(literal)
        check(fm2["title"] == "line one\nline two", "a2: literal | keeps newlines")
        check(fm2["status"] == "open",              "a2: key after literal scalar parsed")

        // Bare > and >+ variants also consume continuations.
        let bare = "---\ntitle: >\n  a b\n  c\nstatus: open\n---\n"
        let fm3 = TaskStore.parseTaskFrontmatter(bare)
        check(fm3["title"] == "a b c", "a2: bare > folds")

        // Plain single-line values still work (no regression).
        let plain = "---\ntitle: Simple title\nstatus: open\n---\n"
        check(TaskStore.parseTaskFrontmatter(plain)["title"] == "Simple title",
              "a2: plain scalar unchanged")
    }

    // MARK: - Check a: full-field round-trip

    private static func checkFullFieldRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("a")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(
                projectPath: proj,
                title: "Round-trip task",
                category: .engineering,
                stage: "alpha",
                notes: "Some notes here",
                source: .local,
                parentId: nil,
                linkedDocPath: "/docs/design.md"
            )
        } catch {
            check(false, "a: add threw \(error)"); return
        }

        // Set phases, ghIssue, and pr via update
        var modified = t
        modified.phases = ["Phase 1", "Phase 2"]
        modified.ghIssueURL = URL(string: "https://github.com/org/repo/issues/42")
        modified.pr = "https://github.com/org/repo/pull/7"
        do {
            try TaskStore.update(projectPath: proj, modified)
        } catch {
            check(false, "a: update threw \(error)"); return
        }

        let tasks = TaskStore.read(proj)
        guard let read = tasks.first(where: { $0.id == t.id }) else {
            check(false, "a: task not found after read"); return
        }

        check(read.title == "Round-trip task",        "a: title round-trip")
        check(read.notes == "Some notes here",         "a: notes round-trip")
        check(read.category == .engineering,           "a: category round-trip")
        check(read.stage == "alpha",                   "a: stage round-trip")
        check(read.source == .local,                   "a: source round-trip")
        check(read.status == .open,                    "a: status round-trip")
        check(read.parentId == nil,                    "a: parentId nil round-trip")
        check(read.linkedDocPath == "/docs/design.md", "a: linkedDocPath round-trip")
        check(read.phases == ["Phase 1", "Phase 2"],   "a: phases round-trip")
        check(read.ghIssueURL?.absoluteString == "https://github.com/org/repo/issues/42",
              "a: ghIssueURL round-trip")
        check(read.pr == "https://github.com/org/repo/pull/7", "a: pr round-trip")
    }

    // MARK: - Check b: adversarial title/notes escaping

    private static func checkAdversarialEscaping(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("b")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let weirdTitle = #"She said \"hi\" \ path"#
        let weirdNotes = #"notes with "quotes", backslash \ colon: and # hash"#

        let t: TaskItem
        do {
            t = try TaskStore.add(
                projectPath: proj,
                title: weirdTitle,
                notes: weirdNotes
            )
        } catch {
            check(false, "b: add threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "b: task not found after first read"); return
        }

        check(read1.title == weirdTitle,  "b: title with quotes+backslash preserved on first read")
        check(read1.notes == weirdNotes,  "b: notes with special chars preserved on first read")

        // Now update (change status to done) and re-read — assert no compounding corruption.
        var modified = read1
        modified.status = .done
        do {
            try TaskStore.update(projectPath: proj, modified)
        } catch {
            check(false, "b: update threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "b: task not found after update+read"); return
        }

        check(read2.title == weirdTitle, "b: title preserved after update round-trip")
        check(read2.notes == weirdNotes, "b: notes preserved after update round-trip")
    }

    // MARK: - Check c: notes containing sentinel and heading lines

    private static func checkNotesWithSentinelLines(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("c")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // Notes that contain strings that look like the sentinel and a heading.
        let notes = "Intro line\n## Status history\nSome user content\n# Some Heading\nMore content"

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Sentinel test", notes: notes)
        } catch {
            check(false, "c: add threw \(error)"); return
        }

        let tasks = TaskStore.read(proj)
        guard let read = tasks.first(where: { $0.id == t.id }) else {
            check(false, "c: task not found after read"); return
        }

        check(read.notes == notes, "c: notes containing '## Status history' and '# Some Heading' fully preserved")
    }

    // MARK: - Check d: phases with commas

    private static func checkPhasesWithCommas(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("d")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Phases task")
        } catch {
            check(false, "d: add threw \(error)"); return
        }

        let commaPhase = "Design, build, ship"
        let otherPhase = "Test"
        do {
            try TaskStore.setPhases(projectPath: proj, id: t.id, phases: [commaPhase, otherPhase])
        } catch {
            check(false, "d: setPhases threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "d: task not found after setPhases"); return
        }

        check(read1.phases?.count == 2, "d: comma-containing phase name survives as ONE phase (count==2), got \(read1.phases?.count ?? -1)")
        check(read1.phases?.contains(commaPhase) == true, "d: comma phase name round-trips exactly")
        check(read1.phases?.contains(otherPhase) == true, "d: second phase name preserved")

        // addCompletedPhase with the comma-containing name.
        do {
            try TaskStore.addCompletedPhase(projectPath: proj, id: t.id, phase: commaPhase)
        } catch {
            check(false, "d: addCompletedPhase threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "d: task not found after addCompletedPhase"); return
        }

        check(read2.completedPhases.contains(commaPhase), "d: completedPhases contains comma phase after add")
        check(read2.completedPhases.count == 1,            "d: no duplicate in completedPhases (count==1), got \(read2.completedPhases.count)")

        // Call addCompletedPhase again with the same name — should be idempotent.
        do {
            try TaskStore.addCompletedPhase(projectPath: proj, id: t.id, phase: commaPhase)
        } catch {
            check(false, "d: second addCompletedPhase threw \(error)"); return
        }

        let tasks3 = TaskStore.read(proj)
        guard let read3 = tasks3.first(where: { $0.id == t.id }) else {
            check(false, "d: task not found after second addCompletedPhase"); return
        }

        check(read3.completedPhases.count == 1, "d: addCompletedPhase is idempotent (still count==1), got \(read3.completedPhases.count)")
    }

    // MARK: - Check e: unknown-key preservation

    private static func checkUnknownKeyPreservation(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("e")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Unknown keys task")
        } catch {
            check(false, "e: add threw \(error)"); return
        }

        // Inject unknown frontmatter keys directly into the file.
        let dir = TaskStore.file(for: proj)
        guard let filename = TaskStore.findFile(id: t.id, in: dir) else {
            check(false, "e: can't find task file"); return
        }
        let path = "\(dir)/\(filename)"
        guard var raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "e: can't read task file"); return
        }

        // Insert unknown keys before closing --- fence.
        raw = TaskStore.setOrAddFrontmatterKey(in: raw, key: "devdash_id", value: "\"abc-123\"")
        raw = TaskStore.setOrAddFrontmatterKey(in: raw, key: "pr", value: "\"https://x/y/1\"")
        do {
            try raw.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            check(false, "e: can't write injected keys: \(error)"); return
        }

        // Now call setStatus and setOwner — these do in-place edits.
        do {
            try TaskStore.setStatus(projectPath: proj, id: t.id, status: .inProgress)
            try TaskStore.setOwner(projectPath: proj, id: t.id, owner: .ai)
        } catch {
            check(false, "e: setStatus/setOwner threw \(error)"); return
        }

        // Read raw file back and verify unknown keys still present.
        guard let rawAfter = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "e: can't re-read file after mutations"); return
        }

        check(rawAfter.contains("devdash_id:"), "e: devdash_id key preserved after setStatus+setOwner")
        check(rawAfter.contains("abc-123"),     "e: devdash_id value preserved")
        check(rawAfter.contains("pr:"),         "e: pr key preserved after setStatus+setOwner")
        check(rawAfter.contains("https://x/y/1"), "e: pr value preserved")

        // Also call update() and verify again.
        let tasks = TaskStore.read(proj)
        if let readTask = tasks.first(where: { $0.id == t.id }) {
            var mut = readTask
            mut.status = .done
            do {
                try TaskStore.update(projectPath: proj, mut)
            } catch {
                check(false, "e: update threw \(error)"); return
            }

            guard let rawAfterUpdate = try? String(contentsOfFile: path, encoding: .utf8) else {
                check(false, "e: can't re-read file after update()"); return
            }
            check(rawAfterUpdate.contains("devdash_id:"),     "e: devdash_id preserved after update()")
            check(rawAfterUpdate.contains("pr:"),             "e: pr key preserved after update()")
        } else {
            check(false, "e: task not found for update() phase")
        }
    }

    // MARK: - Check f: numeric id tolerance and cascade delete

    private static func checkNumericIdTolerance(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("f")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let dir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            check(false, "f: createDirectory threw \(error)"); return
        }

        // Write files with non-zero-padded names directly (as lore CLI would).
        let parentDoc = """
            ---
            lore_type: task
            title: "Parent"
            status: open
            category: other
            source: local
            created: 2026-06-01
            ---
            # Parent
            """
        let childDoc = """
            ---
            lore_type: task
            title: "Child"
            status: open
            category: other
            source: local
            created: 2026-06-01
            parent: "1"
            ---
            # Child
            """

        do {
            try parentDoc.write(toFile: "\(dir)/1-foo.md", atomically: true, encoding: .utf8)
            try childDoc.write(toFile: "\(dir)/2-bar.md",  atomically: true, encoding: .utf8)
        } catch {
            check(false, "f: writing test files threw \(error)"); return
        }

        check(TaskStore.hasChildren(projectPath: proj, id: "1"),
              "f: hasChildren(\"1\") is true when child has parent: \"1\"")

        // Cascade delete of "1" should also remove "2".
        do {
            try TaskStore.delete(projectPath: proj, id: "1")
        } catch {
            check(false, "f: delete threw \(error)"); return
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let mdFiles = files.filter { $0.hasSuffix(".md") }
        check(mdFiles.isEmpty, "f: cascade delete removed both parent and child (got \(mdFiles))")
    }

    // MARK: - Check g: setStatus history + dates

    private static func checkSetStatusHistory(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("g")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Status history task",
                                  notes: "User content here")
        } catch {
            check(false, "g: add threw \(error)"); return
        }

        // Transition open → done.
        do {
            try TaskStore.setStatus(projectPath: proj, id: t.id, status: .done)
        } catch {
            check(false, "g: setStatus threw \(error)"); return
        }

        let dir = TaskStore.file(for: proj)
        guard let filename = TaskStore.findFile(id: t.id, in: dir),
              let rawAfter = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else {
            check(false, "g: can't read file after setStatus"); return
        }

        let fm = TaskStore.parseTaskFrontmatter(rawAfter)
        check(fm["status"] == "done",                     "g: status frontmatter == done")
        check(fm["completed"] != nil && !fm["completed"]!.isEmpty,
              "g: completed date set after ->done")
        check(rawAfter.contains(TaskStore.statusHistorySentinel),
              "g: sentinel present in file")
        check(rawAfter.contains("## Status history"),     "g: ## Status history heading present")
        check(rawAfter.contains("open → done"),           "g: history entry records open->done transition")

        // Notes should still be extractable and clean.
        let tasks = TaskStore.read(proj)
        guard let read = tasks.first(where: { $0.id == t.id }) else {
            check(false, "g: task not found after setStatus+read"); return
        }

        check(read.notes == "User content here", "g: notes clean after setStatus (sentinel not leaked)")
        check(read.status == .done,              "g: status reads back as done")
    }

    // MARK: - Check i: setPR setter

    private static func checkSetPR(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("i")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "PR setter task",
                                  notes: "Some notes")
        } catch {
            check(false, "i: add threw \(error)"); return
        }

        // Set a PR URL.
        let prURL = "https://github.com/org/repo/pull/42"
        do {
            try TaskStore.setPR(projectPath: proj, id: t.id, url: prURL)
        } catch {
            check(false, "i: setPR threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "i: task not found after setPR"); return
        }
        check(read1.pr == prURL, "i: pr field set correctly (got \(read1.pr ?? "nil"))")

        // Notes and other fields must survive the in-place edit.
        check(read1.notes == "Some notes", "i: notes preserved after setPR")
        check(read1.title == "PR setter task", "i: title preserved after setPR")

        // Clear the PR URL (nil).
        do {
            try TaskStore.setPR(projectPath: proj, id: t.id, url: nil)
        } catch {
            check(false, "i: setPR(nil) threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "i: task not found after setPR(nil)"); return
        }
        check(read2.pr == nil, "i: pr field cleared after setPR(nil) (got \(read2.pr ?? "nil"))")

        // Verify raw file no longer has the pr: key.
        let dir = TaskStore.file(for: proj)
        if let filename = TaskStore.findFile(id: t.id, in: dir),
           let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8) {
            let fm = TaskStore.parseTaskFrontmatter(raw)
            check(fm["pr"] == nil, "i: pr key absent from frontmatter after clear")
        } else {
            check(false, "i: can't read file for raw verification")
        }

        // DashboardStore helpers: isGHPRCreate and parsePRURL.
        check(DashboardStore.isGHPRCreate("gh pr create --title foo"),
              "i: isGHPRCreate matches 'gh pr create --title foo'")
        check(DashboardStore.isGHPRCreate("git add . && gh pr create"),
              "i: isGHPRCreate matches after &&")
        check(!DashboardStore.isGHPRCreate("echo \"gh pr create\""),
              "i: isGHPRCreate does NOT match echo")
        check(!DashboardStore.isGHPRCreate("gh pr list"),
              "i: isGHPRCreate does NOT match 'gh pr list'")
        check(!DashboardStore.isGHPRCreate("gh pr"),
              "i: isGHPRCreate does NOT match bare 'gh pr'")

        let sampleOutput = "https://github.com/org/repo/pull/99\n"
        check(DashboardStore.parsePRURL(from: sampleOutput) == "https://github.com/org/repo/pull/99",
              "i: parsePRURL extracts PR URL from gh output")
        check(DashboardStore.parsePRURL(from: "no url here") == nil,
              "i: parsePRURL returns nil for non-URL output")

        // kanbanColumn guard: a done task is NOT in aiWorking, so the PR promotion
        // block must not touch it (isGHPRCreate gate only fires when kanbanColumn == .aiWorking).
        let projDone = makeTempProject("i-done")
        defer { try? FileManager.default.removeItem(atPath: projDone) }
        let td: TaskItem
        do {
            td = try TaskStore.add(projectPath: projDone, title: "Done task")
        } catch {
            check(false, "i: done-task add threw \(error)"); return
        }
        // Mark done and owner=.ai to confirm kanbanColumn != .aiWorking when status==.done.
        do {
            try TaskStore.setStatus(projectPath: projDone, id: td.id, status: .done)
            try TaskStore.setOwner(projectPath: projDone, id: td.id, owner: .ai)
        } catch {
            check(false, "i: done-task setup threw \(error)"); return
        }
        let doneTasks = TaskStore.read(projDone)
        if let doneTask = doneTasks.first(where: { $0.id == td.id }) {
            check(doneTask.kanbanColumn != .aiWorking,
                  "i: done task is NOT in aiWorking (kanban=\(doneTask.kanbanColumn))")
            // Simulate what the PostToolUse block does: only act when kanbanColumn == .aiWorking.
            let wouldPromote = doneTask.kanbanColumn == .aiWorking
            check(!wouldPromote, "i: done task would NOT be promoted by PR gate (aiWorking guard)")
        } else {
            check(false, "i: done task not found after setup")
        }
    }

    // MARK: - Check k: worktree field round-trip

    private static func checkWorktreeFieldRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("k")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // Add a task then set worktree + branch via TaskStore.setWorktree.
        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Worktree round-trip task",
                                  notes: "Some notes")
        } catch {
            check(false, "k: add threw \(error)"); return
        }

        let wt = "/repos/myapp/.worktrees/task-0001-worktree-round-trip"
        let br = "task/0001-worktree-round-trip"
        do {
            try TaskStore.setWorktree(projectPath: proj, id: t.id, worktree: wt, branch: br)
        } catch {
            check(false, "k: setWorktree threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "k: task not found after setWorktree"); return
        }
        check(read1.worktree == wt, "k: worktree field round-trips (got \(read1.worktree ?? "nil"))")
        check(read1.branch == br,   "k: branch field round-trips (got \(read1.branch ?? "nil"))")
        check(read1.notes == "Some notes", "k: notes preserved after setWorktree")
        check(read1.title == "Worktree round-trip task", "k: title preserved after setWorktree")

        // Clear via update() round-trip.
        var modified = read1
        modified.worktree = nil
        modified.branch = nil
        do {
            try TaskStore.update(projectPath: proj, modified)
        } catch {
            check(false, "k: update (clear) threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "k: task not found after clear"); return
        }
        check(read2.worktree == nil, "k: worktree cleared via update (got \(read2.worktree ?? "nil"))")
        check(read2.branch == nil,   "k: branch cleared via update (got \(read2.branch ?? "nil"))")

        // Also verify setWorktree(nil) path.
        do {
            try TaskStore.setWorktree(projectPath: proj, id: t.id, worktree: wt, branch: br)
            try TaskStore.setWorktree(projectPath: proj, id: t.id, worktree: nil, branch: nil)
        } catch {
            check(false, "k: setWorktree(nil) threw \(error)"); return
        }
        let tasks3 = TaskStore.read(proj)
        guard let read3 = tasks3.first(where: { $0.id == t.id }) else {
            check(false, "k: task not found after setWorktree(nil)"); return
        }
        check(read3.worktree == nil, "k: worktree absent after setWorktree(nil)")
        check(read3.branch == nil,   "k: branch absent after setWorktree(nil)")

        // Raw file must not contain worktree: or branch: keys after clear.
        let dir = TaskStore.file(for: proj)
        if let filename = TaskStore.findFile(id: t.id, in: dir),
           let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8) {
            let fm = TaskStore.parseTaskFrontmatter(raw)
            check(fm["worktree"] == nil, "k: worktree key absent from frontmatter after clear")
            check(fm["branch"] == nil,   "k: branch key absent from frontmatter after clear")
        } else {
            check(false, "k: can't read file for raw verification")
        }
    }

    // MARK: - Check l: WorktreeManager slug naming + sanitisation

    private static func checkWorktreeSlugNaming(_ check: (Bool, String) -> Void) {
        // Pure function — no filesystem I/O.
        let cases: [(taskId: String, title: String, expectedBranch: String, expectedDir: String)] = [
            ("0042", "Add user auth",
             "task/0042-add-user-auth",  "task-0042-add-user-auth"),
            ("0001", "Fix: the \"weird\" bug / issue #3",
             "task/0001-fix-the-weird-bug-issue-3", "task-0001-fix-the-weird-bug-issue-3"),
            ("0007", "  UPPER CASE  ",
             "task/0007-upper-case", "task-0007-upper-case"),
            ("0099", String(repeating: "a", count: 80),
             // slug is capped at 40 chars
             "task/0099-" + String(repeating: "a", count: 40),
             "task-0099-" + String(repeating: "a", count: 40)),
            ("0003", "!!!",
             // all unsafe chars stripped → slug falls back to "task"
             "task/0003-task", "task-0003-task"),
        ]

        for (id, title, expBranch, expDir) in cases {
            let (branch, dirName) = WorktreeManager.slugBranch(taskId: id, title: title)
            check(branch == expBranch,
                  "l: slugBranch branch for '\(title)' → '\(branch)' (expected '\(expBranch)')")
            check(dirName == expDir,
                  "l: slugBranch dirName for '\(title)' → '\(dirName)' (expected '\(expDir)')")
        }

        // makeSlug corner cases.
        check(WorktreeManager.makeSlug("hello world") == "hello-world",
              "l: makeSlug 'hello world' → 'hello-world'")
        check(WorktreeManager.makeSlug("a--b") == "a-b",
              "l: makeSlug collapses double hyphens")
        check(WorktreeManager.makeSlug("") == "task",
              "l: makeSlug empty → 'task'")
        check(WorktreeManager.makeSlug("-leading-and-trailing-") == "leading-and-trailing",
              "l: makeSlug trims leading/trailing hyphens")
    }

    // MARK: - Check m: WorktreeManager.isCollisionError classifier

    /// Pure function — no I/O, no git mutations.
    private static func checkWorktreeCollisionClassifier(_ check: (Bool, String) -> Void) {
        // Phrases that ARE name collisions → should retry with uniquified name.
        let shouldRetry: [(String, String)] = [
            ("fatal: 'task/0001-foo' already exists", "m: 'already exists' is a collision"),
            ("error: branch 'task/0001-foo' already exists", "m: branch already exists is a collision"),
            ("fatal: '/path/.worktrees/task-0001-foo' already checked out", "m: already checked out is a collision"),
            ("error: worktree '/x' already checked out at '/y'", "m: already checked out (alt form) is a collision"),
            ("fatal: already used by worktree at '/path'", "m: already used by worktree is a collision"),
        ]
        for (msg, label) in shouldRetry {
            check(WorktreeManager.isCollisionError(msg.lowercased()), label)
        }

        // Phrases that are NOT collisions → should NOT trigger retry (return nil immediately).
        let shouldNotRetry: [(String, String)] = [
            ("fatal: not a git repository", "m: not a git repository is NOT a collision"),
            ("error: pathspec 'x' did not match any file(s)", "m: pathspec error is NOT a collision"),
            ("fatal: cannot lock ref 'refs/heads/task/foo'", "m: lock ref error is NOT a collision"),
            ("fatal: insufficient permission for adding an object", "m: permission error is NOT a collision"),
            ("error: unable to create file: no space left on device", "m: disk full is NOT a collision"),
            // 'branch' appearing in a non-collision context must NOT match
            ("fatal: branch name required", "m: bare 'branch name required' is NOT a collision"),
            ("error: invalid branch name 'task/foo bar'", "m: invalid branch name is NOT a collision"),
        ]
        for (msg, label) in shouldNotRetry {
            check(!WorktreeManager.isCollisionError(msg.lowercased()), label)
        }
    }

    // MARK: - Check j: worktree grouping

    /// Pure unit test for SidebarView.groupWorktrees. No filesystem I/O needed.
    private static func checkWorktreeGrouping(_ check: (Bool, String) -> Void) {
        // Helper: build a minimal Project fixture.
        func proj(_ path: String) -> Project {
            Project(
                id: path,
                name: (path as NSString).lastPathComponent,
                path: path,
                stack: nil,
                framework: "",
                health: .active,
                lastCommitAt: nil,
                branch: "main",
                githubURL: nil,
                isGit: true
            )
        }

        // Helper: build a GitStatus with a specific worktrees array.
        func makeStatus(worktrees: [GitStatus.Worktree]) -> GitStatus {
            GitStatus(
                branch: "main",
                upstream: nil,
                aheadCount: 0,
                behindCount: 0,
                stagedCount: 0,
                unstagedCount: 0,
                untrackedCount: 0,
                stashCount: 0,
                localBranches: [],
                worktrees: worktrees
            )
        }

        // --- Fixture (a): standalone project with no gitStatus ---
        let standalone = proj("/repos/solo")
        let groupsA = SidebarView.groupWorktrees([standalone], gitStatuses: [:])
        check(groupsA.count == 1,                     "j-a: standalone → exactly 1 group")
        check(groupsA[0].parent.path == "/repos/solo", "j-a: parent is the standalone project")
        check(groupsA[0].children.isEmpty,             "j-a: standalone has no children")

        // --- Fixture (b): main + 2 worktrees, all three in the project list ---
        // worktrees[0] is isMain (primary checkout — always first in git output).
        let mainProj   = proj("/repos/myapp")
        let wt1Proj    = proj("/repos/myapp-feat-a")
        let wt2Proj    = proj("/repos/myapp-feat-b")

        let wtMain = GitStatus.Worktree(path: "/repos/myapp",        branch: "main",   isMain: true)
        let wtA    = GitStatus.Worktree(path: "/repos/myapp-feat-a", branch: "feat-a", isMain: false)
        let wtB    = GitStatus.Worktree(path: "/repos/myapp-feat-b", branch: "feat-b", isMain: false)
        let status = makeStatus(worktrees: [wtMain, wtA, wtB])

        // All three projects share the same gitStatus (same repo — scanner returns
        // the full worktree list from any checkout path).
        let statuses: [String: GitStatus] = [
            "/repos/myapp":        status,
            "/repos/myapp-feat-a": status,
            "/repos/myapp-feat-b": status,
        ]

        let groupsB = SidebarView.groupWorktrees([mainProj, wt1Proj, wt2Proj], gitStatuses: statuses)
        check(groupsB.count == 1,                       "j-b: 3 worktree projects → 1 group")
        check(groupsB[0].parent.path == "/repos/myapp", "j-b: main checkout is the parent")
        check(groupsB[0].children.count == 2,           "j-b: 2 children")
        // Neither child appears in its own group.
        let allParentPaths = groupsB.map { $0.parent.path }
        check(!allParentPaths.contains("/repos/myapp-feat-a"), "j-b: feat-a is not a parent")
        check(!allParentPaths.contains("/repos/myapp-feat-b"), "j-b: feat-b is not a parent")

        // --- Fixture (c): worktree present but main checkout NOT in project list ---
        // Only the two linked worktrees are scanned; main lives outside the scan roots.
        let groupsC = SidebarView.groupWorktrees([wt1Proj, wt2Proj], gitStatuses: statuses)
        check(groupsC.count == 1,     "j-c: main absent → still 1 group (not dropped)")
        check(!groupsC.isEmpty,       "j-c: group is non-empty")
        // The fallback parent should be one of the two worktrees (first member).
        let cParentPath = groupsC[0].parent.path
        check(cParentPath == "/repos/myapp-feat-a" || cParentPath == "/repos/myapp-feat-b",
              "j-c: fallback parent is one of the two worktrees (got \(cParentPath))")
        check(groupsC[0].children.count == 1,
              "j-c: 1 child under fallback parent (got \(groupsC[0].children.count))")
    }

    // MARK: - Check n: Ticket round-trip

    private static func checkTicketRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("n")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // Add a ticket.
        let t: Ticket
        do {
            t = try TicketStore.add(
                projectPath: proj,
                title: "Round-trip ticket",
                category: .engineering,
                owner: .human,
                notes: "Some ticket notes"
            )
        } catch {
            check(false, "n: TicketStore.add threw \(error)"); return
        }

        let tickets1 = TicketStore.read(proj)
        guard let read1 = tickets1.first(where: { $0.id == t.id }) else {
            check(false, "n: ticket not found after add+read"); return
        }

        check(read1.title    == "Round-trip ticket", "n: title round-trip")
        check(read1.notes    == "Some ticket notes",  "n: notes round-trip")
        check(read1.category == .engineering,          "n: category round-trip")
        check(read1.owner    == .human,                "n: owner round-trip")
        check(read1.status   == .open,                 "n: status defaults to open")

        // Update: change status + inject a pr, verify unknown keys survive.
        // First inject an unknown key directly into the file.
        let ticketDir = TicketStore.dir(for: proj)
        guard let fname = TicketStore.findFile(id: t.id, in: ticketDir) else {
            check(false, "n: can't find ticket file"); return
        }
        let path = "\(ticketDir)/\(fname)"
        guard var raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "n: can't read ticket file"); return
        }
        raw = TaskStore.setOrAddFrontmatterKey(in: raw, key: "devdash_test_key",
                                               value: "\"preserved\"")
        try? raw.write(toFile: path, atomically: true, encoding: .utf8)

        // update() via TicketStore.update.
        var modified = read1
        modified.status = .done
        modified.pr     = "https://github.com/org/repo/pull/5"
        do {
            try TicketStore.update(projectPath: proj, modified)
        } catch {
            check(false, "n: TicketStore.update threw \(error)"); return
        }

        let tickets2 = TicketStore.read(proj)
        guard let read2 = tickets2.first(where: { $0.id == t.id }) else {
            check(false, "n: ticket not found after update"); return
        }

        check(read2.status == .done,                                    "n: status updated to done")
        check(read2.pr     == "https://github.com/org/repo/pull/5",     "n: pr field set")
        check(read2.title  == "Round-trip ticket",                       "n: title preserved after update")
        check(read2.notes  == "Some ticket notes",                       "n: notes preserved after update")

        // Verify unknown key survived update().
        guard let rawAfterUpdate = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "n: can't re-read ticket file after update"); return
        }
        check(rawAfterUpdate.contains("devdash_test_key"), "n: unknown key preserved after update()")
        check(rawAfterUpdate.contains("preserved"),        "n: unknown key value preserved after update()")

        // setStatus: open → done → check history sentinel.
        let proj2 = makeTempProject("n2")
        defer { try? FileManager.default.removeItem(atPath: proj2) }
        let t2: Ticket
        do {
            t2 = try TicketStore.add(projectPath: proj2, title: "Status history ticket",
                                     notes: "User notes")
        } catch {
            check(false, "n2: add threw \(error)"); return
        }
        do {
            try TicketStore.setStatus(projectPath: proj2, id: t2.id, status: .done)
        } catch {
            check(false, "n2: setStatus threw \(error)"); return
        }
        let dir2 = TicketStore.dir(for: proj2)
        if let fname2 = TicketStore.findFile(id: t2.id, in: dir2),
           let rawAfter = try? String(contentsOfFile: "\(dir2)/\(fname2)", encoding: .utf8) {
            let fm2 = TaskStore.parseTaskFrontmatter(rawAfter)
            check(fm2["status"] == "done",                    "n2: status frontmatter == done")
            check(fm2["completed"] != nil,                    "n2: completed date set")
            check(rawAfter.contains(TaskStore.statusHistorySentinel),
                  "n2: sentinel present after setStatus")
            check(rawAfter.contains("open → done"),           "n2: history entry present")
        } else {
            check(false, "n2: can't read ticket file after setStatus")
        }
        let tickets3 = TicketStore.read(proj2)
        guard let read3 = tickets3.first(where: { $0.id == t2.id }) else {
            check(false, "n2: ticket not found after setStatus+read"); return
        }
        check(read3.notes == "User notes", "n2: notes clean after setStatus (sentinel not leaked)")
    }

    // MARK: - Check o: TaskItem.ticket field round-trip

    private static func checkTaskItemTicketField(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("o")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        var t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Task with ticket ref",
                                  notes: "Some notes")
        } catch {
            check(false, "o: add threw \(error)"); return
        }

        // Set ticket via update().
        t.ticket = "0007"
        do {
            try TaskStore.update(projectPath: proj, t)
        } catch {
            check(false, "o: update threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "o: task not found after update"); return
        }
        check(read1.ticket == "0007", "o: ticket field round-trips via update (got \(read1.ticket ?? "nil"))")
        check(read1.notes  == "Some notes", "o: notes preserved after ticket field set")

        // Clear ticket via update().
        var modified = read1
        modified.ticket = nil
        do {
            try TaskStore.update(projectPath: proj, modified)
        } catch {
            check(false, "o: update (clear) threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "o: task not found after clear"); return
        }
        check(read2.ticket == nil, "o: ticket field cleared after update(nil) (got \(read2.ticket ?? "nil"))")

        // Verify raw file has no ticket: key after clear.
        let dir = TaskStore.file(for: proj)
        if let fname = TaskStore.findFile(id: t.id, in: dir),
           let rawAfter = try? String(contentsOfFile: "\(dir)/\(fname)", encoding: .utf8) {
            let fm = TaskStore.parseTaskFrontmatter(rawAfter)
            check(fm["ticket"] == nil, "o: ticket key absent from frontmatter after clear")
        } else {
            check(false, "o: can't read file for raw verification")
        }
    }

    // MARK: - Check p: TicketMigrator

    private static func checkTicketMigration(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("p")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let tasksDir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: tasksDir,
                                                     withIntermediateDirectories: true)
        } catch {
            check(false, "p: createDirectory threw \(error)"); return
        }

        // Build fixture:
        //  T  (id=0001, top-level task, no parent)
        //  C  (id=0002, child of T, parent=0001)
        //  G  (id=0003, grandchild of C, parent=0002)
        //  S  (id=0004, sibling top-level task, no parent)
        let tDoc = """
            ---
            lore_type: task
            title: "Top-level task T"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-01
            ---
            # Top-level task T
            """
        let cDoc = """
            ---
            lore_type: task
            title: "Child of T"
            status: open
            owner: ai
            category: engineering
            source: local
            created: 2026-06-02
            parent: "0001"
            ---
            # Child of T
            """
        let gDoc = """
            ---
            lore_type: task
            title: "Grandchild of C"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-03
            parent: "0002"
            ---
            # Grandchild of C
            """
        let sDoc = """
            ---
            lore_type: task
            title: "Sibling top-level S"
            status: done
            owner: human
            category: design
            source: local
            created: 2026-06-04
            completed: 2026-06-05
            ---
            # Sibling top-level S
            """

        do {
            try tDoc.write(toFile: "\(tasksDir)/0001-top-level-task-t.md",
                           atomically: true, encoding: .utf8)
            try cDoc.write(toFile: "\(tasksDir)/0002-child-of-t.md",
                           atomically: true, encoding: .utf8)
            try gDoc.write(toFile: "\(tasksDir)/0003-grandchild-of-c.md",
                           atomically: true, encoding: .utf8)
            try sDoc.write(toFile: "\(tasksDir)/0004-sibling-top-level-s.md",
                           atomically: true, encoding: .utf8)
        } catch {
            check(false, "p: writing fixture threw \(error)"); return
        }

        // Run migration.
        let result = TicketMigrator.migrate(projectPath: proj)
        check(!result.skipped, "p: first run is not skipped")

        // 1. T and S became tickets.
        let tickets = TicketStore.read(proj)
        check(tickets.count == 2, "p: 2 tickets created (got \(tickets.count))")
        let ticketT = tickets.first(where: { $0.title == "Top-level task T" })
        let ticketS = tickets.first(where: { $0.title == "Sibling top-level S" })
        check(ticketT != nil, "p: ticket for T exists")
        check(ticketS != nil, "p: ticket for S exists")
        check(ticketS?.status == .done, "p: S ticket carried done status")

        // 2. Original top-level task docs are removed from tasks/.
        let remainingTaskFiles = (try? FileManager.default.contentsOfDirectory(atPath: tasksDir)) ?? []
        let tStillPresent = remainingTaskFiles.contains { fname in
            guard let raw = try? String(contentsOfFile: "\(tasksDir)/\(fname)", encoding: .utf8) else { return false }
            return TaskStore.parseTaskFrontmatter(raw)["title"] == "Top-level task T"
        }
        let sStillPresent = remainingTaskFiles.contains { fname in
            guard let raw = try? String(contentsOfFile: "\(tasksDir)/\(fname)", encoding: .utf8) else { return false }
            return TaskStore.parseTaskFrontmatter(raw)["title"] == "Sibling top-level S"
        }
        check(!tStillPresent, "p: original T task doc removed from tasks/")
        check(!sStillPresent, "p: original S task doc removed from tasks/")

        // 3. Originals backed up.
        let backupDir = "\(proj)/.devdash/migrated-tasks"
        let backupFiles = (try? FileManager.default.contentsOfDirectory(atPath: backupDir)) ?? []
        check(backupFiles.contains("0001-top-level-task-t.md"),
              "p: T original backed up (got \(backupFiles))")
        check(backupFiles.contains("0004-sibling-top-level-s.md"),
              "p: S original backed up (got \(backupFiles))")

        // 4. C: ticket= set to T's ticket id, parent= CLEARED.
        let tasksAfter = TaskStore.read(proj)
        guard let cTask = tasksAfter.first(where: { $0.title == "Child of T" }) else {
            check(false, "p: child task C not found after migration"); return
        }
        check(cTask.ticket != nil,   "p: C has ticket field set")
        check(cTask.ticket == ticketT?.id, "p: C ticket points to T's ticket (got \(cTask.ticket ?? "nil"), expected \(ticketT?.id ?? "nil"))")
        check(cTask.parentId == nil, "p: C parent cleared (was top-level T's child)")

        // 5. G: ticket= set to T's ticket id, parent= C (preserved).
        guard let gTask = tasksAfter.first(where: { $0.title == "Grandchild of C" }) else {
            check(false, "p: grandchild task G not found after migration"); return
        }
        check(gTask.ticket != nil,        "p: G has ticket field set")
        check(gTask.ticket == ticketT?.id, "p: G ticket points to T's ticket")
        check(gTask.parentId != nil,       "p: G parent preserved (non-top parent)")
        check(TaskStore.numEq(gTask.parentId ?? "", cTask.id),
              "p: G parent is C (got \(gTask.parentId ?? "nil"), C.id=\(cTask.id))")

        // 6. Marker written.
        let markerPath = "\(proj)/.devdash/.tickets-migrated"
        check(FileManager.default.fileExists(atPath: markerPath), "p: marker written")

        // 7. Idempotent: running again skips.
        let result2 = TicketMigrator.migrate(projectPath: proj)
        check(result2.skipped, "p: second run is skipped (marker present)")
        let tickets2 = TicketStore.read(proj)
        check(tickets2.count == 2, "p: no duplicate tickets after second run (got \(tickets2.count))")
    }

    // MARK: - Check h: migration one-time

    private static func checkMigrationOneTime(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("h")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let devdashDir = "\(proj)/.devdash"
        do {
            try FileManager.default.createDirectory(atPath: devdashDir, withIntermediateDirectories: true)
        } catch {
            check(false, "h: createDirectory .devdash threw \(error)"); return
        }

        // Build valid JSON matching TaskItem Codable encoding (JSONEncoder + iso8601 dates).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let task1 = TaskItem(
            id: "uuid-aaa-111",
            title: "Migrated Task One",
            notes: "First migrated task",
            stage: nil,
            category: .engineering,
            source: .local,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: nil,
            completedAt: nil,
            ghIssueURL: nil,
            parentId: nil
        )
        let task2 = TaskItem(
            id: "uuid-bbb-222",
            title: "Migrated Task Two",
            notes: nil,
            stage: nil,
            category: .design,
            source: .local,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            startedAt: nil,
            completedAt: nil,
            ghIssueURL: nil,
            parentId: nil
        )

        guard let jsonData = try? encoder.encode([task1, task2]),
              let _ = try? jsonData.write(to: URL(fileURLWithPath: "\(devdashDir)/tasks.json"))
        else {
            check(false, "h: failed to write tasks.json"); return
        }

        // First read — should trigger migration.
        let tasks1 = TaskStore.read(proj)
        check(tasks1.count == 2, "h: first read after migration returns 2 tasks (got \(tasks1.count))")
        check(tasks1.contains(where: { $0.title == "Migrated Task One" }),
              "h: Migrated Task One is present")
        check(tasks1.contains(where: { $0.title == "Migrated Task Two" }),
              "h: Migrated Task Two is present")

        // tasks.json should be renamed.
        let jsonExists = FileManager.default.fileExists(atPath: "\(devdashDir)/tasks.json")
        let migratedExists = FileManager.default.fileExists(atPath: "\(devdashDir)/tasks.json.migrated")
        check(!jsonExists,    "h: tasks.json was renamed (no longer exists)")
        check(migratedExists, "h: tasks.json.migrated exists")

        // Second read — no duplicates.
        let tasks2 = TaskStore.read(proj)
        check(tasks2.count == 2, "h: second read produces no duplicates (got \(tasks2.count))")
    }

    // MARK: - Check q: interrupted re-run safety
    // Simulates a partial migration: a child already has parent cleared + ticket set,
    // AND the original top-level task doc is still present.
    // Invariant: re-running must NOT promote the child to a ticket, and must NOT
    // create a second ticket for the original top-level task.

    private static func checkMigrationInterruptedRerun(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("q")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let tasksDir = TaskStore.file(for: proj)
        let ticketDir = TicketStore.dir(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: tasksDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: ticketDir, withIntermediateDirectories: true)
        } catch {
            check(false, "q: createDirectory threw \(error)"); return
        }

        // Write the ticket that was already created on the first (incomplete) run.
        // It carries migrated_from: "0001" so the migrator knows it was made from T.
        let existingTicketDoc = """
            ---
            lore_type: ticket
            title: "Top-level task T"
            status: open
            owner: human
            category: engineering
            migrated_from: "0001"
            created: 2026-06-01
            ---
            # Top-level task T
            """
        do {
            try existingTicketDoc.write(toFile: "\(ticketDir)/0001-top-level-task-t.md",
                                        atomically: true, encoding: .utf8)
        } catch {
            check(false, "q: writing existing ticket threw \(error)"); return
        }

        // Original top-level task doc still present (interrupted before removal).
        let tDoc = """
            ---
            lore_type: task
            title: "Top-level task T"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-01
            ---
            # Top-level task T
            """
        // Child: parent already cleared, ticket already set (migration completed for this child).
        let cDoc = """
            ---
            lore_type: task
            title: "Child of T"
            status: open
            owner: ai
            category: engineering
            source: local
            created: 2026-06-02
            ticket: "0001"
            ---
            # Child of T
            """
        do {
            try tDoc.write(toFile: "\(tasksDir)/0001-top-level-task-t.md",
                           atomically: true, encoding: .utf8)
            try cDoc.write(toFile: "\(tasksDir)/0002-child-of-t.md",
                           atomically: true, encoding: .utf8)
        } catch {
            check(false, "q: writing task fixtures threw \(error)"); return
        }

        let result = TicketMigrator.migrate(projectPath: proj)
        check(!result.skipped, "q: re-run is not skipped (no marker yet)")

        // Exactly 1 ticket must exist — the already-created one, no duplicate.
        let tickets = TicketStore.read(proj)
        check(tickets.count == 1, "q: exactly 1 ticket after interrupted re-run (got \(tickets.count))")

        // Child must NOT have been promoted to a ticket (it has ticket: set → not topLevel).
        let childAsTicket = tickets.first(where: { $0.title == "Child of T" })
        check(childAsTicket == nil, "q: child with ticket: set was NOT promoted to a ticket")

        // Child task must still exist in tasks/ with ticket field intact.
        let tasksAfter = TaskStore.read(proj)
        let child = tasksAfter.first(where: { $0.title == "Child of T" })
        check(child != nil,           "q: child task still present in tasks/")
        check(child?.ticket == "0001", "q: child ticket field preserved (got \(child?.ticket ?? "nil"))")
        check(child?.parentId == nil,  "q: child parent still cleared")
    }

    // MARK: - Check r: orphan parent → promoted to ticket, dangling parent cleared

    private static func checkMigrationOrphanParent(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("r")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let tasksDir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: tasksDir, withIntermediateDirectories: true)
        } catch {
            check(false, "r: createDirectory threw \(error)"); return
        }

        // O references parent 9999 which doesn't exist → orphan root.
        let oDoc = """
            ---
            lore_type: task
            title: "Orphan task"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-01
            parent: "9999"
            ---
            # Orphan task
            """
        do {
            try oDoc.write(toFile: "\(tasksDir)/0001-orphan-task.md",
                           atomically: true, encoding: .utf8)
        } catch {
            check(false, "r: writing fixture threw \(error)"); return
        }

        let result = TicketMigrator.migrate(projectPath: proj)
        check(!result.skipped, "r: not skipped")
        check(result.ticketsCreated == 1, "r: 1 ticket created for orphan (got \(result.ticketsCreated))")

        // Orphan became a ticket.
        let tickets = TicketStore.read(proj)
        check(tickets.count == 1, "r: exactly 1 ticket (got \(tickets.count))")
        check(tickets.first?.title == "Orphan task", "r: orphan title carried to ticket")

        // The ticket doc must NOT have a parent: key (dangling parent cleared).
        let ticketDir = TicketStore.dir(for: proj)
        if let fname = TicketStore.findFile(id: tickets.first?.id ?? "", in: ticketDir),
           let rawTicket = try? String(contentsOfFile: "\(ticketDir)/\(fname)", encoding: .utf8) {
            let fm = TaskStore.parseTaskFrontmatter(rawTicket)
            check(fm["parent"] == nil, "r: dangling parent cleared on ticket doc")
            check(fm["migrated_from"] != nil, "r: migrated_from set on orphan ticket")
        } else {
            check(false, "r: can't read ticket file")
        }

        // Original orphan task doc removed from tasks/.
        let tasksAfter = TaskStore.read(proj)
        check(tasksAfter.isEmpty, "r: orphan task doc removed from tasks/ (got \(tasksAfter.count))")
    }

    // MARK: - Check s: non-numeric top-level id → child's parent cleared

    private static func checkMigrationNonNumericId(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("s")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let tasksDir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: tasksDir, withIntermediateDirectories: true)
        } catch {
            check(false, "s: createDirectory threw \(error)"); return
        }

        // Top-level task with a numeric id (normal) — child uses string form "1".
        let tDoc = """
            ---
            lore_type: task
            title: "Non-padded parent"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-01
            ---
            # Non-padded parent
            """
        // Child uses the un-padded "1" form of the parent id (as lore CLI writes it).
        let cDoc = """
            ---
            lore_type: task
            title: "Child of non-padded"
            status: open
            owner: ai
            category: engineering
            source: local
            created: 2026-06-02
            parent: "1"
            ---
            # Child of non-padded
            """
        do {
            // Use non-zero-padded filenames as lore CLI would write.
            try tDoc.write(toFile: "\(tasksDir)/1-non-padded-parent.md",
                           atomically: true, encoding: .utf8)
            try cDoc.write(toFile: "\(tasksDir)/2-child-of-non-padded.md",
                           atomically: true, encoding: .utf8)
        } catch {
            check(false, "s: writing fixtures threw \(error)"); return
        }

        _ = TicketMigrator.migrate(projectPath: proj)

        // Child's parent must be cleared (parent "1" was the top-level task).
        let tasksAfter = TaskStore.read(proj)
        guard let child = tasksAfter.first(where: { $0.title == "Child of non-padded" }) else {
            check(false, "s: child task not found after migration"); return
        }
        check(child.parentId == nil, "s: child parent cleared for non-padded parent id")
        check(child.ticket != nil,   "s: child ticket field set for non-padded parent id")

        // Exactly 1 ticket created.
        let tickets = TicketStore.read(proj)
        check(tickets.count == 1, "s: 1 ticket created (got \(tickets.count))")
        check(tickets.first?.title == "Non-padded parent", "s: correct ticket title")
    }

    // MARK: - Check t: 4-level chain re-points correctly
    // ticket > task > subtask > sub-subtask

    private static func checkMigrationFourLevelChain(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("t-chain")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let tasksDir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: tasksDir, withIntermediateDirectories: true)
        } catch {
            check(false, "t: createDirectory threw \(error)"); return
        }

        // T (0001, top-level) → C (0002, parent=0001) → G (0003, parent=0002) → GG (0004, parent=0003)
        let docs: [(String, String)] = [
            ("0001-root.md", """
            ---
            lore_type: task
            title: "Root"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-01
            ---
            # Root
            """),
            ("0002-level1.md", """
            ---
            lore_type: task
            title: "Level 1"
            status: open
            owner: ai
            category: engineering
            source: local
            created: 2026-06-01
            parent: "0001"
            ---
            # Level 1
            """),
            ("0003-level2.md", """
            ---
            lore_type: task
            title: "Level 2"
            status: open
            owner: ai
            category: engineering
            source: local
            created: 2026-06-01
            parent: "0002"
            ---
            # Level 2
            """),
            ("0004-level3.md", """
            ---
            lore_type: task
            title: "Level 3"
            status: open
            owner: human
            category: engineering
            source: local
            created: 2026-06-01
            parent: "0003"
            ---
            # Level 3
            """),
        ]
        for (fname, content) in docs {
            do {
                try content.write(toFile: "\(tasksDir)/\(fname)", atomically: true, encoding: .utf8)
            } catch {
                check(false, "t: writing \(fname) threw \(error)"); return
            }
        }

        _ = TicketMigrator.migrate(projectPath: proj)

        // 1 ticket from Root.
        let tickets = TicketStore.read(proj)
        check(tickets.count == 1, "t: 1 ticket created (got \(tickets.count))")
        let ticketId = tickets.first?.id ?? ""

        let tasksAfter = TaskStore.read(proj)

        // Level 1 (direct child of Root): parent cleared, ticket set.
        guard let l1 = tasksAfter.first(where: { $0.title == "Level 1" }) else {
            check(false, "t: Level 1 not found"); return
        }
        check(l1.parentId == nil,      "t: Level 1 parent cleared")
        check(l1.ticket == ticketId,   "t: Level 1 ticket set (got \(l1.ticket ?? "nil"))")

        // Level 2 (child of Level 1, a non-top task): parent preserved, ticket set.
        guard let l2 = tasksAfter.first(where: { $0.title == "Level 2" }) else {
            check(false, "t: Level 2 not found"); return
        }
        check(l2.parentId != nil,       "t: Level 2 parent preserved")
        check(TaskStore.numEq(l2.parentId ?? "", l1.id),
              "t: Level 2 parent is Level 1 (got \(l2.parentId ?? "nil"), expected \(l1.id))")
        check(l2.ticket == ticketId,    "t: Level 2 ticket set (got \(l2.ticket ?? "nil"))")

        // Level 3: parent is Level 2 (non-top) → preserved, ticket set.
        guard let l3 = tasksAfter.first(where: { $0.title == "Level 3" }) else {
            check(false, "t: Level 3 not found"); return
        }
        check(l3.parentId != nil,       "t: Level 3 parent preserved")
        check(TaskStore.numEq(l3.parentId ?? "", l2.id),
              "t: Level 3 parent is Level 2 (got \(l3.parentId ?? "nil"), expected \(l2.id))")
        check(l3.ticket == ticketId,    "t: Level 3 ticket set (got \(l3.ticket ?? "nil"))")
    }

    // MARK: - Check u: unknown keys + status history preserved on ticket after migration

    private static func checkMigrationUnknownKeysPreserved(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("u")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let tasksDir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: tasksDir, withIntermediateDirectories: true)
        } catch {
            check(false, "u: createDirectory threw \(error)"); return
        }

        // Top-level task carrying: worktree, devdash_id, ai_run, phases, and a
        // sentinel-delimited status history block.
        let tDoc = """
            ---
            lore_type: task
            title: "Rich task"
            status: done
            owner: ai
            category: engineering
            source: local
            created: 2026-06-01
            completed: 2026-06-10
            devdash_id: "uuid-rich-001"
            worktree: "/repos/myapp/.worktrees/task-0001-rich"
            branch: "task/0001-rich-task"
            ai_run: true
            pr: "https://github.com/org/repo/pull/99"
            phases: "[\"Phase 1\",\"Phase 2\"]"
            ---
            # Rich task

            Some user notes here.
            <!-- devdash:status-history -->
            ## Status history
            - 2026-06-05T10:00 open → in_progress
            - 2026-06-10T12:00 in_progress → done
            """
        do {
            try tDoc.write(toFile: "\(tasksDir)/0001-rich-task.md",
                           atomically: true, encoding: .utf8)
        } catch {
            check(false, "u: writing fixture threw \(error)"); return
        }

        _ = TicketMigrator.migrate(projectPath: proj)

        // Read the resulting ticket raw file.
        let ticketDir = TicketStore.dir(for: proj)
        let tickets = TicketStore.read(proj)
        guard let ticket = tickets.first else {
            check(false, "u: no ticket created"); return
        }
        guard let fname = TicketStore.findFile(id: ticket.id, in: ticketDir),
              let rawTicket = try? String(contentsOfFile: "\(ticketDir)/\(fname)", encoding: .utf8)
        else {
            check(false, "u: can't read ticket file"); return
        }

        let fm = TaskStore.parseTaskFrontmatter(rawTicket)

        check(fm["lore_type"] == "ticket",                 "u: lore_type changed to ticket")
        check(fm["migrated_from"] == "0001",               "u: migrated_from set")
        check(fm["title"] == "Rich task",                  "u: title preserved")
        check(fm["status"] == "done",                      "u: status preserved")
        check(fm["owner"] == "ai",                         "u: owner preserved")
        check(fm["devdash_id"] == "uuid-rich-001",         "u: devdash_id preserved")
        check(fm["worktree"]?.contains("task-0001-rich") == true, "u: worktree preserved")
        check(fm["branch"] == "task/0001-rich-task",       "u: branch preserved")
        check(fm["ai_run"] == "true",                      "u: ai_run preserved")
        check(fm["pr"]?.contains("pull/99") == true,       "u: pr preserved")
        check(fm["phases"] != nil,                         "u: phases preserved")
        check(rawTicket.contains(TaskStore.statusHistorySentinel),
              "u: status history sentinel preserved in ticket body")
        check(rawTicket.contains("open → in_progress"),    "u: status history entries preserved")
        check(rawTicket.contains("Some user notes here"),  "u: user notes preserved")
    }

    // MARK: - Check v: PR→review-task creation logic

    /// Pure filesystem test: given a work task with a ticket field in .aiWorking state,
    /// simulates the PostToolUse handler logic and asserts:
    ///   1. Work task is marked done.
    ///   2. A review task is created under the ticket with the PR URL.
    ///   3. Second call (same PR URL) does not create a duplicate.
    ///   4. Legacy path (no ticket): no review task created, work task moves to Review & QA.
    private static func checkPRReviewTaskCreation(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("v")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // --- Setup: ticket + work task with owner=.ai (kanbanColumn == .aiWorking) ---
        let ticket: Ticket
        do {
            ticket = try TicketStore.add(projectPath: proj, title: "Implement login",
                                         category: .engineering, owner: .human)
        } catch {
            check(false, "v: TicketStore.add threw \(error)"); return
        }

        var workTask: TaskItem
        do {
            workTask = try TaskStore.add(projectPath: proj, title: "Implement login",
                                          category: .engineering, source: .local)
        } catch {
            check(false, "v: TaskStore.add threw \(error)"); return
        }

        // Set ticket + owner=.ai in-place (mirrors launchClaudeForTicket).
        let dir = TaskStore.file(for: proj)
        if let fname = TaskStore.findFile(id: workTask.id, in: dir),
           let raw = try? String(contentsOfFile: "\(dir)/\(fname)", encoding: .utf8) {
            var patched = TaskStore.setOrAddFrontmatterKey(
                in: raw, key: "ticket", value: TaskStore.yamlStr(ticket.id))
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "owner", value: TaskOwner.ai.rawValue)
            try? patched.write(toFile: "\(dir)/\(fname)", atomically: true, encoding: .utf8)
        }
        workTask.ticket = ticket.id
        workTask.owner = .ai

        // Verify the work task is in .aiWorking before we simulate the handler.
        let tasks0 = TaskStore.read(proj)
        guard let wt0 = tasks0.first(where: { $0.id == workTask.id }) else {
            check(false, "v: work task not found before handler"); return
        }
        check(wt0.kanbanColumn == .aiWorking, "v: work task starts in aiWorking (got \(wt0.kanbanColumn))")

        // --- Simulate the PostToolUse handler (first call) ---
        let prURL = "https://github.com/org/repo/pull/7"
        simulatePRHandler(proj: proj, workTaskId: workTask.id, ticketId: ticket.id, prURL: prURL)

        // 1. Work task is now done.
        let tasks1 = TaskStore.read(proj)
        guard let wt1 = tasks1.first(where: { $0.id == workTask.id }) else {
            check(false, "v: work task not found after first handler"); return
        }
        check(wt1.status == .done, "v: work task marked done after PR (got \(wt1.status))")

        // 2. A review task was created with the ticket + PR URL.
        let reviewTasks = tasks1.filter { t in
            guard let tid = t.ticket else { return false }
            return TicketStore.numEq(tid, ticket.id) && t.pr == prURL && t.owner == .human
        }
        check(reviewTasks.count == 1, "v: exactly 1 review task created (got \(reviewTasks.count))")
        check(reviewTasks.first?.owner == .human, "v: review task owner is human")

        // 3. Idempotency: second call with the same PR URL must not create a duplicate.
        simulatePRHandler(proj: proj, workTaskId: workTask.id, ticketId: ticket.id, prURL: prURL)
        let tasks2 = TaskStore.read(proj)
        let reviewTasks2 = tasks2.filter { t in
            guard let tid = t.ticket else { return false }
            return TicketStore.numEq(tid, ticket.id) && t.pr == prURL && t.owner == .human
        }
        check(reviewTasks2.count == 1,
              "v: idempotent — still exactly 1 review task after second call (got \(reviewTasks2.count))")

        // 3b. alreadyExists branch: work task is still .aiWorking (not yet done) but
        //     a review task with the same ticket+PR already exists. The handler must
        //     not create a second review task even though it has a new work task to act on.
        let projDedup = makeTempProject("v-dedup")
        defer { try? FileManager.default.removeItem(atPath: projDedup) }

        // Create a new work task (still aiWorking).
        var dedupWork: TaskItem
        do {
            dedupWork = try TaskStore.add(projectPath: projDedup, title: "Dedup work", source: .local)
        } catch {
            check(false, "v-dedup: add threw \(error)"); return
        }
        let dedupTicket: Ticket
        do {
            dedupTicket = try TicketStore.add(projectPath: projDedup, title: "Dedup ticket",
                                               category: .engineering, owner: .human)
        } catch {
            check(false, "v-dedup: TicketStore.add threw \(error)"); return
        }
        let dedupDir = TaskStore.file(for: projDedup)
        if let fname = TaskStore.findFile(id: dedupWork.id, in: dedupDir),
           let raw = try? String(contentsOfFile: "\(dedupDir)/\(fname)", encoding: .utf8) {
            var patched = TaskStore.setOrAddFrontmatterKey(
                in: raw, key: "ticket", value: TaskStore.yamlStr(dedupTicket.id))
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "owner", value: TaskOwner.ai.rawValue)
            try? patched.write(toFile: "\(dedupDir)/\(fname)", atomically: true, encoding: .utf8)
        }
        dedupWork.ticket = dedupTicket.id
        dedupWork.owner = .ai

        let dedupPRURL = "https://github.com/org/repo/pull/99"

        // Pre-seed a review task so alreadyExists == true before calling the handler.
        guard var preExisting = try? TaskStore.add(
            projectPath: projDedup, title: "Review PR #99", category: .qa, source: .local) else {
            check(false, "v-dedup: pre-existing review task add failed"); return
        }
        if let fname = TaskStore.findFile(id: preExisting.id, in: dedupDir),
           let raw = try? String(contentsOfFile: "\(dedupDir)/\(fname)", encoding: .utf8) {
            var patched = TaskStore.setOrAddFrontmatterKey(
                in: raw, key: "ticket", value: TaskStore.yamlStr(dedupTicket.id))
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "owner", value: TaskOwner.human.rawValue)
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "pr", value: TaskStore.yamlStr(dedupPRURL))
            try? patched.write(toFile: "\(dedupDir)/\(fname)", atomically: true, encoding: .utf8)
        }
        preExisting.ticket = dedupTicket.id
        preExisting.owner = .human

        // Confirm the work task is still aiWorking before calling the handler.
        let dedupTasks0 = TaskStore.read(projDedup)
        guard let dw0 = dedupTasks0.first(where: { $0.id == dedupWork.id }) else {
            check(false, "v-dedup: work task not found"); return
        }
        check(dw0.kanbanColumn == .aiWorking, "v-dedup: work task starts in aiWorking")
        let dedupReview0 = dedupTasks0.filter { t in
            guard let tid = t.ticket else { return false }
            return TicketStore.numEq(tid, dedupTicket.id) && t.pr == dedupPRURL
        }
        check(dedupReview0.count == 1, "v-dedup: 1 review task pre-seeded (got \(dedupReview0.count))")

        // Call handler — alreadyExists guard should prevent a second review task.
        simulatePRHandler(proj: projDedup, workTaskId: dedupWork.id,
                          ticketId: dedupTicket.id, prURL: dedupPRURL)
        let dedupTasks1 = TaskStore.read(projDedup)
        let dedupReview1 = dedupTasks1.filter { t in
            guard let tid = t.ticket else { return false }
            return TicketStore.numEq(tid, dedupTicket.id) && t.pr == dedupPRURL
        }
        check(dedupReview1.count == 1,
              "v-dedup: alreadyExists branch — still exactly 1 review task (got \(dedupReview1.count))")

        // 4. Legacy path: work task without a ticket → no review task, work task → reviewQA.
        let projLegacy = makeTempProject("v-legacy")
        defer { try? FileManager.default.removeItem(atPath: projLegacy) }

        var legacyTask: TaskItem
        do {
            legacyTask = try TaskStore.add(projectPath: projLegacy, title: "Legacy work", source: .local)
        } catch {
            check(false, "v-legacy: add threw \(error)"); return
        }
        // owner=.ai, no ticket → kanbanColumn == .aiWorking.
        try? TaskStore.setOwner(projectPath: projLegacy, id: legacyTask.id, owner: .ai)
        legacyTask.owner = .ai
        legacyTask.ticket = nil

        let legacyTasks0 = TaskStore.read(projLegacy)
        guard let lt0 = legacyTasks0.first(where: { $0.id == legacyTask.id }) else {
            check(false, "v-legacy: task not found"); return
        }
        check(lt0.kanbanColumn == .aiWorking, "v-legacy: starts in aiWorking")

        // Legacy handler: setPR + setHasAIRun + setOwner(.human) — mirrors old code path.
        try? TaskStore.setPR(projectPath: projLegacy, id: legacyTask.id, url: prURL)
        try? TaskStore.setHasAIRun(projectPath: projLegacy, id: legacyTask.id)
        try? TaskStore.setOwner(projectPath: projLegacy, id: legacyTask.id, owner: .human)

        let legacyTasks1 = TaskStore.read(projLegacy)
        guard let lt1 = legacyTasks1.first(where: { $0.id == legacyTask.id }) else {
            check(false, "v-legacy: task not found after legacy handler"); return
        }
        check(lt1.kanbanColumn == .reviewQA, "v-legacy: work task moved to reviewQA (got \(lt1.kanbanColumn))")
        check(lt1.pr == prURL, "v-legacy: pr field set (got \(lt1.pr ?? "nil"))")
        // No review task created in legacy path.
        let legacyAll = legacyTasks1.filter { $0.pr == prURL }
        check(legacyAll.count == 1, "v-legacy: only 1 task has the PR URL — no spurious review task")
    }

    /// Helper: simulate the new PostToolUse PR handler logic (ticket-aware path).
    /// Pure file I/O — no DashboardStore, no main actor, safe in tests.
    private static func simulatePRHandler(proj: String, workTaskId: String, ticketId: String, prURL: String) {
        let tasks = TaskStore.read(proj)
        guard let current = tasks.first(where: { $0.id == workTaskId }),
              current.kanbanColumn == .aiWorking
        else { return }

        // Mark work task done.
        try? TaskStore.setStatus(projectPath: proj, id: workTaskId, status: .done)

        // Idempotency: skip if a review task with this PR already exists under the ticket.
        let alreadyExists = tasks.contains { t in
            guard let tid = t.ticket else { return false }
            return TicketStore.numEq(tid, ticketId) && t.pr == prURL
        }
        guard !alreadyExists else { return }

        // Create review task.
        guard let reviewTask = try? TaskStore.add(
            projectPath: proj, title: "Review PR #7", category: .qa, source: .local) else { return }
        let dir = TaskStore.file(for: proj)
        if let fname = TaskStore.findFile(id: reviewTask.id, in: dir),
           let raw = try? String(contentsOfFile: "\(dir)/\(fname)", encoding: .utf8) {
            var patched = TaskStore.setOrAddFrontmatterKey(
                in: raw, key: "ticket", value: TaskStore.yamlStr(ticketId))
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "owner", value: TaskOwner.human.rawValue)
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "pr", value: TaskStore.yamlStr(prURL))
            try? patched.write(toFile: "\(dir)/\(fname)", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Check w: DashboardStore.prNumberFromURL

    private static func checkPRNumberFromURL(_ check: (Bool, String) -> Void) {
        check(DashboardStore.prNumberFromURL(from: "https://github.com/org/repo/pull/42") == 42,
              "w: prNumberFromURL extracts 42 from standard URL")
        check(DashboardStore.prNumberFromURL(from: "https://github.example.com/org/repo/pull/100") == 100,
              "w: prNumberFromURL works with enterprise host")
        check(DashboardStore.prNumberFromURL(from: "https://github.com/org/repo/pull/1") == 1,
              "w: prNumberFromURL works with single-digit PR number")
        check(DashboardStore.prNumberFromURL(from: "no url here") == nil,
              "w: prNumberFromURL returns nil for non-URL string")
        check(DashboardStore.prNumberFromURL(from: "https://github.com/org/repo/issues/42") == nil,
              "w: prNumberFromURL returns nil for issue URL (not /pull/)")
    }
}
