import SwiftUI
import WebKit

struct DocsTabView: View {
    @EnvironmentObject var store: DashboardStore

    private var atlasURL: URL? {
        let path: String?
        if let proj = store.project(for: store.selection) {
            path = proj.path
        } else if let svc = store.service(for: store.selection) {
            path = svc.cwd
        } else {
            path = nil
        }
        guard let p = path else { return nil }
        let name = URL(fileURLWithPath: p).lastPathComponent
        return URL(string: "http://localhost:\(DashboardStore.atlasPort)/p/\(name)/")
    }

    var body: some View {
        if let url = atlasURL {
            AtlasWebView(url: url)
        } else {
            ContentUnavailableView("No project selected", systemImage: "books.vertical")
        }
    }
}

private struct AtlasWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let current = webView.url
        if current?.host != url.host || current?.port != url.port || current?.path != url.path {
            webView.load(URLRequest(url: url))
        }
    }
}
