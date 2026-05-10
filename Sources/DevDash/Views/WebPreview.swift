import SwiftUI
import WebKit

enum WebLoadStatus: Equatable {
    case loading
    case loaded
    case failed(String)
}

enum Viewport: String, CaseIterable, Identifiable {
    case desktop, tablet, phone
    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .tablet: return "iPad"
        case .phone: return "iPhone"
        }
    }

    var systemImage: String {
        switch self {
        case .desktop: return "macbook"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        }
    }

    var size: CGSize? {
        switch self {
        case .desktop: return nil  // fill available
        case .tablet: return CGSize(width: 820, height: 1180)
        case .phone: return CGSize(width: 390, height: 844)
        }
    }

    var userAgent: String? {
        switch self {
        case .desktop: return nil
        case .tablet: return "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        case .phone: return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
    }
}

@MainActor
final class WebViewHolder: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var status: WebLoadStatus = .loading
    @Published var viewport: Viewport = .desktop {
        didSet { applyUserAgent() }
    }
    private var currentURL: URL?

    override init() {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    func loadIfNeeded(_ url: URL) {
        if currentURL == url { return }
        currentURL = url
        status = .loading
        applyUserAgent()
        webView.load(URLRequest(url: url))
    }

    func reload() {
        status = .loading
        applyUserAgent()
        webView.reload()
    }

    private func applyUserAgent() {
        webView.customUserAgent = viewport.userAgent
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.status = .loading }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.status = .loaded }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.status = .failed(msg) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.status = .failed(msg) }
    }
}

struct WebPreview: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
