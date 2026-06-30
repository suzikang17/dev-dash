import SwiftUI
import WebKit
import AppKit

// MARK: - BrowserPanel

/// A minimal web browser for a canvas panel: address bar + back/forward/reload
/// and a live WKWebView. Type a URL and hit return. (The visited URL isn't
/// persisted across launches yet — the panel reopens blank.)
struct BrowserPanel: View {
    @StateObject private var web = BrowserWebHolder()
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            ZStack {
                BrowserWebView(holder: web)
                if web.currentURL.isEmpty && !web.loading {
                    VStack(spacing: DSSpace.sm) {
                        Image(systemName: "globe")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Type a URL above and press return")
                            .font(DSFont.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: web.currentURL) { _, u in if !u.isEmpty { address = u } }
    }

    private var addressBar: some View {
        HStack(spacing: DSSpace.xs) {
            Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!web.canBack)
                .help("Back").accessibilityLabel("Back")
            Button { web.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(!web.canForward)
                .help("Forward").accessibilityLabel("Forward")
            Button { web.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(web.currentURL.isEmpty)
                .help("Reload").accessibilityLabel("Reload")

            if web.loading {
                ProgressView().controlSize(.mini)
            }

            TextField("Enter a URL…", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(DSFont.mono(.caption))
                .onSubmit { web.load(address); address = web.normalized(address) }

            if !web.currentURL.isEmpty {
                Button {
                    if let url = URL(string: web.currentURL) { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Open in browser").accessibilityLabel("Open in default browser")
            }
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, DSSpace.xs)
        .background(.bar)
    }
}

// MARK: - BrowserWebHolder

@MainActor
final class BrowserWebHolder: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var canBack = false
    @Published var canForward = false
    @Published var currentURL = ""
    @Published var loading = false

    override init() {
        self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
    }

    /// Normalize bare input into a URL string (prepend https:// when no scheme).
    func normalized(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        return s.contains("://") ? s : "https://\(s)"
    }

    func load(_ raw: String) {
        let str = normalized(raw)
        guard !str.isEmpty, let url = URL(string: str) else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    private func sync() {
        canBack = webView.canGoBack
        canForward = webView.canGoForward
        loading = webView.isLoading
        if let u = webView.url?.absoluteString { currentURL = u }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.loading = true }
    }
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.sync() }
    }
}

// MARK: - BrowserWebView

struct BrowserWebView: NSViewRepresentable {
    let holder: BrowserWebHolder
    func makeNSView(context: Context) -> WKWebView { holder.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
