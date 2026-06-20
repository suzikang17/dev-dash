import SwiftUI
import AppKit

/// Scoped chat with Claude about a single guiding question. Loads / appends
/// messages to `.devdash/question-chats/<stageId>-<hash>.jsonl`. "Use as
/// answer" takes the latest assistant message and saves it to ProjectMeta.
struct QuestionChatSheet: View {
    let projectPath: String
    let projectName: String
    let stage: TemplateStage
    let template: LaunchTemplate
    let question: String

    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [QuestionChatMessage] = []
    @State private var draft: String = ""
    @State private var streaming = false
    @State private var streamingId: String? = nil
    @State private var streamTask: Task<Void, Never>? = nil
    @FocusState private var inputFocused: Bool

    private var currentAnswer: String {
        store.meta(for: projectPath).answer(for: stage.id, question: question)
    }

    private var lastAssistant: String? {
        messages.last(where: { $0.role == .assistant })?.content
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .onAppear {
            messages = QuestionChatStore.read(projectPath, stageId: stage.id, question: question)
            // First open with no prior conversation — auto-send the question
            // as the kickoff so Claude responds immediately with project + stage
            // context already attached.
            if messages.isEmpty {
                draft = question
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    send()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
            }
        }
        .onDisappear {
            streamTask?.cancel()
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(spacing: DSSpace.sm) {
                Image(systemName: "sparkles")
                    .foregroundColor(DSColor.assistant)
                Text("Help me think through this")
                    .font(DSFont.title)
                Spacer()
                if !messages.isEmpty {
                    Button {
                        QuestionChatStore.clear(projectPath, stageId: stage.id, question: question)
                        messages = []
                    } label: { Label("Clear", systemImage: "trash") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            Text(question)
                .font(DSFont.title)
            HStack(spacing: DSSpace.sm) {
                Text(projectName).font(DSFont.micro).foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary).font(DSFont.micro)
                Text("\(template.name) · \(stage.title)")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
            }
            if !currentAnswer.isEmpty {
                Text("Current answer: \(currentAnswer)")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var transcript: some View {
        if messages.isEmpty {
            VStack(spacing: DSSpace.sm) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(DSFont.display)
                    .foregroundColor(.secondary)
                Text("Start a conversation about this question")
                    .font(DSFont.body)
                    .foregroundColor(.secondary)
                Text("Type below — Claude has the project, stage, and methodology as context.")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DSSpace.sm) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.last?.content) { _, _ in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: DSSpace.sm) {
            if let last = lastAssistant, !last.isEmpty, !streaming {
                HStack(spacing: DSSpace.sm) {
                    Spacer()
                    Button {
                        store.setAnswer(last, stageId: stage.id, question: question, for: projectPath)
                        dismiss()
                    } label: {
                        Label("Use last reply as answer", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: DSSpace.sm) {
                TextField("Ask Claude…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .lineLimit(1...4)
                    .disabled(streaming)
                    .onSubmit { send() }

                if streaming {
                    Button {
                        streamTask?.cancel()
                        streaming = false
                    } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                } else {
                    Button { send() } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }

        let userMsg = QuestionChatMessage(
            id: UUID().uuidString, role: .user, content: text, timestamp: Date()
        )
        messages.append(userMsg)
        QuestionChatStore.append(userMsg, to: projectPath, stageId: stage.id, question: question)
        draft = ""

        let assistantId = UUID().uuidString
        let assistantStub = QuestionChatMessage(
            id: assistantId, role: .assistant, content: "", timestamp: Date()
        )
        messages.append(assistantStub)
        QuestionChatStore.append(assistantStub, to: projectPath, stageId: stage.id, question: question)
        streamingId = assistantId
        streaming = true

        let prompt = buildPrompt()
        streamTask = Task {
            await runStream(prompt: prompt, into: assistantId)
        }
    }

    private func buildPrompt() -> String {
        let methodology = template.methodology
        let stageContext = """
        Project: \(projectName)
        Methodology: \(template.name)
        Stage: \(stage.title) — \(stage.purpose)
        Stage methodology: \(stage.methodology)

        The question we're working on:
        "\(question)"

        Their current saved answer (may be empty):
        \(currentAnswer.isEmpty ? "(none yet)" : currentAnswer)

        Overall methodology context:
        \(methodology)
        """

        // Include the conversation as turns. Last message is the user's
        // freshly-sent message. The empty assistant stub at the end is
        // dropped here.
        let convo = messages
            .filter { !($0.role == .assistant && $0.content.isEmpty) }
            .map { msg -> String in
                let label = msg.role == .user ? "USER" : "ASSISTANT"
                return "\(label):\n\(msg.content)"
            }
            .joined(separator: "\n\n")

        return """
        You are helping a founder think through one specific question for their \
        product launch. Be concrete, ask one clarifying question if needed, then \
        propose a concrete answer they can save. Keep replies under 200 words.

        Context:
        \(stageContext)

        Conversation so far:
        \(convo)

        Reply now as ASSISTANT:
        """
    }

    private func runStream(prompt: String, into assistantId: String) async {
        let proc: RunningProcess
        do {
            proc = try ClaudeRunner.run(prompt: prompt, cwd: projectPath, allowEdits: false)
        } catch {
            await MainActor.run {
                appendError("Couldn't start Claude: \(error.localizedDescription)", id: assistantId)
                streaming = false
            }
            return
        }

        var buffer = ""
        for await line in proc.lines {
            if Task.isCancelled { proc.stop(); break }
            // claude -p with --output-format text emits raw lines; just join.
            buffer += (buffer.isEmpty ? "" : "\n") + line
            await MainActor.run {
                if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                    messages[idx].content = buffer
                }
            }
        }
        await MainActor.run {
            QuestionChatStore.updateLastAssistant(
                projectPath, stageId: stage.id, question: question,
                content: buffer, id: assistantId
            )
            streaming = false
            streamingId = nil
        }
    }

    private func appendError(_ text: String, id: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = "Error: \(text)"
        }
        QuestionChatStore.updateLastAssistant(
            projectPath, stageId: stage.id, question: question,
            content: "Error: \(text)", id: id
        )
    }
}

private struct MessageBubble: View {
    let message: QuestionChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.sm) {
            Image(systemName: message.role == .user ? "person.circle.fill" : "sparkles")
                .foregroundColor(message.role == .user ? DSColor.user : DSColor.assistant)
                .font(DSFont.title)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.role == .user ? "You" : "Claude")
                    .font(DSFont.sectionHeader)
                    .foregroundColor(.secondary)
                if message.content.isEmpty {
                    HStack(spacing: DSSpace.xs) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(DSFont.micro).foregroundColor(.secondary)
                    }
                } else {
                    Text(message.content)
                        .font(DSFont.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((message.role == .user ? DSColor.user : DSColor.assistant).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
    }
}
