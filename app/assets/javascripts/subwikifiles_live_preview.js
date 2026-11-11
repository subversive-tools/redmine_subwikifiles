/* Subwikifiles: HedgeDoc-style live split preview for Redmine's jsToolBar */
(function () {
  'use strict';

  var STORAGE_KEY = 'swf-editor-mode'; // 'split' | 'edit'
  var RATIO_KEY = 'swf-editor-split-ratio'; // percentage 20..80
  var DEBOUNCE_MS = 280;

  function initBlock(block, cfg) {
    if (!block || block.getAttribute('data-swf-live')) return;
    var tabsUl = block.querySelector('.jstTabs > ul');
    var editTab = tabsUl && tabsUl.querySelector('a.tab-edit');
    var previewTab = tabsUl && tabsUl.querySelector('a.tab-preview');
    var elementsLi = tabsUl && tabsUl.querySelector('li.tab-elements');
    var toolbar = block.querySelector('.jstElements');
    var editor = block.querySelector('.jstEditor');
    var textarea = editor && editor.querySelector('textarea.wiki-edit');
    var preview = editor && editor.querySelector('.wiki-preview');
    if (!tabsUl || !editTab || !previewTab || !textarea || !preview) return;

    var previewUrl = previewTab.getAttribute('data-url');
    if (!previewUrl) return;
    block.setAttribute('data-swf-live', '1');

    // Create the "Split" tab between Edit and Preview
    var splitLi = document.createElement('li');
    var splitLink = document.createElement('a');
    splitLink.href = '#';
    splitLink.className = 'tab-split';
    splitLink.textContent = (cfg && cfg.label) || 'Split';
    if (cfg && cfg.tip) splitLink.title = cfg.tip;
    splitLi.appendChild(splitLink);
    var previewLi = previewTab.parentNode;
    tabsUl.insertBefore(splitLi, previewLi);

    // Create draggable split handle between textarea and preview
    var divider = document.createElement('div');
    divider.className = 'swf-split-divider';
    if (cfg && cfg.dividerTip) divider.title = cfg.dividerTip;
    editor.insertBefore(divider, preview);

    function setRatio(pct, save) {
      var clamped = Math.max(20, Math.min(80, pct));
      editor.style.setProperty('--swf-split-ratio', clamped.toFixed(1) + '%');
      if (save) {
        try { localStorage.setItem(RATIO_KEY, clamped.toFixed(1)); } catch (e) {}
      }
    }

    try {
      var savedRatio = parseFloat(localStorage.getItem(RATIO_KEY));
      if (!isNaN(savedRatio) && savedRatio >= 20 && savedRatio <= 80) {
        setRatio(savedRatio, false);
      }
    } catch (e) {}

    divider.addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      e.preventDefault();
      block.classList.add('swf-dragging');
      var lastPct = 50;

      function onMove(ev) {
        var rect = editor.getBoundingClientRect();
        if (rect.width <= 0) return;
        lastPct = ((ev.clientX - rect.left) / rect.width) * 100;
        setRatio(lastPct, false);
        syncHeight();
      }

      function onUp() {
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup', onUp);
        block.classList.remove('swf-dragging');
        setRatio(lastPct, true);
      }

      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    });

    divider.addEventListener('dblclick', function () {
      setRatio(50, true);
      syncHeight();
    });

    var timer = null;
    var ctrl = null;
    var lastSent = null;
    var syncingScroll = false;

    function syncHeight() {
      if (!block.classList.contains('swf-split')) {
        preview.style.height = '';
        preview.style.maxHeight = '';
        return;
      }
      var h = textarea.offsetHeight;
      if (h > 80) {
        preview.style.height = h + 'px';
        preview.style.maxHeight = h + 'px';
        preview.style.minHeight = h + 'px';
      }
    }

    function syncScrollFromEditor() {
      if (!block.classList.contains('swf-split') || syncingScroll) return;
      var maxEdit = textarea.scrollHeight - textarea.clientHeight;
      var maxPrev = preview.scrollHeight - preview.clientHeight;
      if (maxEdit <= 0 || maxPrev <= 0) return;
      syncingScroll = true;
      preview.scrollTop = (textarea.scrollTop / maxEdit) * maxPrev;
      window.requestAnimationFrame(function () { syncingScroll = false; });
    }

    function syncScrollFromPreview() {
      if (!block.classList.contains('swf-split') || syncingScroll) return;
      var maxEdit = textarea.scrollHeight - textarea.clientHeight;
      var maxPrev = preview.scrollHeight - preview.clientHeight;
      if (maxEdit <= 0 || maxPrev <= 0) return;
      syncingScroll = true;
      textarea.scrollTop = (preview.scrollTop / maxPrev) * maxEdit;
      window.requestAnimationFrame(function () { syncingScroll = false; });
    }

    function serializeAttachments() {
      var form = block.closest('form');
      if (!form) return '';
      var inputs = form.querySelectorAll('.attachments_fields input, .attachments_form input');
      var parts = [];
      Array.prototype.forEach.call(inputs, function (inp) {
        if (inp.name && !inp.disabled && inp.type !== 'file') {
          parts.push(encodeURIComponent(inp.name) + '=' + encodeURIComponent(inp.value));
        }
      });
      return parts.join('&');
    }

    function renderPreview(force) {
      if (!block.classList.contains('swf-split')) return;
      var text = textarea.value;
      if (!force && text === lastSent) return;
      lastSent = text;

      if (ctrl && typeof ctrl.abort === 'function') ctrl.abort();
      ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;

      var tokenMeta = document.querySelector('meta[name="csrf-token"]');
      var token = (cfg && cfg.token) || (tokenMeta && tokenMeta.content) || '';
      var body = 'text=' + encodeURIComponent(text);
      var att = serializeAttachments();
      if (att) body += '&' + att;

      preview.classList.add('swf-updating');
      fetch(previewUrl, {
        method: 'POST',
        credentials: 'same-origin',
        signal: ctrl ? ctrl.signal : undefined,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-CSRF-Token': token,
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: body
      })
        .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
        .then(function (html) {
          preview.classList.remove('swf-updating');
          preview.innerHTML = html;
          if (typeof window.setupWikiTableSortableHeader === 'function') {
            window.setupWikiTableSortableHeader();
          }
          syncHeight();
          syncScrollFromEditor();
        })
        .catch(function (err) {
          if (err && err.name === 'AbortError') return;
          preview.classList.remove('swf-updating');
        });
    }

    function scheduleRender() {
      if (!block.classList.contains('swf-split')) return;
      if (timer) clearTimeout(timer);
      timer = setTimeout(function () { renderPreview(false); }, DEBOUNCE_MS);
    }

    function enableSplit(savePref) {
      block.classList.add('swf-split');
      if (toolbar) toolbar.classList.remove('hidden');
      textarea.classList.remove('hidden');
      preview.classList.remove('hidden');
      editTab.classList.remove('selected');
      previewTab.classList.remove('selected');
      splitLink.classList.add('selected');
      syncHeight();
      renderPreview(true);
      if (savePref) {
        try { localStorage.setItem(STORAGE_KEY, 'split'); } catch (e) {}
      }
    }

    function leaveSplit(saveEditPref) {
      if (timer) { clearTimeout(timer); timer = null; }
      if (ctrl && typeof ctrl.abort === 'function') ctrl.abort();
      block.classList.remove('swf-split');
      splitLink.classList.remove('selected');
      preview.style.height = '';
      preview.style.maxHeight = '';
      if (saveEditPref) {
        try { localStorage.setItem(STORAGE_KEY, 'edit'); } catch (e) {}
      }
    }

    splitLink.addEventListener('click', function (e) {
      e.preventDefault();
      if (block.classList.contains('swf-split')) {
        leaveSplit(true);
        editTab.click();
      } else {
        enableSplit(true);
        textarea.focus();
      }
    });

    editTab.addEventListener('click', function () {
      if (block.classList.contains('swf-split')) {
        leaveSplit(true);
        if (toolbar) toolbar.classList.remove('hidden');
        textarea.classList.remove('hidden');
        preview.classList.add('hidden');
        editTab.classList.add('selected');
      }
    });

    previewTab.addEventListener('click', function () {
      if (block.classList.contains('swf-split')) {
        leaveSplit(false);
        if (toolbar) toolbar.classList.add('hidden');
        textarea.classList.add('hidden');
        preview.classList.remove('hidden');
        previewTab.classList.add('selected');
      }
    });

    textarea.addEventListener('input', scheduleRender);
    textarea.addEventListener('scroll', syncScrollFromEditor);
    preview.addEventListener('scroll', syncScrollFromPreview);

    if (toolbar) {
      toolbar.addEventListener('click', function (e) {
        if (e.target && e.target.closest('button')) {
          setTimeout(scheduleRender, 20);
        }
      });
    }

    if (typeof ResizeObserver !== 'undefined') {
      new ResizeObserver(syncHeight).observe(textarea);
    } else {
      window.addEventListener('resize', syncHeight);
      textarea.addEventListener('mouseup', syncHeight);
    }

    // Restore user preference (default: split on wide screens for the main wiki editor)
    var saved = null;
    try { saved = localStorage.getItem(STORAGE_KEY); } catch (e) {}
    var isMainWikiEditor = textarea.id === 'content_text';
    if ((saved === 'split' || (saved === null && isMainWikiEditor)) && window.innerWidth > 900) {
      enableSplit(false);
    }
  }

  function init() {
    var cfg = window.SWF_LIVE_PREVIEW || {};
    Array.prototype.forEach.call(document.querySelectorAll('.jstBlock'), function (b) {
      initBlock(b, cfg);
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
