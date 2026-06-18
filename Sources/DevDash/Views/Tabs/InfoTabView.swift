import SwiftUI
import AppKit

struct InfoTabView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        if let project = store.project(for: store.selection) {
            VStack(spacing: 0) {
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
                        Divider()
                        DevServerURLRow(project: project)
                        Divider()
                        ProductionURLRow(project: project)
                    }

                    GitCard(project: project)

                    NotesCard(project: project)

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
            DevAddressBar(project: project)
            } // VStack
        } else {
            Text("Select a project to see info")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NotesCard: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var draft: String = ""
    @State private var editing = false

    private var saved: String { store.meta(for: project.path).notes ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NOTES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                Spacer()
                if editing {
                    Button("Done") {
                        store.setProjectNotes(draft, for: project.path)
                        editing = false
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
                } else {
                    Button(saved.isEmpty ? "Add" : "Edit") {
                        draft = saved
                        editing = true
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
            }

            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
            } else if saved.isEmpty {
                Text("No notes yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text(saved)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
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

private struct DevServerURLRow: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var editing = false
    @State private var draft = ""

    private var savedURL: String? { store.meta(for: project.path).customDevServerURL }
    private var displayURL: String {
        guard let port = store.runningPort(for: project.path) else { return savedURL ?? "" }
        let base = "http://localhost:\(port)"
        guard let saved = savedURL,
              let url = URL(string: saved),
              let host = url.host,
              host == "localhost" || host == "127.0.0.1" else { return base }
        var path = url.path == "/" ? "" : url.path
        if let q = url.query { path += "?\(q)" }
        return base + path
    }
    private var openURL: URL? { URL(string: displayURL) }
    private var isRunning: Bool { store.runningPort(for: project.path) != nil }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isRunning ? "play.circle.fill" : "link")
                .foregroundColor(isRunning ? .green : .secondary)
                .frame(width: 16)
            Text("Dev URL")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            if editing {
                TextField("http://localhost:3000", text: $draft)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .onSubmit { save() }
                Button("Done") { save() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            } else if displayURL.isEmpty {
                Text("Not set")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Set") { startEditing() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                if let url = openURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text(displayURL)
                            .foregroundColor(.accentColor)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Edit") { startEditing() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func startEditing() {
        draft = displayURL.isEmpty ? "" : displayURL
        editing = true
    }

    private func save() {
        store.setCustomDevServerURL(draft, for: project.path)
        editing = false
    }
}

private struct ProductionURLRow: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var editing = false
    @State private var draft = ""

    private var savedURL: String? { store.meta(for: project.path).productionURL }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text("Production URL")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            if editing {
                TextField("https://myapp.com", text: $draft)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .onSubmit { save() }
                Button("Done") { save() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            } else if let url = savedURL {
                Button { NSWorkspace.shared.open(URL(string: url) ?? URL(fileURLWithPath: "/")) } label: {
                    Text(url)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Edit") { draft = url; editing = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("Not set")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Set") { draft = ""; editing = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func save() {
        store.setProductionURL(draft, for: project.path)
        editing = false
    }
}

private struct DevAddressBar: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var pathDraft = ""
    @FocusState private var focused: Bool

    private var runningPort: Int? { store.runningPort(for: project.path) }
    private var savedURL: String { store.meta(for: project.path).customDevServerURL ?? "" }

    // Path+query portion of the saved URL when it was a localhost URL.
    private var savedPath: String {
        guard let url = URL(string: savedURL),
              let host = url.host,
              host == "localhost" || host == "127.0.0.1" else { return "" }
        var s = url.path == "/" ? "" : url.path
        if let q = url.query { s += "?\(q)" }
        if let f = url.fragment { s += "#\(f)" }
        return s
    }

    var body: some View {
        HStack(spacing: 0) {
            if let port = runningPort {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                Text(verbatim: "http://localhost:\(port)")
                    .font(.system(size: 12).monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                TextField("/path", text: $pathDraft)
                    .font(.system(size: 12).monospaced())
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { save(); focused = false }
                    .onAppear { pathDraft = savedPath }
                    .onChange(of: project.path) { _, _ in pathDraft = savedPath }
            } else {
                Image(systemName: "link")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                TextField("http://localhost:3000", text: $pathDraft)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { save(); focused = false }
                    .onAppear { pathDraft = savedURL }
                    .onChange(of: project.path) { _, _ in pathDraft = savedURL }
            }
            Spacer(minLength: 4)
            if focused {
                Button { save(); focused = false } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Save (Enter)")
                .padding(.trailing, 4)
            }
            Button { open() } label: {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .foregroundColor(effectiveURL.isEmpty ? Color.secondary.opacity(0.3) : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(effectiveURL.isEmpty)
            .help("Save and open in browser")
            .padding(.trailing, 10)
        }
        .frame(height: 32)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color(NSColor.separatorColor)), alignment: .top)
    }

    private var effectiveURL: String {
        if let port = runningPort {
            var path = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && !path.hasPrefix("/") { path = "/\(path)" }
            return "http://localhost:\(port)\(path)"
        }
        return pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let url = effectiveURL
        guard !url.isEmpty else { return }
        store.setCustomDevServerURL(url, for: project.path)
    }

    private func open() {
        save()
        guard !effectiveURL.isEmpty, let url = URL(string: effectiveURL) else { return }
        NSWorkspace.shared.open(url)
        focused = false
    }
}

private struct GitCard: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var showDiff = false
    @State private var diffContent: String? = nil
    @State private var loadingDiff = false

    private var status: GitStatus? { store.gitStatus(for: project.path) }
    private var isOp: Bool { store.gitOpInProgress.contains(project.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("GIT", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                Spacer()
                if isOp { ProgressView().controlSize(.mini) }
                Button {
                    Task { await store.refreshGitStatus(for: project.path) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isOp)
            }

            if let s = status {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    if s.localBranches.count > 1 {
                        Picker("", selection: Binding(
                            get: { s.branch ?? "" },
                            set: { b in Task { await store.gitCheckout(b, for: project.path) } }
                        )) {
                            ForEach(s.localBranches, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 200)
                    } else {
                        Text(s.branch ?? "detached HEAD")
                            .font(.system(size: 13).monospaced())
                    }
                    Spacer()
                    if s.aheadCount > 0 {
                        Label("\(s.aheadCount)", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(.blue)
                    }
                    if s.behindCount > 0 {
                        Label("\(s.behindCount)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(.orange)
                    }
                }

                if !s.isClean {
                    HStack(spacing: 8) {
                        if s.stagedCount > 0 {
                            GitStatusChip(count: s.stagedCount, label: "staged", color: .green)
                        }
                        if s.unstagedCount > 0 {
                            GitStatusChip(count: s.unstagedCount, label: "modified", color: .orange)
                        }
                        if s.untrackedCount > 0 {
                            GitStatusChip(count: s.untrackedCount, label: "untracked", color: .secondary)
                        }
                        Spacer()
                        if s.stashCount > 0 {
                            Text("\(s.stashCount) stashed")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Button {
                            loadingDiff = true
                            Task {
                                diffContent = await store.gitDiff(for: project.path)
                                loadingDiff = false
                                if diffContent != nil { showDiff = true }
                            }
                        } label: {
                            Label(loadingDiff ? "Loading…" : "Diff", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .controlSize(.small)
                        .disabled(loadingDiff)
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Working tree clean")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }

                if s.worktrees.count > 1 {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WORKTREES")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.0)
                            .foregroundColor(.secondary)
                        ForEach(s.worktrees) { wt in
                            HStack(spacing: 6) {
                                Image(systemName: wt.isMain ? "house" : "folder")
                                    .foregroundColor(.secondary)
                                    .frame(width: 14)
                                Text(wt.displayName)
                                    .font(.system(size: 12))
                                if let b = wt.branch {
                                    Text(b)
                                        .font(.system(size: 11).monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Fetch") { Task { await store.gitFetch(for: project.path) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isOp)
                    Button("Pull") { Task { await store.gitPull(for: project.path) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isOp || s.upstream == nil)
                    Button("Push") { Task { await store.gitPush(for: project.path) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isOp || s.aheadCount == 0)
                }
            } else if project.isGit {
                HStack { ProgressView().controlSize(.mini); Text("Loading…").font(.system(size: 12)).foregroundColor(.secondary) }
            } else {
                Text("Not a git repository.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        .onAppear {
            if store.gitStatus(for: project.path) == nil {
                Task { await store.refreshGitStatus(for: project.path) }
            }
        }
        .onChange(of: project.path) { _, _ in
            Task { await store.refreshGitStatus(for: project.path) }
        }
        .sheet(isPresented: $showDiff) {
            DiffSheet(diff: diffContent ?? "No changes.")
        }
    }
}

private struct GitStatusChip: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

private struct DiffSheet: View {
    let diff: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uncommitted Changes")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

private struct DiffLineView: View {
    let line: String

    var body: some View {
        Text(verbatim: line.isEmpty ? " " : line)
            .font(.system(size: 12).monospaced())
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
    }

    private var foregroundColor: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 1, green: 0.35, blue: 0.35) }
        if line.hasPrefix("@@") { return .accentColor }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return .secondary
        }
        return .primary
    }

    private var backgroundColor: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.05) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.05) }
        return .clear
    }
}
