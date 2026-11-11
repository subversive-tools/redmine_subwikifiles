/* Subwikifiles: sync status chip + popover (no dependencies) */
(function () {
  'use strict';

  var ICONS = {
    to_wiki: '↓', to_file: '↑', create_file: '↑', import: '+',
    conflict: '⚠', deleted: '✕', page_deleted: '✕', pending: '+', attachment: '📎', locked: '⊘', skipped: '–', error: '!'
  };
  var ORDER = ['conflict', 'to_wiki', 'to_file', 'create_file', 'import', 'pending', 'attachment', 'locked', 'skipped', 'error'];
  var DECISIONS = {
    conflict: ['file', 'wiki', 'skip'],
    deleted: ['delete_page', 'restore', 'skip'],
    page_deleted: ['delete_file', 'reimport', 'skip'],
    pending: ['import', 'skip'],
    attachment: ['attach', 'skip']
  };
  var ACTIONABLE = ['create_file', 'to_file', 'to_wiki', 'conflict', 'deleted', 'page_deleted', 'import', 'pending', 'attachment'];
  var DELETIONS = ['deleted', 'page_deleted'];
  var DELETE_CHOICES = { deleted: 'delete_page', page_deleted: 'delete_file' };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function fmt(s, vars) {
    return String(s || '').replace(/%\{(\w+)\}/g, function (_, k) { return vars && vars[k] != null ? vars[k] : ''; });
  }

  function init() {
    var cfg = window.SWF_SYNC;
    if (!cfg || document.querySelector('.swf-chip')) return;
    var t = cfg.t;

    var tmp = document.createElement('div');
    tmp.innerHTML = cfg.chip;
    var chip = tmp.firstElementChild;
    var bar = document.querySelector('#content > .contextual');
    if (bar) {
      bar.insertBefore(document.createTextNode(' '), bar.firstChild);
      bar.insertBefore(chip, bar.firstChild);
    } else {
      var content = document.getElementById('content');
      if (!content) return;
      content.insertBefore(chip, content.firstChild);
    }

    var pop = null, plan = null, scope = null, decisions = {}, loading = null;

    // Background run: the server applies all unambiguous actions automatically and
    // returns what is left (only uncertain cases). Falls back to a read-only plan on error.
    function loadPlan() {
      if (loading) return loading;
      var body = 'authenticity_token=' + encodeURIComponent(cfg.token) +
        (cfg.page ? '&page=' + encodeURIComponent(cfg.page) : '');
      loading = fetch(cfg.autoUrl, {
        method: 'POST', credentials: 'same-origin',
        headers: { 'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': cfg.token },
        body: body
      })
        .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
        .then(function (data) {
          plan = data;
          var a = data.auto || {};
          // Current page content was updated from its file: reload once to show it (loop guard)
          if (a.current_page_changed) {
            var k = 'swf-reload:' + location.pathname, last = +(sessionStorage.getItem(k) || 0);
            if (Date.now() - last > 15000) { sessionStorage.setItem(k, Date.now()); window.location.reload(); return data; }
          }
          if (a.done > 0) {
            autoDone = a;
            resetChip();
            flashChip(fmt(t.auto_done, { count: a.done }), autoTip(a));
            setTimeout(function () { updateChip(); }, 4000);
          } else {
            updateChip();
          }
          return data;
        });
      loading.catch(function () { loading = null; });
      return loading;
    }

    var autoDone = null;
    function autoTip(a) {
      var parts = [];
      if (a.to_wiki) parts.push('↓ ' + a.to_wiki);
      if (a.to_file) parts.push('↑ ' + a.to_file);
      if (a.imported) parts.push('+ ' + a.imported);
      return fmt(t.auto_done_tip, { details: parts.join(' · ') });
    }
    function resetChip() {
      chip.classList.remove('swf-info', 'swf-warn', 'swf-error');
      var d = chip.querySelector('.swf-dot'); if (d) d.parentNode.removeChild(d);
      cfg.status.cls = '';
    }
    function flashChip(label, tip) {
      setLabel(label);
      chip.title = tip;
      chip.classList.add('swf-done');
    }
    function setLabel(label) {
      var lbl = chip.querySelector('.icon-label');
      if (lbl) lbl.textContent = label;
      else {
        Array.prototype.slice.call(chip.childNodes).forEach(function (n) { if (n.nodeType === 3) chip.removeChild(n); });
        chip.insertBefore(document.createTextNode(label), chip.firstChild);
      }
    }

    // Highlight the chip also when child pages / the wiki / subprojects need syncing
    function updateChip() {
      if (!plan || cfg.status.cls === 'swf-error') return;
      chip.classList.remove('swf-done');
      if (plan.available.page && plan.counts.page > 0) {
        if (autoDone) {
          // page state after the automatic run: only uncertain cases remain
          var pa = plan.actions.filter(function (a) { return a.scopes.indexOf('page') >= 0 && ACTIONABLE.indexOf(a.kind) >= 0; })[0];
          if (pa) setChip(t['status_' + pa.kind] || t.status_ok, (pa.kind === 'conflict' || DELETIONS.indexOf(pa.kind) >= 0) ? 'swf-warn' : 'swf-info', t['status_tip_' + pa.kind] || '');
        }
        return; // page state already shown
      }
      var s = ['branch', 'wiki', 'tree'].find(function (x) { return plan.available[x] && plan.counts[x] > 0; });
      if (!s) {
        if (autoDone) { setLabel(t.status_ok); chip.title = autoTip(autoDone); }
        return;
      }
      var inScope = plan.actions.filter(function (a) { return a.scopes.indexOf(s) >= 0; });
      var warn = inScope.some(function (a) { return a.kind === 'conflict' || DELETIONS.indexOf(a.kind) >= 0; });
      var tip = fmt(t.status_tip_more, {
        counts: ['branch', 'wiki', 'tree'].filter(function (x) { return plan.available[x]; })
          .map(function (x) { return t['scope_' + x] + ' ' + plan.counts[x]; }).join(' · ')
      });
      setChip(fmt(t['status_more_' + s], { count: plan.counts[s] }), warn ? 'swf-warn' : 'swf-info', tip);
    }

    function setChip(label, cls, tip) {
      chip.classList.remove('swf-info', 'swf-warn', 'swf-error');
      chip.classList.add(cls);
      chip.title = tip;
      setLabel(label);
      if (!chip.querySelector('.swf-dot')) {
        var d = document.createElement('span'); d.className = 'swf-dot'; chip.appendChild(d);
      }
    }

    function close() {
      if (pop) { pop.parentNode.removeChild(pop); pop = null; }
      document.removeEventListener('mousedown', outside, true);
      document.removeEventListener('keydown', onKey, true);
    }
    function outside(e) { if (pop && !pop.contains(e.target) && e.target !== chip && !chip.contains(e.target)) close(); }
    function onKey(e) { if (e.key === 'Escape') close(); }

    function position() {
      var r = chip.getBoundingClientRect();
      var w = pop.offsetWidth;
      var left = r.right + window.scrollX - w;
      if (left < 10) left = 10;
      pop.style.left = left + 'px';
      pop.style.top = (r.bottom + window.scrollY + 6) + 'px';
    }

    function open() {
      if (pop) { close(); return; }
      pop = document.createElement('div');
      pop.className = 'swf-pop';
      pop.innerHTML = '<div class="swf-pop-head"><strong>' + esc(t.title) + '</strong>' +
        '<button type="button" class="swf-pop-close" title="' + esc(t.close) + '">×</button></div>' +
        '<div class="swf-loading">' + esc(t.loading) + '</div>';
      document.body.appendChild(pop);
      position();
      pop.querySelector('.swf-pop-close').onclick = close;
      document.addEventListener('mousedown', outside, true);
      document.addEventListener('keydown', onKey, true);

      loadPlan()
        .then(function (data) {
          plan = data; decisions = {};
          plan.actions.forEach(function (a) { if (DECISIONS[a.kind]) decisions[a.key] = a.default; });
          scope = plan.default_scope;
          render();
        })
        .catch(function (e) {
          if (pop) pop.querySelector('.swf-loading').textContent = t.load_error + ' (' + e.message + ')';
        });
    }

    function scopeTip(s) {
      return fmt(t['scope_tip_' + s], { subprojects: plan.subprojects, pages: plan.branch_pages });
    }

    function render() {
      if (!pop) return;
      var html = '<div class="swf-pop-head"><strong>' + esc(t.title) + '</strong>' +
        '<button type="button" class="swf-pop-close" title="' + esc(t.close) + '">×</button></div>';

      html += '<div class="swf-scopes">';
      ['page', 'branch', 'wiki', 'tree'].forEach(function (s) {
        var avail = plan.available[s];
        html += '<button type="button" class="swf-scope' + (s === scope ? ' swf-active' : '') + '" data-scope="' + s + '"' +
          (avail ? '' : ' disabled') + ' title="' + esc(scopeTip(s)) + '">' + esc(t['scope_' + s]) +
          (avail && plan.counts[s] > 0 ? '<span class="swf-badge">' + (plan.counts[s] > 99 ? '99+' : plan.counts[s]) + '</span>' : '') +
          '</button>';
      });
      html += '</div>';

      var acts = plan.actions.filter(function (a) { return a.scopes.indexOf(scope) >= 0; });
      html += '<div class="swf-list">';
      if (!acts.some(function (a) { return ACTIONABLE.indexOf(a.kind) >= 0; })) {
        html += '<div class="swf-empty">✓ ' + esc(t.in_sync) + '</div>';
      }
      var multiProject = acts.some(function (a) { return a.project_id !== acts[0].project_id; });

      function decisionRow(a) {
        var kind = a.kind;
        return '<div class="swf-row"><span class="swf-ico swf-ico-' + kind + '">' + ICONS[kind] + '</span>' +
          '<div class="swf-body"><div class="swf-label" title="' + esc(t['tip_' + kind]) + '">' + esc(t['kind_' + kind]) + '</div>' +
          '<div class="swf-names">' + nameHtml(a, multiProject) + '</div></div>' +
          '<span class="swf-choice">' + DECISIONS[kind].map(function (d) {
            var on = decisions[a.key] === d;
            return '<button type="button" data-key="' + esc(a.key) + '" data-choice="' + d + '" class="' +
              (on ? 'swf-on' : '') + (on && d.indexOf('delete') === 0 ? ' swf-danger' : '') +
              '" title="' + esc(t['choice_tip_' + kind + '_' + d] || '') + '">' + esc(t['choice_' + d]) + '</button>';
          }).join('') + '</span></div>';
      }

      ORDER.forEach(function (kind) {
        var list = acts.filter(function (a) { return a.kind === kind; });
        if (!list.length) return;
        if (DECISIONS[kind]) {
          list.forEach(function (a) { html += decisionRow(a); });
        } else {
          var names = list.map(function (a) { return nameHtml(a, multiProject); });
          var plain = list.map(function (a) { return (multiProject ? a.project + ' / ' : '') + a.title; }).join(', ');
          html += '<div class="swf-row"><span class="swf-ico swf-ico-' + kind + '">' + ICONS[kind] + '</span>' +
            '<div class="swf-body"><div class="swf-label" title="' + esc(t['tip_' + kind]) + '">' +
            esc(fmt(t['kind_' + kind + (list.length === 1 ? '_one' : '_other')], { count: list.length })) + '</div>' +
            '<div class="swf-names" title="' + esc(plain) + '">' + names.join(', ') + '</div></div></div>';
        }
      });
      var dels = acts.filter(function (a) { return DELETIONS.indexOf(a.kind) >= 0; });
      if (dels.length) {
        html += '<div class="swf-section"><span title="' + esc(t.deletions_tip) + '">' +
          esc(fmt(t.deletions_title, { count: dels.length })) + '</span>' +
          '<span class="swf-bulk"><a href="#" data-bulk="delete">' + esc(t.bulk_delete) + '</a> · ' +
          '<a href="#" data-bulk="skip">' + esc(t.bulk_skip) + '</a></span></div>';
        dels.forEach(function (a) { html += decisionRow(a); });
      }
      html += '</div>';

      var n = acts.filter(function (a) {
        return ACTIONABLE.indexOf(a.kind) >= 0 && !(DECISIONS[a.kind] && decisions[a.key] === 'skip');
      }).length;
      var skipped = acts.filter(function (a) { return DECISIONS[a.kind] && DELETIONS.indexOf(a.kind) < 0 && decisions[a.key] === 'skip'; }).length;
      var hints = [];
      if (acts.some(function (a) { return a.kind === 'conflict'; })) hints.push(t.hint_conflict);
      if (skipped) hints.push(fmt(t.hint_skipped, { count: skipped }));
      html += '<div class="swf-foot"><span class="swf-hint">' + esc(hints.join(' · ')) + '</span>' +
        '<button type="button" class="swf-apply"' + (n ? '' : ' disabled') + '>' + esc(t.apply) + '</button></div>';

      pop.innerHTML = html;
      position();
      pop.querySelector('.swf-pop-close').onclick = close;
      Array.prototype.forEach.call(pop.querySelectorAll('.swf-scope'), function (b) {
        b.onclick = function () { scope = b.getAttribute('data-scope'); render(); };
      });
      Array.prototype.forEach.call(pop.querySelectorAll('.swf-choice button'), function (b) {
        b.onclick = function () { decisions[b.getAttribute('data-key')] = b.getAttribute('data-choice'); render(); };
      });
      Array.prototype.forEach.call(pop.querySelectorAll('[data-bulk]'), function (l) {
        l.onclick = function (e) {
          e.preventDefault();
          var mode = l.getAttribute('data-bulk');
          dels.forEach(function (a) { decisions[a.key] = mode === 'delete' ? DELETE_CHOICES[a.kind] : 'skip'; });
          render();
        };
      });
      pop.querySelector('.swf-apply').onclick = submit;
    }

    function nameHtml(a, multiProject) {
      var label = (multiProject ? a.project + ' / ' : '') + a.title;
      var extra = '';
      if (a.detail && a.detail.indexOf('rename:') === 0) extra = ' ← ' + a.detail.substring(7);
      else if (a.detail && a.detail.indexOf('placeholder:') === 0) extra = ' (' + fmt(t.placeholder, { page: a.detail.substring(12) }) + ')';
      else if (a.detail && a.detail.indexOf('parent:') === 0) extra = ' ' + fmt(t.below, { page: a.detail.substring(7) });
      else if (a.detail && a.detail.indexOf('container:') === 0) extra = ' ' + fmt(t.attach_to, { page: a.detail.substring(10) });
      else if (a.kind === 'skipped') extra = ' (' + (t['reason_' + a.detail] || a.detail) + ')';
      else if (a.kind === 'error') extra = ' (' + a.detail + ')';
      var s = a.url ? '<a href="' + esc(a.url) + '">' + esc(label) + '</a>' : esc(label);
      if (a.fallback) s += ' <span class="swf-est" title="' + esc(t.fallback_tip) + '">≈</span>';
      return s + esc(extra);
    }

    function submit() {
      var delPages = 0, delFiles = 0;
      plan.actions.forEach(function (a) {
        if (a.scopes.indexOf(scope) < 0) return;
        if (decisions[a.key] === 'delete_page') delPages++;
        if (decisions[a.key] === 'delete_file') delFiles++;
      });
      if ((delPages || delFiles) && !window.confirm(fmt(t.confirm_delete, { pages: delPages, files: delFiles }))) return;
      var f = document.createElement('form');
      f.method = 'post';
      f.action = cfg.applyUrl;
      function add(name, value) {
        var i = document.createElement('input');
        i.type = 'hidden'; i.name = name; i.value = value; f.appendChild(i);
      }
      add('authenticity_token', cfg.token);
      add('scope', scope);
      if (cfg.page) add('page', cfg.page);
      Object.keys(decisions).forEach(function (k) { add('decisions[' + k + ']', decisions[k]); });
      document.body.appendChild(f);
      pop.querySelector('.swf-apply').disabled = true;
      f.submit();
    }

    chip.addEventListener('click', function (e) { e.preventDefault(); open(); });
    // Background check of child pages / wiki / subprojects (does not delay the page)
    setTimeout(function () { loadPlan().catch(function () {}); }, 300);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
