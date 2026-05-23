import SwiftUI
import WebKit

/// WKWebView wrapper that powers the living product doc with two-way
/// interaction. Injects a bridge JS at document-end that:
///   - Makes any element with `[data-section-file]` contenteditable; edits
///     debounce-save back to the source file via `webkit.messageHandlers`.
///   - Routes `[data-action]` clicks (e.g. open-file, add-task) into native
///     handlers exposed on DashboardStore.
///   - Visual save indicator: dirty edge → green flash on save.
///   - `[[` autocomplete for linking/creating tasks, ideas, and docs.
struct ProductWebView: NSViewRepresentable {
    let url: URL
    let docsRoot: URL
    let reloadToken: Int                                   // bump to force reload
    let onSave: (String, String) -> Void                   // (relPath, html)
    let onSaveAlpine: (String, String) -> Void             // (relPath, jsonState)
    let onAction: ([String: Any]) -> Void                  // generic dispatch
    var onSearchItems: ((String) -> [[String: Any]])? = nil  // (query) → [{id,title,type,status}]
    var onCreateTask: ((String, String?) -> [String: Any])? = nil  // (title, linkedDocPath) → {id,title,status}

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "devdash")
        controller.addUserScript(WKUserScript(
            source: Self.callbackJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.bracketLinkJS,
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
        context.coordinator.webView = wv
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
        context.coordinator.onSaveAlpine = onSaveAlpine
        context.coordinator.onAction = onAction
        context.coordinator.onSearchItems = onSearchItems
        context.coordinator.onCreateTask = onCreateTask
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onSave: onSave, onSaveAlpine: onSaveAlpine, onAction: onAction)
        c.onSearchItems = onSearchItems
        c.onCreateTask = onCreateTask
        return c
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onSave: (String, String) -> Void
        var onSaveAlpine: (String, String) -> Void
        var onAction: ([String: Any]) -> Void
        var onSearchItems: ((String) -> [[String: Any]])?
        var onCreateTask: ((String, String?) -> [String: Any])?
        var lastReloadToken: Int = -1
        weak var webView: WKWebView?

        init(onSave: @escaping (String, String) -> Void,
             onSaveAlpine: @escaping (String, String) -> Void,
             onAction: @escaping ([String: Any]) -> Void) {
            self.onSave = onSave
            self.onSaveAlpine = onSaveAlpine
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
            case "save-alpine":
                if let path = body["path"] as? String,
                   let state = body["state"] as? String {
                    onSaveAlpine(path, state)
                }
            case "search-items":
                guard let query = body["query"] as? String,
                      let callbackId = body["callbackId"] as? String else { return }
                let results = onSearchItems?(query) ?? []
                resolve(callbackId: callbackId, value: results)
            case "create-task":
                guard let title = body["title"] as? String,
                      let callbackId = body["callbackId"] as? String else { return }
                let docPath = body["linkedDocPath"] as? String
                let result = onCreateTask?(title, docPath) ?? [:]
                resolve(callbackId: callbackId, value: result)
            case "get-item-status":
                guard let itemId = body["itemId"] as? String,
                      let callbackId = body["callbackId"] as? String else { return }
                let match = onSearchItems?("").first(where: { $0["id"] as? String == itemId }) ?? [:]
                resolve(callbackId: callbackId, value: match)
            default:
                onAction(body)
            }
        }

        private func resolve(callbackId: String, value: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let json = String(data: data, encoding: .utf8) else { return }
            let escaped = callbackId.replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("devdashResolve('\(escaped)', \(json))", completionHandler: nil)
        }
    }

    /// Promise/callback bridge. Defines `window.devdash.searchItems`, `.createTask`, `.getItemStatus`.
    private static let callbackJS = """
    (function() {
      window._devdashCallbacks = window._devdashCallbacks || {};
      window.devdashResolve = function(callbackId, result) {
        var cb = window._devdashCallbacks[callbackId];
        if (cb) { cb(result); delete window._devdashCallbacks[callbackId]; }
      };
      window.devdash = window.devdash || {};
      function _post(payload) {
        try { webkit.messageHandlers.devdash.postMessage(payload); }
        catch(e) { console.error('devdash bridge', e); }
      }
      function _makePromise(action, extra) {
        return new Promise(function(resolve) {
          var id = Math.random().toString(36).slice(2);
          window._devdashCallbacks[id] = resolve;
          _post(Object.assign({ action: action, callbackId: id }, extra));
        });
      }
      window.devdash.searchItems = function(query) {
        return _makePromise('search-items', { query: query || '' });
      };
      window.devdash.createTask = function(title, linkedDocPath) {
        return _makePromise('create-task', { title: title, linkedDocPath: linkedDocPath || '' });
      };
      window.devdash.getItemStatus = function(itemId, itemType) {
        return _makePromise('get-item-status', { itemId: itemId, itemType: itemType || 'task' });
      };
    })();
    """

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

    /// [[ bracket-link detection, autocomplete dropdown, and link chip insertion.
    private static let bracketLinkJS = """
    (function() {
      var dropdown = null;
      var pendingTextNode = null;
      var pendingOffset = -1;

      function escHtml(s) {
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      }
      function statusIcon(s) {
        if (s === 'done') return '\\u2713';
        if (s === 'blocked') return '!';
        return '\\u25ef';
      }
      function typeIcon(t) {
        if (t === 'idea') return '\\ud83d\\udca1';
        if (t === 'doc')  return '\\ud83d\\udcc4';
        return statusIcon('open');
      }

      function getQuery() {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return null;
        var r = sel.getRangeAt(0);
        if (r.startContainer.nodeType !== Node.TEXT_NODE) return null;
        var text = r.startContainer.textContent.substring(0, r.startOffset);
        var idx = text.lastIndexOf('[[');
        if (idx === -1) return null;
        return { query: text.substring(idx + 2), offset: idx, textNode: r.startContainer, cursorOffset: r.startOffset };
      }

      function showDropdown(info) {
        hideDropdown();
        pendingTextNode = info.textNode;
        pendingOffset   = info.offset;

        var sel = window.getSelection();
        var rect = sel.getRangeAt(0).getBoundingClientRect();

        dropdown = document.createElement('div');
        dropdown.style.cssText = [
          'position:fixed;z-index:99999;min-width:240px;max-height:220px;overflow-y:auto',
          'background:#1c1c22;border:1px solid rgba(255,255,255,0.14);border-radius:9px',
          'box-shadow:0 10px 40px rgba(0,0,0,0.7);padding:5px;font-family:inherit;font-size:12px'
        ].join(';');
        dropdown.style.top  = (rect.bottom + 6) + 'px';
        dropdown.style.left = Math.max(8, rect.left) + 'px';
        document.body.appendChild(dropdown);

        dropdown.innerHTML = '<div style="padding:7px 10px;opacity:0.4;font-size:11px">Searching\\u2026</div>';

        if (window.devdash && window.devdash.searchItems) {
          window.devdash.searchItems(info.query).then(function(results) {
            if (!dropdown) return;
            renderResults(results, info.query);
          });
        }
      }

      function renderResults(results, query) {
        if (!dropdown) return;
        dropdown.innerHTML = '';
        var trimmed = (query || '').trim();

        if (trimmed) {
          var cr = makeRow('<span style="font-weight:600;color:#5ac8fa">+</span> Create task: ' + escHtml(trimmed), true);
          cr.addEventListener('mousedown', function(e) { e.preventDefault(); createAndInsert(trimmed); });
          dropdown.appendChild(cr);
        }

        (results || []).slice(0, 8).forEach(function(item) {
          var icon = item.type === 'task' ? statusIcon(item.status) : typeIcon(item.type);
          var row = makeRow(escHtml(icon + ' ' + item.title), false);
          row.addEventListener('mousedown', function(e) { e.preventDefault(); insertChip(item); });
          dropdown.appendChild(row);
        });

        if (!trimmed && (!results || results.length === 0)) {
          dropdown.innerHTML = '<div style="padding:7px 10px;opacity:0.4;font-size:11px">Type to search or create\\u2026</div>';
        }
      }

      function makeRow(html, highlighted) {
        var d = document.createElement('div');
        d.style.cssText = 'padding:6px 10px;cursor:pointer;border-radius:6px;display:flex;align-items:center;gap:6px;' +
          (highlighted ? 'background:rgba(90,200,250,0.07);' : '');
        d.innerHTML = html;
        d.addEventListener('mouseenter', function() { d.style.background = 'rgba(255,255,255,0.06)'; });
        d.addEventListener('mouseleave', function() { d.style.background = highlighted ? 'rgba(90,200,250,0.07)' : ''; });
        return d;
      }

      function replaceQueryWithChip(chip) {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0 || !pendingTextNode) return;
        var r = document.createRange();
        r.setStart(pendingTextNode, pendingOffset);
        r.setEnd(pendingTextNode, sel.getRangeAt(0).startOffset);
        r.deleteContents();
        r.insertNode(chip);
        var after = document.createRange();
        after.setStartAfter(chip);
        sel.removeAllRanges();
        sel.addRange(after);
        var section = chip.closest('[data-section-file]');
        if (section) window.devdashMarkDirty && window.devdashMarkDirty(section);
      }

      function insertChip(item) {
        hideDropdown();
        var chip = buildChip(item.id, item.type, item.title, item.status || 'open');
        replaceQueryWithChip(chip);
        pendingTextNode = null;
      }

      function createAndInsert(title) {
        var savedNode   = pendingTextNode;
        var savedOffset = pendingOffset;
        hideDropdown();
        pendingTextNode = savedNode;
        pendingOffset   = savedOffset;
        var linkedDocPath = window.location.pathname;
        if (window.devdash && window.devdash.createTask) {
          window.devdash.createTask(title, linkedDocPath).then(function(task) {
            if (!task || !task.id) return;
            var chip = buildChip(task.id, 'task', task.title || title, 'open');
            replaceQueryWithChip(chip);
            pendingTextNode = null;
          });
        }
      }

      function buildChip(id, type, title, status) {
        var chip = document.createElement('span');
        chip.className = 'devdash-link-chip';
        chip.dataset.linkId   = id;
        chip.dataset.linkType = type;
        chip.contentEditable  = 'false';
        var icon = type === 'task' ? statusIcon(status) : typeIcon(type);
        chip.textContent = icon + ' ' + title;
        return chip;
      }

      function hideDropdown() {
        if (dropdown) { dropdown.remove(); dropdown = null; }
      }

      document.addEventListener('input', function(e) {
        if (!e.target.closest('[data-section-file]')) { hideDropdown(); return; }
        var info = getQuery();
        if (info) { showDropdown(info); } else { hideDropdown(); }
      });

      document.addEventListener('keydown', function(e) {
        if (!dropdown) return;
        if (e.key === 'Escape') { hideDropdown(); e.preventDefault(); }
      });

      document.addEventListener('mousedown', function(e) {
        if (dropdown && !dropdown.contains(e.target)) hideDropdown();
      });

      if (!document.getElementById('devdash-chip-style')) {
        var s = document.createElement('style');
        s.id = 'devdash-chip-style';
        s.textContent = '.devdash-link-chip{display:inline-flex;align-items:center;gap:4px;' +
          'background:rgba(90,200,250,0.1);border:1px solid rgba(90,200,250,0.3);' +
          'padding:1px 7px;border-radius:4px;color:#5ac8fa;font-size:12px;' +
          'cursor:default;user-select:none;white-space:nowrap}' +
          '.devdash-link-chip:hover{background:rgba(90,200,250,0.2)}';
        document.head.appendChild(s);
      }

      // Refresh chip status icons on page load
      document.querySelectorAll('.devdash-link-chip[data-link-id]').forEach(function(chip) {
        if (!window.devdash || chip.dataset.linkType !== 'task') return;
        window.devdash.getItemStatus(chip.dataset.linkId, 'task').then(function(r) {
          if (!r || !r.status) return;
          var icon = statusIcon(r.status);
          var rest = chip.textContent.replace(/^[\\u25ef\\u2713!]\\s*/, '');
          chip.textContent = icon + ' ' + rest;
        });
      });
    })();
    """
}
