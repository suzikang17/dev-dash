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

      // Auto-inject + Add buttons for known structural patterns so that
      // sections scaffolded before this feature shipped still get the
      // affordance. The buttons are appended in-DOM only on first sight;
      // they'll persist into the file once the user makes any edit.
      function autoInject(scope) {
        (scope || document).querySelectorAll('[data-section-file]').forEach(function(sec) {
          if (sec.dataset.autoinjected) return;
          sec.dataset.autoinjected = 'true';

          function makeBtn(label, template, target) {
            var btn = document.createElement('button');
            btn.className = 'add-btn';
            btn.textContent = label;
            btn.dataset.action = 'dom-append-template';
            btn.dataset.template = template;
            btn.dataset.target = target;
            // Critical: section is contenteditable, so without this the click
            // just places the caret inside the button label.
            btn.contentEditable = 'false';
            return btn;
          }
          function tagWith(el, attr, prefix) {
            if (el.dataset[attr]) return el.dataset[attr];
            var id = prefix + Math.random().toString(36).slice(2, 9);
            el.setAttribute('data-' + attr.replace(/([A-Z])/g, '-$1').toLowerCase(), id);
            return id;
          }

          // .kpi-grid → "+ Add KPI" sibling button after the grid
          sec.querySelectorAll('.kpi-grid').forEach(function(grid) {
            if (grid.dataset.autobtn) return;
            grid.dataset.autobtn = '1';
            var id = tagWith(grid, 'kgridId', 'kg-');
            var btn = makeBtn('+ Add KPI', 'kpi', '[data-k-grid-id="' + id + '"]');
            grid.parentNode.insertBefore(btn, grid.nextSibling);
          });

          // ul.checklist → "+ Add item"
          sec.querySelectorAll('ul.checklist').forEach(function(ul) {
            if (ul.dataset.autobtn) return;
            ul.dataset.autobtn = '1';
            var id = tagWith(ul, 'clId', 'cl-');
            var btn = makeBtn('+ Add item', 'checklist-item', '[data-c-l-id="' + id + '"]');
            ul.parentNode.insertBefore(btn, ul.nextSibling);
          });

          // .board .col → "+ Idea" inside each column
          sec.querySelectorAll('.board .col').forEach(function(col) {
            if (col.dataset.autobtn) return;
            col.dataset.autobtn = '1';
            var id = tagWith(col, 'colId', 'col-');
            var btn = makeBtn('+ Idea', 'idea-card', '[data-col-id="' + id + '"]');
            col.appendChild(btn);
          });

          // table tbody → "+ Add row"
          sec.querySelectorAll('table tbody').forEach(function(tbody) {
            if (tbody.dataset.autobtn) return;
            tbody.dataset.autobtn = '1';
            var id = tagWith(tbody, 'tbId', 'tb-');
            var table = tbody.closest('table');
            var btn = makeBtn('+ Add row', 'metric-row', '[data-t-b-id="' + id + '"]');
            (table || tbody).parentNode.insertBefore(btn, (table || tbody).nextSibling);
          });
        });
      }

      // Triage board drag-and-drop. Operates on any .triage-board / .triage-cols
      // ancestor inside an editable section so the dropped state auto-saves.
      function attachTriage(scope) {
        (scope || document).querySelectorAll('.triage-list').forEach(function(list) {
          if (list.dataset.triageAttached) return;
          list.dataset.triageAttached = 'true';
          list.addEventListener('dragover', function(e) {
            e.preventDefault();
            list.classList.add('is-drop-target');
          });
          list.addEventListener('dragleave', function() {
            list.classList.remove('is-drop-target');
          });
          list.addEventListener('drop', function(e) {
            e.preventDefault();
            list.classList.remove('is-drop-target');
            var id = e.dataTransfer.getData('text/triage-id');
            var card = id ? document.querySelector('[data-triage-id="' + id + '"]') : null;
            if (!card) return;
            list.appendChild(card);
            updateCounts(list.closest('.triage-cols'));
            var section = findEditableAncestor(list);
            if (section) {
              section.classList.add('is-dirty');
              save(section);
            }
          });
        });

        (scope || document).querySelectorAll('.triage-card').forEach(function(card) {
          if (card.dataset.triageCardAttached) return;
          card.dataset.triageCardAttached = 'true';
          card.setAttribute('draggable', 'true');
          if (!card.dataset.triageId) {
            card.dataset.triageId = 't-' + Math.random().toString(36).slice(2, 9);
          }
          card.addEventListener('dragstart', function(e) {
            e.dataTransfer.setData('text/triage-id', card.dataset.triageId);
            e.dataTransfer.effectAllowed = 'move';
            card.classList.add('dragging');
          });
          card.addEventListener('dragend', function() {
            card.classList.remove('dragging');
          });
          // Tag click → toggle filter
          card.querySelectorAll('.tag').forEach(function(tag) {
            if (tag.dataset.tagFilterAttached) return;
            tag.dataset.tagFilterAttached = 'true';
            tag.addEventListener('click', function(e) {
              e.stopPropagation();
              var board = card.closest('.triage-cols');
              var current = board && board.dataset.filter;
              var next = (current === tag.textContent) ? '' : tag.textContent;
              if (board) {
                board.dataset.filter = next;
                applyFilter(board);
              }
            });
          });
        });
      }

      function updateCounts(board) {
        if (!board) return;
        board.querySelectorAll('.triage-col').forEach(function(col) {
          var count = col.querySelectorAll('.triage-card').length;
          var cnt = col.querySelector('.tcount');
          if (cnt) cnt.textContent = count;
        });
      }

      function applyFilter(board) {
        var filter = (board.dataset.filter || '').trim();
        board.querySelectorAll('.triage-card').forEach(function(card) {
          if (!filter) { card.classList.remove('is-filtered-out'); return; }
          var tags = Array.from(card.querySelectorAll('.tag')).map(function(t) { return t.textContent; });
          if (tags.indexOf(filter) === -1) card.classList.add('is-filtered-out');
          else card.classList.remove('is-filtered-out');
        });
      }

      // Triage-specific actions
      document.addEventListener('click', function(e) {
        var btn = e.target.closest('[data-action]');
        if (!btn) return;
        var act = btn.dataset.action;

        if (act === 'triage-add') {
          var section = findEditableAncestor(btn);
          if (!section) return;
          var col = btn.dataset.col || 'now';
          var list = section.querySelector('[data-droplist="' + col + '"]');
          if (!list) return;
          var card = document.createElement('div');
          card.className = 'triage-card';
          card.contentEditable = 'true';
          card.dataset.triageId = 't-' + Math.random().toString(36).slice(2, 9);
          card.innerHTML = '<div class="t-title">New ticket</div><div class="t-tags"><span class="tag">untagged</span></div>';
          list.appendChild(card);
          attachTriage(list);
          updateCounts(list.closest('.triage-cols'));
          section.classList.add('is-dirty');
          save(section);
          e.preventDefault();
          return;
        }

        if (act === 'triage-export-md') {
          var section = findEditableAncestor(btn);
          if (!section) return;
          var lines = ['# Triage'];
          section.querySelectorAll('.triage-col').forEach(function(col) {
            var title = (col.querySelector('h4') || {}).textContent || '';
            lines.push('');
            lines.push('## ' + title.replace(/\\d+$/, '').trim());
            col.querySelectorAll('.triage-card').forEach(function(card) {
              var t = (card.querySelector('.t-title') || {}).textContent || '';
              lines.push('- ' + t.trim());
            });
          });
          var md = lines.join('\\n');
          if (navigator.clipboard) navigator.clipboard.writeText(md);
          btn.textContent = 'Copied!';
          setTimeout(function() { btn.textContent = 'Copy as Markdown'; }, 1200);
          e.preventDefault();
          return;
        }
      });

      attachEditing(document);
      autoInject(document);
      attachTriage(document);
      attachActions();   // must run after autoInject so injected buttons get handlers
      // Initialize counts on any boards present
      document.querySelectorAll('.triage-cols').forEach(updateCounts);
      // Re-attach after tab switches (panes are still in DOM but new buttons may exist)
      document.querySelectorAll('nav.tabs .tab').forEach(function(b) {
        b.addEventListener('click', function() {
          setTimeout(function() {
            attachEditing(document);
            autoInject(document);
            attachActions();
          }, 30);
        });
      });
    })();
    """
}

