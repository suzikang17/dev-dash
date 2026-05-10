import SwiftUI
import AppKit

struct InfoTabView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        if let project = store.project(for: store.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(project.name)
                        .font(.largeTitle.bold())

                    Text(DevRoots.shortenPath(project.path))
                        .font(.system(size: 12).monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    InfoCard {
                        InfoRow(label: "Framework", value: project.framework, icon: "cube.box")
                        Divider()
                        InfoRow(label: "Stack", value: project.stack ?? "—", icon: "stack.3d")
                        Divider()
                        InfoRow(label: "Health", value: project.health.label, icon: "heart")
                        if let days = project.daysSinceCommit {
                            Divider()
                            InfoRow(label: "Last commit", value: "\(days) days ago", icon: "clock")
                        }
                        if let branch = project.branch {
                            Divider()
                            InfoRow(label: "Branch", value: branch, icon: "arrow.triangle.branch", monospaced: true)
                        }
                        if let url = project.githubURL {
                            Divider()
                            InfoRow(label: "GitHub", value: url.absoluteString, icon: "link", linkURL: url)
                        }
                        if let port = store.runningPort(for: project.path) {
                            Divider()
                            InfoRow(label: "Running on", value: "localhost:\(port)", icon: "play.circle.fill",
                                    linkURL: URL(string: "http://localhost:\(port)"))
                        }
                    }

                    HStack(spacing: 10) {
                        if store.runningPort(for: project.path) == nil {
                            Button {
                                Task { await store.startServer(for: project.path) }
                            } label: {
                                Label("Start dev server", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isStarting(project.path))
                        } else {
                            Button(role: .destructive) {
                                Task { await store.stopServer(for: project.path) }
                            } label: {
                                Label("Stop dev server", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)

                        if let url = project.githubURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open GitHub", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let err = store.startError(project.path) {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    ProvidersCard(project: project)

                    ContextCard(project: project)

                    Spacer()
                }
                .padding(20)
            }
        } else {
            Text("Select a project to see info")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProvidersCard: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var editing: Provider? = nil
    @State private var addingNew = false

    var body: some View {
        let providers = store.providers(for: project.path)
        let total = store.totalMonthlyCost(for: project.path)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PROVIDERS", systemImage: "shippingbox")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                if !providers.isEmpty {
                    Text(verbatim: "\(providers.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let total = total {
                    Text(verbatim: "~$\(format(total))/mo")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(.green)
                }
                Button {
                    store.refreshProviders(for: project.path)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Re-detect from package.json + .env")

                Button {
                    addingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Add provider manually")
            }

            if providers.isEmpty {
                Text("No providers detected. Click + to add one, or refresh to re-scan package.json and .env.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let grouped = Dictionary(grouping: providers, by: { $0.category })
                let categories = grouped.keys.sorted { $0.rawValue < $1.rawValue }
                VStack(spacing: 0) {
                    ForEach(categories, id: \.self) { cat in
                        ForEach(grouped[cat] ?? [], id: \.id) { p in
                            ProviderRow(provider: p, onEdit: { editing = p })
                            if p.id != providers.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        .sheet(item: $editing) { p in
            ProviderEditor(projectPath: project.path, existing: p)
                .environmentObject(store)
        }
        .sheet(isPresented: $addingNew) {
            ProviderEditor(projectPath: project.path, existing: nil)
                .environmentObject(store)
        }
    }

    private func format(_ d: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = d < 10 ? 2 : 0
        f.maximumFractionDigits = d < 10 ? 2 : 0
        return f.string(from: NSNumber(value: d)) ?? String(format: "%.2f", d)
    }
}

private struct ProviderRow: View {
    let provider: Provider
    let onEdit: () -> Void
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.category.systemImage)
                .foregroundColor(.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(provider.category.label)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                    if !provider.detectedFrom.isManual {
                        Text(provider.detectedFrom.label)
                            .font(.system(size: 10).monospaced())
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let notes = provider.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let cost = provider.monthlyEstimateUSD {
                Text(verbatim: "$\(formatCost(cost))/mo")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.green)
            }
            if let url = provider.dashboardURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(url.absoluteString)
            }
            if hover {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit") { onEdit() }
            if let url = provider.dashboardURL {
                Button("Open dashboard") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button(role: .destructive) {
                store.deleteProvider(projectPath: providerProjectPath, id: provider.id)
            } label: { Text("Delete") }
        }
    }

    /// We don't carry projectPath in Provider, so the context menu's delete
    /// has to look it up. Walk up via the EnvironmentObject's selection.
    private var providerProjectPath: String {
        store.project(for: store.selection)?.path ?? ""
    }

    private func formatCost(_ d: Double) -> String {
        d < 10 ? String(format: "%.2f", d) : String(Int(d.rounded()))
    }
}

private struct ProviderEditor: View {
    let projectPath: String
    let existing: Provider?
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var category: ProviderCategory = .other
    @State private var dashboardURL: String = ""
    @State private var monthlyCost: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(existing == nil ? "Add provider" : "Edit \(existing?.name ?? "")")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            Form {
                TextField("Name", text: $name)
                Picker("Category", selection: $category) {
                    ForEach(ProviderCategory.allCases, id: \.self) { c in
                        Label(c.label, systemImage: c.systemImage).tag(c)
                    }
                }
                TextField("Dashboard URL (optional)", text: $dashboardURL)
                HStack {
                    Text("Monthly cost (USD)")
                    TextField("0.00", text: $monthlyCost)
                        .frame(width: 100)
                }
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)
            .padding(.horizontal, 14)

            Divider()
            HStack {
                if let existing = existing {
                    Button(role: .destructive) {
                        store.deleteProvider(projectPath: projectPath, id: existing.id)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480)
        .onAppear {
            if let e = existing {
                name = e.name
                category = e.category
                dashboardURL = e.dashboardURL?.absoluteString ?? ""
                monthlyCost = e.monthlyEstimateUSD.map { String(format: "%.2f", $0) } ?? ""
                notes = e.notes ?? ""
            }
        }
    }

    private func save() {
        let url = URL(string: dashboardURL.trimmingCharacters(in: .whitespaces))
        let cost = Double(monthlyCost.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""))
        let notesValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let e = existing {
            var updated = e
            updated.name = name
            updated.category = category
            updated.dashboardURL = url
            updated.monthlyEstimateUSD = cost
            updated.notes = notesValue.isEmpty ? nil : notesValue
            store.updateProvider(projectPath: projectPath, updated)
        } else {
            store.addProvider(
                projectPath: projectPath,
                name: name,
                category: category,
                dashboardURL: url,
                monthlyEstimateUSD: cost,
                notes: notesValue.isEmpty ? nil : notesValue
            )
        }
        dismiss()
    }
}

private struct ContextCard: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        let path = project.path
        let projectSessions = store.sessions.filter {
            $0.projectPath == path || $0.projectPath.hasPrefix("\(path)/")
        }
        let openTodos = (store.tasksByProject.first { $0.projectPath == path }?.todos ?? [])
            .filter { !$0.done }.count

        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT ACTIVITY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)

            if projectSessions.isEmpty && openTodos == 0 {
                Text("No recent activity logged for this project.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if openTodos > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").foregroundColor(.secondary)
                    Text(verbatim: "\(openTodos) open todo\(openTodos == 1 ? "" : "s")")
                }
                .font(.system(size: 12))
            }

            if !projectSessions.isEmpty {
                Divider()
                Text("RECENT CLAUDE SESSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(projectSessions.prefix(5)) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Text(timeAgo(s.lastActivity))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(s.firstUserMessage ?? "(no user message)")
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct InfoCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    let icon: String
    var monospaced: Bool = false
    var linkURL: URL? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            if let url = linkURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(value)
                        .foregroundColor(.accentColor)
                        .font(monospaced ? .system(size: 13).monospaced() : .system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            } else {
                Text(value)
                    .font(monospaced ? .system(size: 13).monospaced() : .system(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
