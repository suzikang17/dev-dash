import SwiftUI
import WebKit

/// Loads a local file via WKWebView. Used by the Files tab to render HTML and SVG.
struct FileWebView: NSViewRepresentable {
    enum Source: Equatable {
        case file(URL)
        case html(String, baseURL: URL?)
    }

    let source: Source

    init(fileURL: URL) { self.source = .file(fileURL) }
    init(html: String, baseURL: URL? = nil) { self.source = .html(html, baseURL: baseURL) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        load(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(into: nsView)
    }

    private func load(into webView: WKWebView) {
        switch source {
        case .file(let url):
            if webView.url != url {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        case .html(let html, let baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }
}
