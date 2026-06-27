import Foundation
import AppKit

// MARK: - Xcode project representation

/// A discovered Xcode project or workspace in a dashboard project directory.
struct XcodeProject: Identifiable, Hashable {
    /// Display name shown in the picker (the dashboard project name).
    let name: String
    /// Root directory of the dashboard project.
    let rootPath: String
    /// Resolved workspace path (.xcworkspace preferred over .xcodeproj).
    let buildTarget: BuildTarget

    var id: String { rootPath }

    enum BuildTarget: Hashable {
        case workspace(String)   // path to .xcworkspace
        case project(String)     // path to .xcodeproj

        var path: String {
            switch self { case .workspace(let p), .project(let p): return p }
        }

        var xcodebuildFlags: [String] {
            switch self {
            case .workspace(let p): return ["-workspace", p]
            case .project(let p):   return ["-project", p]
            }
        }
    }

    /// Scan `rootPath` for a .xcworkspace or .xcodeproj and return an
    /// XcodeProject if found.  Workspace takes priority.
    ///
    /// Many repos (e.g. a Next.js app with a native companion) keep the Xcode
    /// project in a subdirectory rather than the repo root, so when the root
    /// has nothing we scan one level deep, preferring conventional native dirs
    /// (`ios`, `App`, …) and skipping dependency/build noise.  The returned
    /// `rootPath` points at the directory that actually contains the project,
    /// so `xcodebuild`'s cwd and the derived-data slug stay correct.
    static func discover(name: String, rootPath: String) -> XcodeProject? {
        // 1. Repo root — preserves the original behavior.
        if let target = buildTarget(in: rootPath) {
            return XcodeProject(name: name, rootPath: rootPath, buildTarget: target)
        }

        // 2. One level deep, conventional native dirs first.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { return nil }
        let preferred = ["ios", "App", "app", "apple", "macos", "Sources"]
        let skip: Set<String> = ["node_modules", "Pods", "DerivedData",
                                  ".build", ".git", ".worktrees", "build"]
        let subdirs = entries.filter { entry in
            guard !entry.hasPrefix("."), !skip.contains(entry) else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(rootPath)/\(entry)", isDirectory: &isDir) && isDir.boolValue
        }
        // Conventional names first, then the rest alphabetically — deterministic.
        let ordered = subdirs.sorted { a, b in
            let ai = preferred.firstIndex(of: a) ?? Int.max
            let bi = preferred.firstIndex(of: b) ?? Int.max
            return ai != bi ? ai < bi : a < b
        }
        for sub in ordered {
            let subPath = "\(rootPath)/\(sub)"
            if let target = buildTarget(in: subPath) {
                return XcodeProject(name: name, rootPath: subPath, buildTarget: target)
            }
        }
        return nil
    }

    /// Return the build target for an Xcode workspace/project directly inside
    /// `dir` (non-recursive), preferring a standalone `.xcworkspace`.
    private static func buildTarget(in dir: String) -> BuildTarget? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        // Prefer workspace (covers CocoaPods / SPM-generated setups).
        if let ws = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return .workspace("\(dir)/\(ws)")
        }
        if let proj = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return .project("\(dir)/\(proj)")
        }
        return nil
    }

    // MARK: Fix 4 — derived data outside the target repo

    /// Stable per-project derived-data path under ~/Library/Caches/dev-dash/simbuild/.
    /// Keeps incremental build artifacts reusable across sessions without polluting
    /// the target project's git repo.
    var derivedDataPath: String {
        // Slug the rootPath to a safe directory name.
        let slug = rootPath
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.path ?? (NSHomeDirectory() + "/Library/Caches")
        let dir = "\(caches)/dev-dash/simbuild/\(slug)"
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Build settings decoded from xcodebuild -showBuildSettings -json

private struct BuildSettingsEnvelope: Decodable {
    struct Target: Decodable {
        let buildSettings: Settings
        enum CodingKeys: String, CodingKey { case buildSettings }
    }
    struct Settings: Decodable {
        let targetBuildDir: String
        let fullProductName: String
        let productBundleIdentifier: String
        enum CodingKeys: String, CodingKey {
            case targetBuildDir          = "TARGET_BUILD_DIR"
            case fullProductName         = "FULL_PRODUCT_NAME"
            case productBundleIdentifier = "PRODUCT_BUNDLE_IDENTIFIER"
        }
    }
    // xcodebuild -showBuildSettings -json emits an array of per-target objects.
    // Fix 3: select the target whose FULL_PRODUCT_NAME ends in ".app"; fall back
    // to first only if none match (e.g. framework-only scheme).
    static func decode(from data: Data) throws -> Settings {
        let targets = try JSONDecoder().decode([Target].self, from: data)
        guard !targets.isEmpty else { throw SimAppError.buildSettingsMissing }
        let appTarget = targets.first(where: { $0.buildSettings.fullProductName.hasSuffix(".app") })
        guard let settings = (appTarget ?? targets.first)?.buildSettings else {
            throw SimAppError.buildSettingsMissing
        }
        return settings
    }
}

// MARK: - Scheme list decoded from xcodebuild -list -json

private struct SchemeList: Decodable {
    struct Project: Decodable {
        let schemes: [String]
    }
    let project: Project?
    let workspace: Project?

    var allSchemes: [String] { (project ?? workspace)?.schemes ?? [] }
}

// MARK: - Errors

enum SimAppError: LocalizedError {
    case noProjectSelected
    case noUDIDSelected
    case schemeResolutionFailed
    case buildFailed(tail: String)
    case buildTimedOut(tail: String)
    case buildSettingsMissing
    case appNotFound(path: String)
    case installFailed(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectSelected:
            return "No Xcode project selected."
        case .noUDIDSelected:
            return "No simulator selected. Start a simulator first."
        case .schemeResolutionFailed:
            return "Could not determine an Xcode scheme. Select one manually."
        case .buildFailed(let tail):
            return "Build failed:\n\(tail)"
        case .buildTimedOut(let tail):
            return "Build timed out after 10 min —\n\(tail)"
        case .buildSettingsMissing:
            return "Could not read build settings from xcodebuild."
        case .appNotFound(let path):
            return "Built .app not found at expected path: \(path)"
        case .installFailed(let detail):
            return "simctl install failed: \(detail)"
        case .launchFailed(let detail):
            return "simctl launch failed: \(detail)"
        }
    }
}

