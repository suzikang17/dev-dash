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
        wv.loadFileURL(url, allowingReadAccessTo: docsRoot)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Only reload when the URL changes (different project / forced regen).
        // Plain re-renders of SwiftUI shouldn't blow away in-flight edits.
        if nsView.url != url {
            nsView.loadFileURL(url, allowingReadAccessTo: docsRoot)
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

      function attachEditing(root) {
        (root || document).querySelectorAll('[data-section-file]').forEach(function(el) {
          if (el.dataset.editingAttached) return;
          el.dataset.editingAttached = 'true';
          el.contentEditable = 'true';
          el.spellcheck = false;
          var saveTimer = null;
          var origHTML = el.innerHTML;

          el.addEventListener('input', function() {
            el.classList.add('is-dirty');
            clearTimeout(saveTimer);
            saveTimer = setTimeout(function() { save(el); }, 800);
          });
          el.addEventListener('blur', function() {
            if (el.classList.contains('is-dirty')) {
              clearTimeout(saveTimer);
              save(el);
            }
          });
          // Cmd-S inside the editable saves immediately
          el.addEventListener('keydown', function(e) {
            if ((e.metaKey || e.ctrlKey) && e.key === 's') {
              e.preventDefault();
              clearTimeout(saveTimer);
              save(el);
            }
          });
        });
      }

      function save(el) {
        post({ action: 'save', path: el.dataset.sectionFile, html: el.innerHTML });
        el.classList.remove('is-dirty');
        el.classList.add('is-saved');
        setTimeout(function() { el.classList.remove('is-saved'); }, 1500);
      }

      // Client-side template library used by data-action="dom-insert-template".
      // Each template is a plain HTML string. Adding more here is the way to
      // expand what users can scaffold inside any editable section.
      var templates = {
        'kpi': '<div class="kpi"><div class="k-label">New metric</div><div class="k-value">—</div><div class="k-target">target: —</div><div class="k-delta">—</div></div>',
        'idea-card': '<div class="item"><span class="tag">new</span> <em>New idea — describe it</em></div>',
        'risk-row': '<tr><td><em>New risk</em></td><td><span class="pill warn">Med</span></td><td><span class="pill risk">High</span></td><td><em>mitigation</em></td></tr>',
        'metric-row': '<tr><td><em>New metric</em></td><td>—</td><td>—</td><td>—</td></tr>',
        'decision-entry': '<div class="card"><div class="doc-head"><h3 style="margin:0">D-### · <em>title</em></h3><span class="doc-status meta"><span class="pill warn">Draft</span></span></div><h4>Context</h4><p><em>What forced the decision.</em></p><h4>Decision</h4><p><strong>Picked: …</strong> <em>Why.</em></p></div>',
        'feature-card': '<div class="card"><h3>New feature</h3><p><em>One sentence.</em></p></div>',
        'milestone': '<li><div class="t-meta">Week ?</div><div class="t-title">New milestone</div><p><em>Description.</em></p></li>',
        'checklist-item': '<li>☐ <em>New item</em></li>',
        'kpi-tile': '<div class="kpi"><div class="k-label">New KPI</div><div class="k-value">—</div><div class="k-target">target: —</div></div>'
      };

      function findEditableAncestor(el) {
        var cur = el;
        while (cur && cur !== document.body) {
          if (cur.dataset && cur.dataset.sectionFile) return cur;
          cur = cur.parentElement;
        }
        return null;
      }

      // Action routing — any element with [data-action] posts a payload.
      function attachActions() {
        document.querySelectorAll('[data-action]').forEach(function(el) {
          if (el.dataset.actionAttached) return;
          el.dataset.actionAttached = 'true';
          el.addEventListener('click', function(e) {
            e.preventDefault();
            var act = el.dataset.action;

            // Client-side template insertion (no native round-trip needed).
            if (act === 'dom-insert-template' || act === 'dom-append-template') {
              var tplKey = el.dataset.template;
              var targetSel = el.dataset.target;
              var html = templates[tplKey];
              if (!html) { console.warn('unknown template', tplKey); return; }
              var section = findEditableAncestor(el);
              if (!section) return;
              var target = targetSel ? section.querySelector(targetSel) : el.parentElement;
              if (!target) return;
              var wrap = document.createElement('div');
              wrap.innerHTML = html.trim();
              var node = wrap.firstChild;
              if (act === 'dom-append-template' || !target.contains(el)) {
                // Append when explicitly asked, OR fall back to append when
                // the button isn't a child of the target (insertBefore would
                // throw NotFoundError otherwise).
                target.appendChild(node);
              } else {
                target.insertBefore(node, el);
              }
              section.classList.add('is-dirty');
              save(section);
              return;
            }

            // Client-side delete: remove a marked element + save.
            if (act === 'dom-remove-closest') {
              var sel = el.dataset.target;
              var sec = findEditableAncestor(el);
              if (!sec || !sel) return;
              var victim = el.closest(sel);
              if (victim) {
                victim.remove();
                sec.classList.add('is-dirty');
                save(sec);
              }
              return;
            }

            // Anything else → native side-effect.
            var payload = { action: act };
            Object.keys(el.dataset).forEach(function(k) {
              if (k === 'action' || k === 'actionAttached') return;
              payload[k] = el.dataset[k];
            });
            post(payload);
          });
        });
      }

      // Inject the editing/saving CSS once
      if (!document.getElementById('devdash-bridge-style')) {
        var style = document.createElement('style');
        style.id = 'devdash-bridge-style';
        style.textContent = '\\n[data-section-file] { transition: box-shadow 0.18s; outline: none; border-radius: 6px; }' +
                            '\\n[data-section-file]:focus { box-shadow: inset 0 0 0 1px var(--accent); }' +
                            '\\n[data-section-file].is-dirty { box-shadow: inset 0 0 0 1px var(--orange); }' +
                            '\\n[data-section-file].is-saved { box-shadow: inset 0 0 0 1px var(--green); }';
        document.head.appendChild(style);
      }

      attachEditing(document);
      attachActions();
      // Re-attach after tab switches (panes are still in DOM but new buttons may exist)
      document.querySelectorAll('nav.tabs .tab').forEach(function(b) {
        b.addEventListener('click', function() {
          setTimeout(function() { attachEditing(document); attachActions(); }, 30);
        });
      });
    })();
    """
}
