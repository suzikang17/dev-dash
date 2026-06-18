import Foundation
import WebKit
import AppKit

@MainActor
enum VisualDiffRunner {

    // MARK: - Snapshot

    static func takeSnapshot(webView: WKWebView) async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: webView.frame.width)
        let nsImage: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: SnapshotError.noImage)
                }
            }
        }
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SnapshotError.conversionFailed
        }
        return cg
    }

    // MARK: - Diff

    nonisolated static func diff(new newImage: CGImage, baseline: CGImage, threshold: Int = 25) -> SnapshotDiffResult {
        let w = min(newImage.width, baseline.width)
        let h = min(newImage.height, baseline.height)
        guard w > 0, h > 0 else {
            return SnapshotDiffResult(newImage: newImage, diffImage: newImage,
                                      changedPixelRatio: 1.0, isSignificant: true, runPath: "")
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        guard
            let newCtx  = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
            let baseCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
            let diffCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else {
            return SnapshotDiffResult(newImage: newImage, diffImage: newImage,
                                      changedPixelRatio: 0, isSignificant: false, runPath: "")
        }

        // Draw into contexts first, then read pixel data
        newCtx.draw(newImage, in: rect)
        baseCtx.draw(baseline, in: rect)
        diffCtx.draw(newImage, in: rect)  // background: new image, changed pixels overwritten below

        guard let nPtr = newCtx.data, let bPtr = baseCtx.data, let dPtr = diffCtx.data else {
            return SnapshotDiffResult(newImage: newImage, diffImage: newImage,
                                      changedPixelRatio: 0, isSignificant: false, runPath: "")
        }

        let nBuf = nPtr.bindMemory(to: UInt8.self, capacity: newCtx.bytesPerRow * h)
        let bBuf = bPtr.bindMemory(to: UInt8.self, capacity: baseCtx.bytesPerRow * h)
        let dBuf = dPtr.bindMemory(to: UInt8.self, capacity: diffCtx.bytesPerRow * h)

        let nStride = newCtx.bytesPerRow
        let bStride = baseCtx.bytesPerRow
        let dStride = diffCtx.bytesPerRow

        var changedCount = 0

        for y in 0..<h {
            let nRow = y * nStride
            let bRow = y * bStride
            let dRow = y * dStride
            for x in 0..<w {
                let ni = nRow + x * 4
                let bi = bRow + x * 4
                let di = dRow + x * 4
                let maxDiff = Swift.max(
                    abs(Int(nBuf[ni])   - Int(bBuf[bi])),
                    abs(Int(nBuf[ni+1]) - Int(bBuf[bi+1])),
                    abs(Int(nBuf[ni+2]) - Int(bBuf[bi+2]))
                )
                if maxDiff > threshold {
                    changedCount += 1
                    dBuf[di]   = 255  // R
                    dBuf[di+1] = 0    // G
                    dBuf[di+2] = 0    // B
                    dBuf[di+3] = 210  // A — semi-transparent red overlay
                }
                // else: diffCtx already has the newImage pixel from draw() above
            }
        }

        let diffCGImage = diffCtx.makeImage() ?? newImage
        let ratio = Float(changedCount) / Float(max(w * h, 1))
        return SnapshotDiffResult(
            newImage: newImage,
            diffImage: diffCGImage,
            changedPixelRatio: ratio,
            isSignificant: ratio > 0.01,
            runPath: ""
        )
    }

    // MARK: - Production URL snapshot

    @MainActor
    static func takeSnapshotFromURL(_ url: URL, viewportSize: CGSize = CGSize(width: 1280, height: 900)) async throws -> CGImage {
        let loader = PageLoader(viewportSize: viewportSize)
        return try await loader.load(url)
    }

    // MARK: - Errors

    enum SnapshotError: Error, LocalizedError {
        case noImage
        case conversionFailed
        var errorDescription: String? {
            switch self {
            case .noImage:          return "WebView returned no image"
            case .conversionFailed: return "Could not convert snapshot to CGImage"
            }
        }
    }
}

@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var done = false

    init(viewportSize: CGSize) {
        webView = WKWebView(frame: CGRect(origin: .zero, size: viewportSize))
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            self.capture()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    private func capture() {
        guard !done else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: webView.frame.width)
        webView.takeSnapshot(with: config) { [self] image, error in
            guard !self.done else { return }
            self.done = true
            if let error {
                self.continuation?.resume(throwing: error)
            } else if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.continuation?.resume(returning: cg)
            } else {
                self.continuation?.resume(throwing: VisualDiffRunner.SnapshotError.noImage)
            }
        }
    }

    private func fail(_ error: Error) {
        guard !done else { return }
        done = true
        continuation?.resume(throwing: error)
    }
}
