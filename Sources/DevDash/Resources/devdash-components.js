// devdash Alpine components. Loaded after alpine.min.js. Components register
// themselves via the alpine:init event so script load order does not matter.
document.addEventListener('alpine:init', function () {
  Alpine.data('triageBoard', function () {
    return {
      cols: ['now', 'next', 'later', 'cut'],
      cards: [],
      filter: '',
      copyLabel: 'Copy as Markdown',
      _saveTimer: null,

      init: function () {
        // The JSON state block is the previous sibling of this x-data root.
        // See the triage template body in ProductDocGenerator.swift.
        var stateEl = this.$el.previousElementSibling;
        if (stateEl && stateEl.id === 'triage-state') {
          try {
            var parsed = JSON.parse(stateEl.textContent);
            this.cards = Array.isArray(parsed.cards) ? parsed.cards : [];
          } catch (e) {
            console.warn('[devdash] triage state JSON parse failed', e);
            this.cards = [];
          }
        }
        var self = this;
        this.$watch('cards', function () { self.scheduleSave(); }, { deep: true });
      },

      cardsIn: function (col) {
        var f = this.filter;
        return this.cards.filter(function (c) {
          return c.col === col && (!f || (c.tags || []).indexOf(f) !== -1);
        });
      },

      addCard: function (col) {
        var id = 't-' + Math.random().toString(36).slice(2, 9);
        this.cards.push({ id: id, col: col, title: 'New ticket', tags: ['untagged'] });
      },

      removeCard: function (id) {
        this.cards = this.cards.filter(function (c) { return c.id !== id; });
      },

      drop: function (ev, col) {
        ev.preventDefault();
        var id = ev.dataTransfer.getData('id');
        var card = this.cards.find(function (c) { return c.id === id; });
        if (card) card.col = col;
      },

      toggleFilter: function (tag) {
        this.filter = (this.filter === tag) ? '' : tag;
      },

      copyMarkdown: function () {
        var lines = ['# Triage'];
        var self = this;
        this.cols.forEach(function (col) {
          lines.push('');
          lines.push('## ' + col);
          self.cardsIn(col).forEach(function (c) { lines.push('- ' + c.title); });
        });
        if (navigator.clipboard) navigator.clipboard.writeText(lines.join('\n'));
        this.copyLabel = 'Copied!';
        setTimeout(function () { self.copyLabel = 'Copy as Markdown'; }, 1200);
      },

      scheduleSave: function () {
        clearTimeout(this._saveTimer);
        var self = this;
        this._saveTimer = setTimeout(function () {
          var path = self.$el.dataset.sectionFile;
          var state = JSON.stringify({ cards: self.cards });
          if (window.devdashSaveAlpine) window.devdashSaveAlpine(path, state);
        }, 800);
      }
    };
  });
});