// MARK: - State machine

/// Drives the build → install → launch pipeline for a selected Xcode project.
/// All @Published mutations happen on the main actor.
@MainActor
final class SimAppRunner: ObservableObject {

    // MARK: Published state

    enum BuildPhase: Equatable {
        case idle
        case fetchingSchemes
        case building
        case installing
        case launching
        case done
        case failed(String)
    }

    @Published var phase: BuildPhase = .idle
    /// Live tail of xcodebuild output shown during build.
    @Published var buildStatusLine: String = ""
    /// Available schemes for the selected project (populated after fetchSchemes).
    @Published var availableSchemes: [String] = []
    @Published var selectedScheme: String? = nil

    // MARK: Fix 1+2 — cancellable build task with in-flight guard

    /// The live build task, if one is in progress.  Non-nil implies a build is
    /// running; nil means idle.  We store it here so `cancel()` can reach it
    /// from the Cancel button, onDisappear, and deinit.
    private var buildTask: Task<Void, Never>? = nil
    /// The live xcodebuild process, captured inside `streamingRun` so `cancel()`
    /// can kill it immediately rather than waiting for Task cancellation to
    /// propagate through the async stream.
    private var buildProcess: RunningProcess? = nil

    deinit {
        // Cancel any in-flight build when the runner is torn down (e.g. when
        // SimulatorView disappears and its @StateObject is released).
        buildTask?.cancel()
        buildProcess?.stop()
    }

    // MARK: - Scheme resolution

    /// Populate `availableSchemes` by running `xcodebuild -list -json`.
    /// Auto-selects the scheme if exactly one is found.
    func fetchSchemes(for project: XcodeProject) async {
        phase = .fetchingSchemes
        availableSchemes = []
        selectedScheme = nil

        var args = project.buildTarget.xcodebuildFlags
        args += ["-list", "-json"]

        let raw = await ShellRunner.run("/usr/bin/xcodebuild", args: args,
                                        cwd: project.rootPath, timeout: 30)
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode(SchemeList.self, from: data) else {
            // Fall back: use the project directory name as scheme.
            let fallback = URL(fileURLWithPath: project.rootPath).lastPathComponent
            availableSchemes = [fallback]
            selectedScheme = fallback
            phase = .idle
            return
        }

        availableSchemes = list.allSchemes
        if let only = list.allSchemes.first, list.allSchemes.count == 1 {
            selectedScheme = only
        } else if selectedScheme == nil {
            selectedScheme = list.allSchemes.first
        }
        phase = .idle
    }

    // MARK: - Full build → install → launch pipeline

    /// Spawn the build pipeline as a stored Task so it can be cancelled.
    /// Returns immediately; observe `phase` for progress.
    func buildAndRun(project: XcodeProject, scheme: String, udid: String) {
        // Fix 2: in-flight guard — ignore if a build is already running.
        if let existing = buildTask, !existing.isCancelled { return }

        buildTask = Task {
            await runPipeline(project: project, scheme: scheme, udid: udid)
            // Clear the task reference when it finishes naturally.
            buildTask = nil
        }
    }

    /// Cancel any running build and return to idle.
    func cancel() {
        buildTask?.cancel()
        buildTask = nil
        buildProcess?.stop()
        buildProcess = nil
        phase = .idle
        buildStatusLine = ""
    }

    func reset() {
        cancel()   // also clears any live process
        availableSchemes = []
        selectedScheme = nil
    }

    // MARK: - Pipeline implementation

