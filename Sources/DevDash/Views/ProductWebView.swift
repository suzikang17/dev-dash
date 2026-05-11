import SwiftUI
import WebKit

/// WKWebView wrapper that powers the living product doc with two-way
/// interaction. Injects a bridge JS at document-end that:
///   - Makes any element with `[data-section-file]` contenteditable; edits
///     debounce-save back to the source file via `webkit.messageHandlers`.
///   - Routes `[data-action]` clicks (e.g. open-file, add-task) into native
///     handlers exposed on DashboardStore.
///   - Visual save indicator: dirty edge → green flash on save.
struct ProductWebView: NSViewRepresentable {
    let url: URL
    let docsRoot: URL
    let reloadToken: Int                                   // bump to force reload
    let onSave: (String, String) -> Void                   // (relPath, html)
    let onAction: ([String: Any]) -> Void                  // generic dispatch

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "devdash")
        controller.addUserScript(WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        config.userContentController = controller
        let wv = WKWebView(frame: .zero, configuration: config)
        // Enable Web Inspector so right-click → Inspect Element works.
        // Open Safari → Develop menu → DevDash → <page> for full devtools.
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        wv.loadFileURL(url, allowingReadAccessTo: docsRoot)
        context.coordinator.lastReloadToken = reloadToken
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reload when the URL changes (different project) OR when the token
        // bumps (caller wants the latest bridge JS / regenerated content).
        if nsView.url != url || context.coordinator.lastReloadToken != reloadToken {
            nsView.loadFileURL(url, allowingReadAccessTo: docsRoot)
            context.coordinator.lastReloadToken = reloadToken
        }
        context.coordinator.onSave = onSave
        context.coordinator.onAction = onAction
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onAction: onAction)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onSave: (String, String) -> Void
        var onAction: ([String: Any]) -> Void
        var lastReloadToken: Int = -1

        init(onSave: @escaping (String, String) -> Void,
             onAction: @escaping ([String: Any]) -> Void) {
            self.onSave = onSave
            self.onAction = onAction
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["action"] as? String {
            case "save":
                if let path = body["path"] as? String,
                   let html = body["html"] as? String {
                    onSave(path, html)
                }
            default:
                onAction(body)
            }
        }
    }

    /// Injected bridge. Contenteditable + click routing for [data-action].
    private static let bridgeJS = """
    (function() {
      function post(payload) {
        try { window.webkit.messageHandlers.devdash.postMessage(payload); }
        catch (e) { console.error('devdash bridge failed', e); }
      }

      // Walk every artifact embed (.embed[data-section-file]) and copy the section
      // file path onto any descendant Alpine-managed root that doesn't have one yet.
      // Triage templates ship with data-section-file="" because the path isn't known
      // at scaffold time; the embed wrapper supplies it at view time.
      function fillAlpineSectionPaths(scope) {
        (scope || document).querySelectorAll('[data-section-file]').forEach(function(host) {
          var hostPath = host.dataset.sectionFile;
          if (!hostPath) return;
          host.querySelectorAll('[data-section-format="alpine-triage"]').forEach(function(node) {
            if (!node.dataset.sectionFile) node.dataset.sectionFile = hostPath;
          });
        });
      }

      function attachEditing(root) {
        (root || document).querySelectorAll('[data-section-file]').forEach(function(el) {
          if (el.dataset.editingAttached) return;
          // Alpine-managed sections own their own state machine; do not make their
          // root contenteditable.
          if (el.dataset.sectionFormat === 'alpine-triage') { el.dataset.editingAttached = 'true'; return; }
          // Artifact-browser .embed wrappers that contain an Alpine-triage root
          // delegate ownership to the inner Alpine component — making the outer
          // wrapper contenteditable would cause the whole embed innerHTML to save
          // alongside (and conflict with) the JSON-block save path.
          if (el.querySelector('[data-section-format="alpine-triage"]')) {
            el.dataset.editingAttached = 'true';
            return;
          }
          el.dataset.editingAttached = 'true';
          el.contentEditable = 'true';
          el.spellcheck = false;
          var saveTimer = null;
          el.addEventListener('input', function() {
            el.classList.add('is-dirty');
            clearTimeout(saveTimer);
            saveTimer = setTimeout(function() { saveHTML(el); }, 800);
          });
          el.addEventListener('blur', function() {
            if (el.classList.contains('is-dirty')) {
              clearTimeout(saveTimer);
              saveHTML(el);
            }
          });
          el.addEventListener('keydown', function(e) {
            if ((e.metaKey || e.ctrlKey) && e.key === 's') {
              e.preventDefault();
              clearTimeout(saveTimer);
              saveHTML(el);
            }
          });
        });
      }

      function saveHTML(el) {
        post({ action: 'save', path: el.dataset.sectionFile, html: el.innerHTML });
        el.classList.remove('is-dirty');
        el.classList.add('is-saved');
        setTimeout(function() { el.classList.remove('is-saved'); }, 1500);
      }

      // Inline Alpine @click handlers in templates call this after mutating DOM
      // inside a contenteditable section, so the input listener fires and the
      // debounced save runs.
      window.devdashMarkDirty = function(el) {
        var section = el.closest('[data-section-file]');
        if (!section) return;
        section.classList.add('is-dirty');
        section.dispatchEvent(new Event('input', { bubbles: true }));
      };

      // Triage's scheduleSave() calls this with the section path + JSON state.
      // Bridge ships it to Swift, which regex-replaces the JSON block in the file.
      window.devdashSaveAlpine = function(path, state) {
        if (!path) return;   // Alpine root hadn't been linked to a file yet
        post({ action: 'save-alpine', path: path, state: state });
        var sec = document.querySelector('[data-section-file="' + path + '"]');
        if (sec) {
          sec.classList.add('is-saved');
          setTimeout(function() { sec.classList.remove('is-saved'); }, 1500);
        }
      };

      // Pass-through delegate for any [data-action] not consumed locally.
      // Keeps open-file / regenerate / etc. working from the rendered HTML.
      document.addEventListener('click', function(e) {
        var btn = e.target.closest('[data-action]');
        if (!btn) return;
        e.preventDefault();
        var payload = { action: btn.dataset.action };
        Object.keys(btn.dataset).forEach(function(k) {
          if (k === 'action') return;
          payload[k] = btn.dataset[k];
        });
        post(payload);
      }, true);

      // Bridge style for dirty/saved indicators
      if (!document.getElementById('devdash-bridge-style')) {
        var style = document.createElement('style');
        style.id = 'devdash-bridge-style';
        style.textContent = '\\n[data-section-file] { transition: box-shadow 0.18s; outline: none; border-radius: 6px; }' +
                            '\\n[data-section-file]:focus { box-shadow: inset 0 0 0 1px var(--accent); }' +
                            '\\n[data-section-file].is-dirty { box-shadow: inset 0 0 0 1px var(--orange); }' +
                            '\\n[data-section-file].is-saved { box-shadow: inset 0 0 0 1px var(--green); }';
        document.head.appendChild(style);
      }

      fillAlpineSectionPaths(document);
      attachEditing(document);
      document.querySelectorAll('nav.tabs .tab').forEach(function(b) {
        b.addEventListener('click', function() {
          setTimeout(function() {
            fillAlpineSectionPaths(document);
            attachEditing(document);
          }, 30);
        });
      });
    })();
    """
}


