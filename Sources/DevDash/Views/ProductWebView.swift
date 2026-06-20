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
    var onSaveLore: (String, String) -> (html: String, warning: String?) = { _, _ in ("", nil) } // (absLorePath, markdownBody) → rendered body HTML + optional validation warning
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
        controller.addUserScript(WKUserScript(
            source: Self.outlinerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.tagPickerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.blocksViewJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.loreEditJS,
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
        context.coordinator.onSaveLore = onSaveLore
        context.coordinator.onAction = onAction
        context.coordinator.onSearchItems = onSearchItems
        context.coordinator.onCreateTask = onCreateTask
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onSave: onSave, onSaveAlpine: onSaveAlpine, onAction: onAction)
        c.onSaveLore = onSaveLore
        c.onSearchItems = onSearchItems
        c.onCreateTask = onCreateTask
        return c
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onSave: (String, String) -> Void
        var onSaveAlpine: (String, String) -> Void
        var onSaveLore: (String, String) -> (html: String, warning: String?) = { _, _ in ("", nil) }
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
            case "save-lore":
                if let path = body["path"] as? String,
                   let markdown = body["markdown"] as? String {
                    let result = onSaveLore(path, markdown)
                    if let cb = body["callbackId"] as? String {
                        resolve(callbackId: cb, value: ["html": result.html, "warning": result.warning ?? ""])
                    }
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

      // Templates for dom-append-template / dom-insert-template actions.
      var DOM_TEMPLATES = {
        'idea-card': '<div class="item"><span class="tag">new</span> <em>New idea — describe it</em></div>',
        'kpi': '<div class="kpi"><div class="k-label">New KPI</div><div class="k-value">—</div><div class="k-target">target: —</div><div class="k-delta">—</div></div>',
        'checklist-item': '<li>☐ <em>New item</em></li>',
        'metric-row': '<tr><td><em>new metric</em></td><td>—</td><td>—</td><td>—</td></tr>'
      };

      // Pass-through delegate for any [data-action] not consumed locally.
      // Keeps open-file / regenerate / etc. working from the rendered HTML.
      document.addEventListener('click', function(e) {
        var btn = e.target.closest('[data-action]');
        if (!btn) return;
        e.preventDefault();
        var action = btn.dataset.action;

        // Handle DOM template insertion locally — no Swift roundtrip needed.
        if (action === 'dom-append-template' || action === 'dom-insert-template') {
          var tmpl = DOM_TEMPLATES[btn.dataset.template];
          var tgt = btn.dataset.target ? document.querySelector(btn.dataset.target) : null;
          if (tmpl && tgt) {
            tgt.insertAdjacentHTML('beforeend', tmpl);
            var sec = tgt.closest('[data-section-file]') || btn.closest('[data-section-file]');
            if (sec) saveHTML(sec);
          }
          return;
        }

        var payload = { action: action };
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

    /// Roam/Tana-style outliner keyboard handling:
    /// - Enter: split bullet (new sibling)
    /// - Tab: indent (nest under previous sibling)
    /// - Shift-Tab: outdent (promote to grandparent's level)
    /// - Backspace on empty bullet: outdent or merge with previous
    private static let outlinerJS = #"""
    (function() {
      function isInOutliner(node) {
        return node && node.nodeType === 1
          ? node.closest('[data-outliner] li')
          : (node && node.parentElement ? node.parentElement.closest('[data-outliner] li') : null);
      }

      function markSectionDirty(li) {
        var sec = li.closest('[data-section-file]');
        if (!sec) return;
        sec.classList.add('is-dirty');
        sec.dispatchEvent(new Event('input', { bubbles: true }));
      }

      function placeCaretAtStart(el) {
        var range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(true);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }

      function placeCaretAtEnd(el) {
        var range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(false);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }

      // li text content excluding nested <ul> children
      function getLiTextLength(li) {
        var len = 0;
        li.childNodes.forEach(function(n) {
          if (n.nodeName === 'UL') return;
          len += (n.textContent || '').length;
        });
        return len;
      }

      document.addEventListener('keydown', function(e) {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return;
        var anchor = sel.anchorNode;
        var li = isInOutliner(anchor);
        if (!li) return;

        // Enter — split into a new sibling li (no nested newline).
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          var newLi = document.createElement('li');
          newLi.appendChild(document.createElement('br'));
          // Insert after current li, before any nested ul
          var nestedUl = li.querySelector(':scope > ul');
          if (nestedUl) {
            li.insertBefore(newLi, nestedUl);
          } else if (li.nextSibling) {
            li.parentNode.insertBefore(newLi, li.nextSibling);
          } else {
            li.parentNode.appendChild(newLi);
          }
          placeCaretAtStart(newLi);
          markSectionDirty(newLi);
          return;
        }

        // Tab — indent (nest under previous sibling)
        if (e.key === 'Tab' && !e.shiftKey) {
          e.preventDefault();
          var prev = li.previousElementSibling;
          if (!prev || prev.nodeName !== 'LI') return; // can't indent first child
          var prevUl = prev.querySelector(':scope > ul');
          if (!prevUl) {
            prevUl = document.createElement('ul');
            prev.appendChild(prevUl);
          }
          prevUl.appendChild(li);
          placeCaretAtEnd(li);
          markSectionDirty(li);
          return;
        }

        // Shift-Tab — outdent
        if (e.key === 'Tab' && e.shiftKey) {
          e.preventDefault();
          var parentUl = li.parentNode;
          var grandLi = parentUl.parentNode;
          if (!grandLi || grandLi.nodeName !== 'LI') return; // already at root
          // Move li to be sibling after grandLi
          if (grandLi.nextSibling) {
            grandLi.parentNode.insertBefore(li, grandLi.nextSibling);
          } else {
            grandLi.parentNode.appendChild(li);
          }
          // If parentUl is now empty, remove it
          if (parentUl.children.length === 0) parentUl.remove();
          placeCaretAtEnd(li);
          markSectionDirty(li);
          return;
        }

        // Backspace right after a chip — remove the whole chip in one keystroke
        if (e.key === 'Backspace') {
          var rangeBs = sel.getRangeAt(0);
          if (rangeBs.collapsed && rangeBs.startContainer.nodeType === Node.TEXT_NODE && rangeBs.startOffset === 0) {
            var prevSibling = rangeBs.startContainer.previousSibling;
            if (prevSibling && prevSibling.nodeType === 1 &&
                (prevSibling.classList.contains('devdash-tag-chip') ||
                 prevSibling.classList.contains('devdash-link-chip'))) {
              e.preventDefault();
              prevSibling.remove();
              markSectionDirty(li);
              return;
            }
          }
        }

        // Backspace at start of empty li — remove and place caret in previous
        if (e.key === 'Backspace') {
          var range = sel.getRangeAt(0);
          if (!range.collapsed) return;
          var textLen = getLiTextLength(li);
          // Only intercept when truly empty AND caret is at start.
          if (textLen === 0 && range.startOffset === 0) {
            e.preventDefault();
            var prevSib = li.previousElementSibling;
            var parentUlBs = li.parentNode;
            var grandLiBs = parentUlBs.parentNode;
            li.remove();
            if (parentUlBs.children.length === 0 && parentUlBs !== document.body) {
              parentUlBs.remove();
            }
            // Focus target: previous sibling, else grandparent li
            var focusTarget = prevSib || (grandLiBs && grandLiBs.nodeName === 'LI' ? grandLiBs : null);
            if (focusTarget) {
              // Find deepest last li in subtree for natural caret placement
              var deepest = focusTarget;
              var lastUl = focusTarget.querySelector(':scope > ul');
              while (lastUl) {
                var lastChild = lastUl.lastElementChild;
                if (!lastChild) break;
                deepest = lastChild;
                lastUl = deepest.querySelector(':scope > ul');
              }
              placeCaretAtEnd(deepest);
            }
            markSectionDirty(li);
            return;
          }
        }
      }, true);
    })();
    """#

    /// Tana-style supertag picker. Trigger via `#` (anywhere) or `/` (start of bullet).
    /// Picks from a fixed type list and inserts a non-editable chip with data-tag.
    private static let tagPickerJS = #"""
    (function() {
      var TAG_TYPES = ['task','kpi','goal','decision','risk','question','idea'];
      var dropdown = null;
      var trigger = null;        // '#' or '/'
      var triggerTextNode = null;
      var triggerOffset = -1;    // offset of trigger char in textNode
      var selectedIdx = 0;
      var filteredTags = TAG_TYPES.slice();

      function inEditableBlock(node) {
        var el = node && (node.nodeType === 1 ? node : node.parentElement);
        if (!el) return false;
        var sec = el.closest('[data-section-file]');
        return sec && (sec.isContentEditable || sec.querySelector('[contenteditable]'));
      }

      function isAtBulletStart(textNode, offset) {
        // Check that all text before offset in textNode is empty/whitespace AND
        // textNode is the first text-bearing child of its <li>.
        var prefix = textNode.textContent.substring(0, offset);
        if (prefix.trim().length > 0) return false;
        var li = (textNode.parentElement || textNode.parentNode).closest('li');
        if (!li) return false;
        // Walk li children — find first content node. If it's our textNode (or ancestor), we're at start.
        var firstContent = null;
        for (var i = 0; i < li.childNodes.length; i++) {
          var n = li.childNodes[i];
          if (n.nodeType === Node.TEXT_NODE && n.textContent.length > 0) { firstContent = n; break; }
          if (n.nodeType === 1 && n.nodeName !== 'UL') { firstContent = n; break; }
        }
        return firstContent === textNode;
      }

      function hideDropdown() {
        if (dropdown) { dropdown.remove(); dropdown = null; }
        trigger = null; triggerTextNode = null; triggerOffset = -1;
      }

      function showDropdown(rect) {
        hideDropdown.skipReset = true;
        if (dropdown) dropdown.remove();
        dropdown = document.createElement('div');
        dropdown.style.cssText = [
          'position:fixed;z-index:99999;min-width:180px;max-height:240px;overflow-y:auto',
          'background:#1c1c22;border:1px solid rgba(255,255,255,0.14);border-radius:9px',
          'box-shadow:0 10px 40px rgba(0,0,0,0.7);padding:5px;font-family:inherit;font-size:12px'
        ].join(';');
        dropdown.style.top  = (rect.bottom + 6) + 'px';
        dropdown.style.left = Math.max(8, rect.left) + 'px';
        document.body.appendChild(dropdown);
        selectedIdx = 0;
        renderDropdown();
      }

      function renderDropdown() {
        if (!dropdown) return;
        dropdown.innerHTML = '';
        if (filteredTags.length === 0) {
          dropdown.innerHTML = '<div style="padding:8px 10px;opacity:0.5">No matching types</div>';
          return;
        }
        filteredTags.forEach(function(tag, i) {
          var row = document.createElement('div');
          row.style.cssText = 'padding:7px 10px;border-radius:5px;cursor:pointer;display:flex;align-items:center;gap:8px;color:#eee';
          if (i === selectedIdx) row.style.background = 'rgba(90,200,250,0.18)';
          row.innerHTML = '<span class="devdash-tag-chip" data-tag="' + tag + '" style="pointer-events:none">#' + tag + '</span>';
          row.onmouseenter = function() { selectedIdx = i; renderDropdown(); };
          row.onmousedown = function(e) { e.preventDefault(); pickTag(tag); };
          dropdown.appendChild(row);
        });
      }

      function pickTag(tag) {
        if (!triggerTextNode) { hideDropdown(); return; }
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) { hideDropdown(); return; }
        var range = sel.getRangeAt(0);
        var endOffset = (range.endContainer === triggerTextNode) ? range.endOffset : triggerTextNode.textContent.length;
        // Replace from triggerOffset to endOffset (the typed `#xxx` or `/xxx`)
        var before = triggerTextNode.textContent.substring(0, triggerOffset);
        var after = triggerTextNode.textContent.substring(endOffset);
        triggerTextNode.textContent = before;

        var chip = document.createElement('span');
        chip.className = 'devdash-tag-chip';
        chip.setAttribute('data-tag', tag);
        chip.setAttribute('contenteditable', 'false');
        chip.textContent = '#' + tag;

        var afterNode = document.createTextNode(after.length ? after : ' ');
        var parent = triggerTextNode.parentNode;
        if (triggerTextNode.nextSibling) {
          parent.insertBefore(chip, triggerTextNode.nextSibling);
          parent.insertBefore(afterNode, chip.nextSibling);
        } else {
          parent.appendChild(chip);
          parent.appendChild(afterNode);
        }

        var newRange = document.createRange();
        newRange.setStart(afterNode, afterNode.textContent.length);
        newRange.collapse(true);
        sel.removeAllRanges();
        sel.addRange(newRange);

        var sec = chip.closest('[data-section-file]');
        if (sec) {
          sec.classList.add('is-dirty');
          sec.dispatchEvent(new Event('input', { bubbles: true }));
        }
        hideDropdown();
      }

      // Detect # or / as the user types
      document.addEventListener('keydown', function(e) {
        // Navigation keys when dropdown is open
        if (dropdown) {
          if (e.key === 'Escape') { e.preventDefault(); hideDropdown(); return; }
          if (e.key === 'ArrowDown') { e.preventDefault(); selectedIdx = (selectedIdx + 1) % filteredTags.length; renderDropdown(); return; }
          if (e.key === 'ArrowUp')   { e.preventDefault(); selectedIdx = (selectedIdx - 1 + filteredTags.length) % filteredTags.length; renderDropdown(); return; }
          if (e.key === 'Enter' || e.key === 'Tab') {
            e.preventDefault(); e.stopPropagation();
            if (filteredTags[selectedIdx]) pickTag(filteredTags[selectedIdx]);
            return;
          }
        }
      }, true);

      document.addEventListener('input', function(e) {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return;
        var range = sel.getRangeAt(0);
        var node = range.startContainer;
        if (node.nodeType !== Node.TEXT_NODE) { if (dropdown) hideDropdown(); return; }
        if (!inEditableBlock(node)) { if (dropdown) hideDropdown(); return; }

        var text = node.textContent.substring(0, range.startOffset);

        // If dropdown is open, update filter based on text since trigger
        if (dropdown && triggerTextNode === node && triggerOffset >= 0) {
          var typed = node.textContent.substring(triggerOffset + 1, range.startOffset);
          // bail if user typed something that ends the query (space, newline)
          if (/[\s\n]/.test(typed)) { hideDropdown(); return; }
          filteredTags = TAG_TYPES.filter(function(t) { return t.toLowerCase().indexOf(typed.toLowerCase()) === 0; });
          selectedIdx = 0;
          renderDropdown();
          return;
        }

        // Look for a fresh # or / trigger just typed
        var lastChar = text.charAt(text.length - 1);
        var charBefore = text.charAt(text.length - 2);
        if (lastChar !== '#' && lastChar !== '/') return;

        // # triggers anywhere (except mid-word — char before must be space/empty/non-word)
        // / triggers only at bullet start
        if (lastChar === '#') {
          if (charBefore && /\w/.test(charBefore)) return; // mid-word, ignore
        } else if (lastChar === '/') {
          if (!isAtBulletStart(node, range.startOffset - 1)) return;
        }

        trigger = lastChar;
        triggerTextNode = node;
        triggerOffset = range.startOffset - 1;
        filteredTags = TAG_TYPES.slice();
        var rect = range.getBoundingClientRect();
        showDropdown(rect);
      });

      document.addEventListener('mousedown', function(e) {
        if (dropdown && !dropdown.contains(e.target)) hideDropdown();
      });
    })();
    """#

    /// Live query view for the Blocks tab. Reads notes.html and groups
    /// tagged bullets by type. Re-runs on every tab switch + after edits.
    private static let blocksViewJS = #"""
    (function() {
      var TAG_TYPES = ['task','kpi','goal','decision','risk','question','idea'];

      function renderBlocks() {
        var container = document.getElementById('devdash-blocks-view');
        if (!container) return;
        // Source: the Notes section pane on this page
        var notes = document.querySelector('#tab-notes [data-outliner]');
        if (!notes) {
          container.innerHTML = '<div class="empty-state">Notes tab not found.</div>';
          return;
        }
        var groups = {};
        TAG_TYPES.forEach(function(t) { groups[t] = []; });

        notes.querySelectorAll('li').forEach(function(li) {
          var chips = li.querySelectorAll(':scope > .devdash-tag-chip');
          if (chips.length === 0) return;
          // Get text without nested ul, without chip text
          var clone = li.cloneNode(true);
          // Remove nested ul + chips for clean preview
          clone.querySelectorAll('ul, .devdash-tag-chip').forEach(function(n) { n.remove(); });
          var preview = clone.textContent.trim();
          chips.forEach(function(chip) {
            var t = chip.getAttribute('data-tag');
            if (groups[t]) groups[t].push({ text: preview, li: li });
          });
        });

        var html = '';
        var anyFound = false;
        TAG_TYPES.forEach(function(t) {
          var items = groups[t];
          if (items.length === 0) return;
          anyFound = true;
          html += '<div class="block-group">';
          html += '<h3><span class="devdash-tag-chip" data-tag="' + t + '">#' + t + '</span> &middot; ' + items.length + '</h3>';
          items.forEach(function(item, i) {
            html += '<div class="block-row" data-tag="' + t + '" data-idx="' + i + '">' + (item.text || '<em style="opacity:0.5">(empty)</em>') + '</div>';
          });
          html += '</div>';
        });
        if (!anyFound) {
          html = '<div class="empty-state">No tagged bullets yet. Go to Notes and type <code>#task</code>, <code>#kpi</code>, etc. on a bullet.</div>';
        }
        container.innerHTML = html;

        // Click handler — jump to Notes and flash the matching bullet
        container.querySelectorAll('.block-row').forEach(function(row) {
          row.addEventListener('click', function() {
            var t = row.getAttribute('data-tag');
            var i = parseInt(row.getAttribute('data-idx'), 10);
            var target = groups[t][i] && groups[t][i].li;
            if (!target) return;
            // Switch to notes tab
            var notesBtn = document.querySelector('nav.tabs .tab[data-tab="notes"]');
            if (notesBtn) notesBtn.click();
            setTimeout(function() {
              target.scrollIntoView({ behavior: 'smooth', block: 'center' });
              var orig = target.style.background;
              target.style.transition = 'background 0.6s';
              target.style.background = 'rgba(90,200,250,0.25)';
              setTimeout(function() { target.style.background = orig; }, 1200);
            }, 50);
          });
        });
      }

      // Run on tab switch (existing tabScript triggers a click handler on .tab buttons)
      document.addEventListener('click', function(e) {
        var btn = e.target.closest('nav.tabs .tab[data-tab="blocks"]');
        if (btn) setTimeout(renderBlocks, 60);
      });

      // Also render on initial load if Blocks happens to be the active tab
      if (document.readyState === 'complete') {
        setTimeout(renderBlocks, 80);
      } else {
        window.addEventListener('load', function() { setTimeout(renderBlocks, 80); });
      }

      // Re-render when notes section saves
      document.addEventListener('input', function(e) {
        var sec = e.target.closest && e.target.closest('[data-section-file="sections/notes.html"]');
        if (!sec) return;
        // Only re-render if Blocks tab is currently visible
        var blocksPane = document.getElementById('tab-blocks');
        if (blocksPane && blocksPane.classList.contains('active')) {
          clearTimeout(window._devdashBlocksRerenderTimer);
          window._devdashBlocksRerenderTimer = setTimeout(renderBlocks, 400);
        }
      });
    })();
    """#

    /// SPIKE: lossless source editing for lore-backed cards. The "edit source"
    /// button flips a `.lore-card` from its formatted body to a contenteditable
    /// `<pre>` of the raw markdown; on blur / ⌘S it posts the markdown straight
    /// to Swift, which writes it back to the card's `data-lore-file` (the lore
    /// .md). No HTML→markdown conversion — the text round-trips verbatim.
    private static let loreEditJS = """
    (function() {
      function post(p) {
        try { window.webkit.messageHandlers.devdash.postMessage(p); }
        catch (e) { console.error('lore-edit bridge failed', e); }
      }
      // `ta` is the per-card <textarea class="lore-src"> — its .value round-trips
      // the markdown byte-exact (unlike contenteditable + innerText).
      function autosize(ta) { ta.style.height = 'auto'; ta.style.height = ta.scrollHeight + 'px'; }
      function save(ta) {
        var card = ta.closest('.lore-card');
        if (!card) return;
        // Callback round-trip: Swift writes the .md, renders it, and hands the
        // fresh body HTML back so the formatted view updates the instant we save.
        var id = Math.random().toString(36).slice(2);
        window._devdashCallbacks = window._devdashCallbacks || {};
        window._devdashCallbacks[id] = function(result) {
          if (result && typeof result.html === 'string') {
            var bodyEl = card.querySelector('.lore-body');
            if (bodyEl) bodyEl.innerHTML = result.html;   // live re-render
          }
          var warn = card.querySelector('.lore-warn');
          if (warn) {
            if (result && result.warning) { warn.textContent = '⚠ ' + result.warning; warn.style.display = ''; }
            else { warn.style.display = 'none'; }
          }
        };
        post({ action: 'save-lore', path: card.dataset.loreFile, markdown: ta.value, callbackId: id });
        ta.classList.remove('is-dirty');
        ta.classList.add('is-saved');
        setTimeout(function() { ta.classList.remove('is-saved'); }, 1500);
      }
      function wire(ta) {
        if (ta.dataset.wired) return;
        ta.dataset.wired = '1';
        ta.spellcheck = false;
        var t = null;
        ta.addEventListener('input', function() {
          ta.classList.add('is-dirty');
          autosize(ta);
          clearTimeout(t);
          t = setTimeout(function() { save(ta); }, 900);
        });
        ta.addEventListener('blur', function() {
          if (ta.classList.contains('is-dirty')) { clearTimeout(t); save(ta); }
        });
        ta.addEventListener('keydown', function(e) {
          if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); clearTimeout(t); save(ta); }
        });
      }
      document.addEventListener('click', function(e) {
        var btn = e.target.closest('.lore-edit-toggle');
        if (!btn) return;
        e.preventDefault();
        e.stopPropagation();
        var card = btn.closest('.lore-card');
        if (!card) return;
        var bodyEl = card.querySelector('.lore-body');
        var src = card.querySelector('.lore-src');
        if (!src) return;
        var editing = src.style.display !== 'none';
        if (editing) {
          src.style.display = 'none';
          if (bodyEl) bodyEl.style.display = '';
          btn.textContent = '✎ edit source';
        } else {
          if (bodyEl) bodyEl.style.display = 'none';
          src.style.display = '';
          btn.textContent = '✓ done';
          wire(src);
          autosize(src);
          src.focus();
        }
      }, true);

      // Keyboard shortcuts inside the living document.
      document.addEventListener('keydown', function(e) {
        // ⌘N → "+ new" in the currently-visible section.
        if ((e.metaKey || e.ctrlKey) && (e.key === 'n' || e.key === 'N')) {
          var newBtn = document.querySelector('.tab-pane.active .lore-new');
          if (newBtn) { e.preventDefault(); newBtn.click(); }
          return;
        }
        // Esc → finish editing the open card (collapse the textarea).
        if (e.key === 'Escape') {
          var openCard = null;
          document.querySelectorAll('.lore-card .lore-src').forEach(function(s) {
            if (s.style.display !== 'none') openCard = s.closest('.lore-card');
          });
          if (openCard) {
            var toggle = openCard.querySelector('.lore-edit-toggle');
            if (toggle) { e.preventDefault(); toggle.click(); }
          }
        }
      }, true);
    })();
    """
}