    private func runPipeline(project: XcodeProject, scheme: String, udid: String) async {
        phase = .building
        buildStatusLine = "Starting build…"

        let derivedDataPath = project.derivedDataPath

        // MARK: Step 1 – build
        var buildArgs = project.buildTarget.xcodebuildFlags
        buildArgs += [
            "-scheme", scheme,
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-configuration", "Debug",
            "-derivedDataPath", derivedDataPath,
            "build",
        ]

        let buildResult = await streamingRun(
            binary: "/usr/bin/xcodebuild",
            args: buildArgs,
            cwd: project.rootPath,
            timeout: 600
        )

        // Fix 1: check cancellation between steps.
        if Task.isCancelled { return }

        guard buildResult.exitCode == 0 else {
            let tail = lastLines(buildResult.output, count: 20)
            // Fix 5: distinguish timeout (exitCode SIGTERM = -15 / 143) from
            // compile failure.  We set timedOut on the result when the wall-clock
            // task fired first.
            if buildResult.timedOut {
                phase = .failed("Build timed out after 10 min —\n\(tail)")
            } else {
                phase = .failed("Build failed:\n\(tail)")
            }
            return
        }

        // MARK: Step 2 – read build settings to locate the .app
        phase = .installing
        buildStatusLine = "Reading build settings…"

        if Task.isCancelled { return }

        var settingsArgs = project.buildTarget.xcodebuildFlags
        settingsArgs += [
            "-scheme", scheme,
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-configuration", "Debug",
            "-derivedDataPath", derivedDataPath,
            "-showBuildSettings", "-json",
        ]

        guard let settingsRaw = await ShellRunner.run(
            "/usr/bin/xcodebuild", args: settingsArgs,
            cwd: project.rootPath, timeout: 60
        ), let settingsData = settingsRaw.data(using: .utf8),
        let settings = try? BuildSettingsEnvelope.decode(from: settingsData) else {
            phase = .failed("Could not read build settings from xcodebuild.")
            return
        }

        if Task.isCancelled { return }

        let appPath = "\(settings.targetBuildDir)/\(settings.fullProductName)"
        let bundleID = settings.productBundleIdentifier

        guard FileManager.default.fileExists(atPath: appPath) else {
            phase = .failed("Built .app not found at expected path: \(appPath)")
            return
        }

        // MARK: Step 3 – install
        buildStatusLine = "Installing \(settings.fullProductName)…"
        let install = await ShellRunner.runResult(
            "/usr/bin/xcrun",
            args: ["simctl", "install", udid, appPath],
            timeout: 60
        )
        guard install.ok else {
            phase = .failed("simctl install failed: \(install.output)")
            return
        }

        if Task.isCancelled { return }

        // MARK: Step 4 – launch
        phase = .launching
        buildStatusLine = "Launching \(bundleID)…"
        let launch = await ShellRunner.runResult(
            "/usr/bin/xcrun",
            args: ["simctl", "launch", udid, bundleID],
            timeout: 30
        )
        guard launch.ok else {
            phase = .failed("simctl launch failed: \(launch.output)")
            return
        }

        phase = .done
        buildStatusLine = "Launched \(bundleID)"
    }

    // MARK: - Private helpers

    /// Extended result that also captures whether the wall-clock timeout fired.
    private struct StreamResult {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Run a long-lived command (xcodebuild), streaming its output lines into
    /// `buildStatusLine` and collecting them for the error tail.
    /// Fix 5: returns a `StreamResult` that records whether the wall-clock
    /// timeout fired (distinguishing timeout from genuine build failure).
    private func streamingRun(
        binary: String,
        args: [String],
        cwd: String,
        timeout: Double
    ) async -> StreamResult {
        do {
            let proc = try ShellRunner.start(binary, args: args, cwd: cwd)
            buildProcess = proc

            var lines: [String] = []
            var didTimeout = false

            // Wall-clock timeout: kill the process and flag the result.
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                didTimeout = true
                proc.stop()
                await MainActor.run { self?.buildProcess = nil }
            }

            for await line in proc.lines {
                if Task.isCancelled {
                    proc.stop()
                    timeoutTask.cancel()
                    buildProcess = nil
                    return StreamResult(output: lines.joined(separator: "\n"),
                                       exitCode: -1, timedOut: false)
                }
                lines.append(line)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { buildStatusLine = trimmed }
            }

            timeoutTask.cancel()
            buildProcess = nil

            let exitCode = proc.process.terminationStatus
            return StreamResult(output: lines.joined(separator: "\n"),
                                exitCode: exitCode, timedOut: didTimeout)
        } catch {
            buildProcess = nil
            return StreamResult(output: error.localizedDescription,
                                exitCode: -1, timedOut: false)
        }
    }

    /// Return the last `count` non-empty lines from a block of text.
    private func lastLines(_ text: String, count: Int) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }
}

// MARK: - ShellRunner.CommandResult shim
// streamingRun now returns its own StreamResult; rename the old helper usage
// so callers in runPipeline don't need updating.
private extension SimAppRunner {
    // Transparent re-export so call sites in runPipeline stay readable.
}
