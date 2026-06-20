import SwiftUI
import AppKit

struct VisualDiffSheet: View {
    let result: SnapshotDiffResult
    let projectPath: String
    let urlSlug: String
    let viewportLabel: String
    let pageURL: URL
    let onApprove: (CGImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DashboardStore
    @State private var showDiff = false
    @AppStorage("diffThreshold") private var diffThreshold = 25
    @State private var liveDiffImage: CGImage?
    @State private var liveRatio: Float?

    private enum Sensitivity: Int, CaseIterable {
        case subtle = 8, normal = 25, major = 45
        var label: String {
            switch self {
            case .subtle: return "Subtle"
            case .normal: return "Normal"
            case .major: return "Major"
            }
        }
    }

    private var percentChanged: Int { Int((liveRatio ?? result.changedPixelRatio) * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            imageGrid
                .padding(DSSpace.xl)
            Divider()
            footer
        }
        .frame(minWidth: 800, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: diffThreshold) { _, _ in recomputeDiff() }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var header: some View {
        HStack(spacing: DSSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Visual Review")
                    .font(DSFont.title)
                Text("\(pageURL.absoluteString) — \(percentChanged)% changed")
                    .font(DSFont.label)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("Sensitivity", selection: Binding(
                get: { Sensitivity(rawValue: diffThreshold) ?? .normal },
                set: { diffThreshold = $0.rawValue }
            )) {
                ForEach(Sensitivity.allCases, id: \.rawValue) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("Diff sensitivity — Subtle catches small changes, Major shows only large ones")
            Toggle("Show diff", isOn: $showDiff)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, DSSpace.xl)
        .padding(.vertical, DSSpace.md)
    }

    private var imageGrid: some View {
        GeometryReader { geo in
            let w = (geo.size.width - 12) / 2
            HStack(spacing: DSSpace.md) {
                imageCell(label: "Baseline", cgImage: baselineCGImage, width: w)
                imageCell(label: showDiff ? "Diff (red = changed)" : "New snapshot",
                          cgImage: showDiff ? (liveDiffImage ?? result.diffImage) : result.newImage, width: w)
            }
        }
    }

    private var baselineCGImage: CGImage? {
        VisualSnapshotStore.baseline(for: projectPath, urlSlug: urlSlug, viewport: viewportLabel)
    }

    @ViewBuilder
    private func imageCell(label: String, cgImage: CGImage?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(label)
                .font(DSFont.sectionHeader)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if let cg = cgImage {
                let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: DSRadius.small)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: width)
                    .overlay(Text("No baseline").foregroundColor(.secondary))
            }
        }
    }

    private func recomputeDiff() {
        guard let baseline = baselineCGImage else { return }
        let newImg = result.newImage
        let t = diffThreshold
        Task {
            let diff = await Task.detached {
                VisualDiffRunner.diff(new: newImg, baseline: baseline, threshold: t)
            }.value
            liveDiffImage = diff.diffImage
            liveRatio = diff.changedPixelRatio
        }
    }

    private var footer: some View {
        HStack(spacing: DSSpace.sm) {
            Button("Export report") {
                if let url = VisualSnapshotStore.exportReport(
                    projectPath: projectPath, urlSlug: urlSlug, viewport: viewportLabel,
                    runId: result.runPath.components(separatedBy: "/").last ?? "",
                    pageURL: pageURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .help("Generate static HTML report and open in browser")

            Button("View in Files") {
                store.pendingFilePath = "\(result.runPath)/snapshot.png"
                store.detailTab = .files
                dismiss()
            }
            .buttonStyle(.bordered)
            .help("Open snapshot in the Files tab")
            .disabled(result.runPath.isEmpty)

            Spacer()

            Button("Needs review — create task") {
                store.addTask(
                    projectPath: projectPath,
                    title: "Visual review: \(pageURL.host ?? pageURL.absoluteString)",
                    notes: "Run: \(result.runPath)\nChanged: \(percentChanged)%"
                )
                dismiss()
            }
            .buttonStyle(.bordered)

            Button("Looks good — save as baseline") {
                onApprove(result.newImage)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DSSpace.xl)
        .padding(.vertical, DSSpace.md)
    }
}
