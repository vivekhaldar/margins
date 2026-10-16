// Margins editor: a contenteditable document with block-level tracked changes.
// Swift drives it through window.margins.*; it reports back via webkit.messageHandlers.margins.
(() => {
  'use strict';
  const $ = (s) => document.querySelector(s);
  const doc = $('#doc');
  const pop = $('#pop');
  const popin = $('#popin');

  const post = (type, data = {}) => {
    const msg = Object.assign({ type }, data);
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.margins;
    if (h) h.postMessage(msg);
    else (window.__marginsLog = window.__marginsLog || []).push(msg); // standalone/debug
  };

  document.execCommand('defaultParagraphSeparator', false, 'p');

  // ---------- ids ----------
  let bseq = 0, cseq = 0;
  const newBid = () => 'b' + (++bseq);
  const newCid = () => 'c' + (++cseq);
  function bumpSeq() {
    doc.querySelectorAll('[data-bid]').forEach((e) => { const m = /^b(\d+)$/.exec(e.dataset.bid); if (m) bseq = Math.max(bseq, +m[1]); });
    doc.querySelectorAll('[data-cid]').forEach((e) => { const m = /^c(\d+)$/.exec(e.dataset.cid); if (m) cseq = Math.max(cseq, +m[1]); });
  }

  const isChg = (el) => el && el.nodeType === 1 && el.classList.contains('chg');
  const tops = () => [...doc.children];
  const chgs = () => [...doc.querySelectorAll(':scope > .chg')];
  const byBid = (id) => tops().find((e) => e.dataset.bid === id);
  const byCid = (id) => chgs().find((e) => e.dataset.cid === id);
  const insOf = (ch) => ch.querySelector(':scope > ins');
  const delOf = (ch) => ch.querySelector(':scope > del');

  // ---------- html hygiene ----------
  const INLINE = new Set(['A', 'B', 'STRONG', 'I', 'EM', 'CODE', 'SPAN', 'U', 'S', 'SUB', 'SUP', 'MARK', 'SMALL', 'BR', 'IMG']);
  const KEEP_ATTRS = new Set(['href', 'src', 'alt', 'colspan', 'rowspan', 'start']);
  const SAFE_IMG = /^(margins-asset:|https?:|data:image\/(png|jpe?g|gif|webp|svg\+xml);)/i;

  function blocksFrom(html) {
    const t = document.createElement('template');
    t.innerHTML = html || '';
    // Diagrams reach the editor as <img src="margins-asset://…">; Swift lifts inline <svg> out first.
    t.content.querySelectorAll('script,style,iframe,object,embed,link,meta,svg,math,foreignObject').forEach((x) => x.remove());
    t.content.querySelectorAll('*').forEach((x) => {
      [...x.attributes].forEach((a) => { if (!KEEP_ATTRS.has(a.name) || /^\s*javascript:/i.test(a.value)) x.removeAttribute(a.name); });
    });
    t.content.querySelectorAll('img').forEach((x) => { if (!SAFE_IMG.test(x.getAttribute('src') || '')) x.remove(); });
    const out = [];
    let para = null;
    [...t.content.childNodes].forEach((n) => {
      if (n.nodeType === 3 && !n.textContent.trim()) return;
      if (n.nodeType === 8) return;
      if (n.nodeType === 3 || INLINE.has(n.tagName)) {
        if (!para) { para = document.createElement('p'); out.push(para); }
        para.appendChild(n);
      } else { para = null; out.push(n); }
    });
    return out;
  }
  const sanitize = (html) => { const d = document.createElement('div'); d.append(...blocksFrom(html)); return d.innerHTML; };

  function clean(el) {
    const c = el.cloneNode(true);
    c.querySelectorAll('.tools,.rb').forEach((x) => x.remove());
    [c, ...c.querySelectorAll('*')].forEach((x) => [...x.attributes].forEach((a) => { if (!KEEP_ATTRS.has(a.name)) x.removeAttribute(a.name); }));
    return c;
  }
  const squash = (s) => s.replace(/\s+/g, ' ').trim();
  function blockHTML(el) {
    if (isChg(el)) { const ins = insOf(el); return ins ? clean(ins).innerHTML.trim() : ''; }
    return clean(el).outerHTML.trim();
  }

  function normalize() {
    [...doc.childNodes].forEach((n) => {
      if (n.nodeType === 8) { n.remove(); return; }
      if (n.nodeType === 3 && !n.textContent.trim()) { n.remove(); return; }
      if (n.nodeType === 3 || (n.nodeType === 1 && INLINE.has(n.tagName) && n.tagName !== 'BR')) {
        const p = document.createElement('p'); doc.insertBefore(p, n); p.appendChild(n);
      } else if (n.nodeType === 1 && n.tagName === 'DIV' && !isChg(n)) {
        const p = document.createElement('p'); p.innerHTML = n.innerHTML; if (n.dataset.bid) p.dataset.bid = n.dataset.bid; n.replaceWith(p);
      }
    });
    if (!doc.textContent.trim() && !doc.querySelector('img,hr,table,.chg')) {
      doc.querySelectorAll(':scope > br').forEach((b) => b.remove());
    }
    const seen = new Set();
    tops().forEach((el) => {
      if (el.tagName === 'BR') return;
      let b = el.dataset.bid;
      if (!b || seen.has(b)) { b = newBid(); el.dataset.bid = b; }
      seen.add(b);
    });
    chgs().forEach((ch) => {
      if (!ch.querySelector(':scope > .tools')) ch.appendChild(tools());
      const d = delOf(ch); if (d) d.contentEditable = 'false';
    });
    doc.classList.toggle('empty', !doc.textContent.trim() && !doc.querySelector('img,hr,table'));
  }

  function currentHTML() {
    const c = doc.cloneNode(true);
    c.querySelectorAll('.sel,.cur,.peek,.flash,.refining').forEach((x) => x.classList.remove('sel', 'cur', 'peek', 'flash', 'refining'));
    return c.innerHTML;
  }

  function sectionOf(node) {
    if (node && node.nodeType === 3) node = node.parentNode;
    if (!node || !doc.contains(node) || node === doc) return 'Document';
    let el = node;
    while (el.parentNode !== doc) el = el.parentNode;
    for (let cur = el; cur; cur = cur.previousElementSibling) {
      const h = /^H[12]$/.test(cur.tagName) ? cur : (isChg(cur) ? (insOf(cur) || cur).querySelector('h1,h2') : null);
      if (h && h.textContent.trim()) return h.textContent.trim();
    }
    return 'Document';
  }

  // ---------- tracked changes ----------
  function tools() {
    const t = document.createElement('span');
    t.className = 'tools';
    t.contentEditable = 'false';
    t.innerHTML = '<button class="ok" data-a="ok" title="Accept (A)">✓</button>' +
      '<button class="no" data-a="no" title="Reject (R)">✕</button>' +
      '<button class="chat" data-a="chat" title="Refine this change (C)">💬</button>';
    return t;
  }

  function makeChg(step, kind, delHTML, insHTML, bid) {
    const ch = document.createElement('div');
    ch.className = 'chg';
    ch.dataset.cid = newCid();
    ch.dataset.step = String(step);
    ch.dataset.bid = bid || newBid();
    ch.dataset.kind = kind;
    const del = document.createElement('del'); del.contentEditable = 'false'; del.innerHTML = delHTML || '';
    const ins = document.createElement('ins'); ins.innerHTML = insHTML || '';
    ch.append(del, ins, tools());
    return ch;
  }

  function flash(el) { el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash'); setTimeout(() => el.classList.remove('flash'), 1500); }

  function applyEdits(step, edits, direct) {
    normalize();
    const missing = [], touched = [], lastAfter = {};
    for (const e of edits || []) {
      const html = sanitize(e.html || '');
      if (e.op === 'insertAfter') {
        const key = e.blockId || '^';
        let anchor = lastAfter[key] || (key === '^' ? null : byBid(key));
        if (key !== '^' && !anchor) { missing.push(key); anchor = doc.lastElementChild; }
        if (!html) continue;
        const nodes = direct ? blocksFrom(html) : [makeChg(step, 'insert', '', html)];
        const ref = anchor ? anchor.nextSibling : doc.firstChild;
        nodes.forEach((n) => doc.insertBefore(n, ref));
        lastAfter[key] = nodes[nodes.length - 1];
        touched.push(...nodes);
        continue;
      }
      const el = byBid(e.blockId);
      if (!el) { missing.push(e.blockId); continue; }
      if (e.op === 'replace') {
        if (squash(blockHTML(el)) === squash(html)) continue; // no-op edit
        if (direct) {
          const nodes = blocksFrom(html);
          if (nodes[0] && nodes[0].nodeType === 1) nodes[0].dataset.bid = el.dataset.bid;
          el.replaceWith(...nodes); touched.push(...nodes);
        } else if (isChg(el)) {
          insOf(el).innerHTML = html;
          el.dataset.step = String(step);
          el.dataset.kind = delOf(el).innerHTML.trim() ? 'replace' : 'insert';
          touched.push(el);
        } else {
          const ch = makeChg(step, 'replace', el.outerHTML, html, el.dataset.bid);
          el.replaceWith(ch); touched.push(ch);
        }
      } else if (e.op === 'delete') {
        if (direct) { el.remove(); }
        else if (isChg(el)) {
          if (!delOf(el).innerHTML.trim()) el.remove();
          else { insOf(el).innerHTML = ''; el.dataset.kind = 'delete'; el.dataset.step = String(step); touched.push(el); }
        } else {
          const ch = makeChg(step, 'delete', el.outerHTML, '', el.dataset.bid);
          el.replaceWith(ch); touched.push(ch);
        }
      }
    }
    normalize();
    const els = touched.filter((n) => n.nodeType === 1 && n.isConnected);
    els.forEach(flash);
    if (els[0]) els[0].scrollIntoView({ block: 'center', behavior: 'smooth' });
    emitPending();
    return { html: currentHTML(), missing, changes: els.filter(isChg).length };
  }

  // ---------- review ----------
  let rev = { ok: 0, no: 0, secs: new Set() }, revTimer = null;
  function noteReview(ch, ok) {
    rev[ok ? 'ok' : 'no']++;
    rev.secs.add(sectionOf(ch));
    clearTimeout(revTimer);
    revTimer = setTimeout(flushReview, 700);
  }
  function flushReview() {
    clearTimeout(revTimer);
    if (!rev.ok && !rev.no) return;
    post('reviewed', { accepted: rev.ok, rejected: rev.no, sections: [...rev.secs], html: currentHTML() });
    rev = { ok: 0, no: 0, secs: new Set() };
  }

  function resolve(ch, ok) {
    if (!ch || !ch.isConnected) return;
    noteReview(ch, ok);
    const src = ok ? insOf(ch) : delOf(ch);
    const nodes = src ? [...src.childNodes] : [];
    if (ok) {
      let first = true;
      nodes.forEach((n) => { if (n.nodeType === 1) { if (first) { n.dataset.bid = ch.dataset.bid; first = false; } else n.removeAttribute('data-bid'); } });
    }
    ch.replaceWith(...nodes);
  }

  function select(filter) {
    filter = filter || {};
    if (filter.all) return chgs();
    if (filter.step != null) return chgs().filter((c) => c.dataset.step === String(filter.step));
    if (filter.selected) return chgs().filter((c) => c.classList.contains('sel'));
    if (filter.cid) return chgs().filter((c) => c.dataset.cid === filter.cid);
    return [];
  }
  function resolveWhere(filter, ok) {
    const list = select(filter);
    list.forEach((c) => resolve(c, ok));
    cur = -1;
    normalize();
    emitPending();
    return { count: list.length, html: currentHTML() };
  }

  function emitPending() {
    const all = chgs(), byStep = {};
    all.forEach((c) => { byStep[c.dataset.step] = (byStep[c.dataset.step] || 0) + 1; });
    const selected = all.filter((c) => c.classList.contains('sel')).length;
    $('#pending').textContent = all.length ? `${all.length} pending change${all.length > 1 ? 's' : ''}` : 'No pending changes';
    $('#accAll').disabled = $('#rejAll').disabled = !all.length;
    $('#selbar').classList.toggle('on', selected > 0);
    $('#selcount').textContent = `${selected} selected`;
    post('pending', { total: all.length, byStep, selected });
    scheduleOutline();
    scheduleMarks();
  }

  // ---------- inline edits ----------
  let editSecs = new Set(), editTimer = null;
  function noteEdit(node) {
    if (!node) { const s = getSelection(); node = s && s.anchorNode; }
    editSecs.add(sectionOf(node));
    clearTimeout(editTimer);
    editTimer = setTimeout(flushEdits, 1500);
  }
  doc.addEventListener('input', () => { noteEdit(); syncLinkPop(); scheduleOutline(); });
  function flushEdits() {
    clearTimeout(editTimer);
    if (!editSecs.size) return;
    const sections = [...editSecs];
    editSecs = new Set();
    normalize();
    post('edited', { sections, html: currentHTML() });
    emitPending();
  }

  // ---------- pointer ----------
  doc.addEventListener('mousedown', (e) => { if (e.target.closest('.tools')) e.preventDefault(); });
  doc.addEventListener('click', (e) => {
    const b = e.target.closest('.tools button');
    if (b) {
      const ch = b.closest('.chg');
      if (b.dataset.a === 'chat') openRefine(ch);
      else { resolve(ch, b.dataset.a === 'ok'); normalize(); emitPending(); }
      return;
    }
    const ch = e.target.closest('.chg');
    const a = e.target.closest('a[href]');
    if (a && (e.metaKey || e.ctrlKey || !a.isContentEditable)) {
      e.preventDefault();
      openURL(a.getAttribute('href'));
      return;
    }
    if (ch && (e.metaKey || e.ctrlKey || e.shiftKey)) {
      e.preventDefault();
      ch.classList.toggle('sel');
      emitPending();
    }
  });
  $('#bar').addEventListener('click', (e) => {
    const a = e.target.closest('[data-act]'); if (!a) return;
    const act = a.dataset.act;
    if (act === 'acc-all') resolveWhere({ all: true }, true);
    else if (act === 'rej-all') resolveWhere({ all: true }, false);
    else if (act === 'acc-sel') resolveWhere({ selected: true }, true);
    else if (act === 'rej-sel') resolveWhere({ selected: true }, false);
    else if (act === 'clear-sel') { chgs().forEach((c) => c.classList.remove('sel')); emitPending(); }
  });

  // ---------- refine popover ----------
  let popFor = null;
  function openRefine(ch) {
    if (!ch) return;
    popFor = ch;
    const r = ch.getBoundingClientRect();
    pop.style.display = 'block';
    const top = Math.min(window.innerHeight - pop.offsetHeight - 10, r.top + 4);
    pop.style.top = Math.max(50, top) + 'px';
    pop.style.left = Math.max(10, Math.min(window.innerWidth - 330, r.right - 320)) + 'px';
    popin.value = '';
    popin.focus();
  }
  function closeRefine() { pop.style.display = 'none'; popFor = null; }
  function requestRefine(ch, text) {
    text = (text || '').trim();
    if (!ch || !text) return;
    closeRefine();
    ch.classList.add('refining');
    post('refine', { cid: ch.dataset.cid, step: +ch.dataset.step, instruction: text });
  }
  pop.querySelectorAll('[data-q]').forEach((b) => b.addEventListener('click', () => requestRefine(popFor, b.dataset.q)));
  popin.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); requestRefine(popFor, popin.value); }
    if (e.key === 'Escape') closeRefine();
  });
  document.addEventListener('mousedown', (e) => { if (popFor && !pop.contains(e.target) && !e.target.closest('.tools')) closeRefine(); });

  // ---------- links ----------
  const lpop = $('#lpop'), lview = $('#lview'), ledit = $('#ledit'), lurl = $('#lurl'), lhref = $('#lhref');
  let linkEl = null, linkRange = null;

  function normalizeURL(s) {
    s = (s || '').trim();
    if (!s) return '';
    if (/^\s*javascript:/i.test(s)) return '';
    if (/^[a-z][a-z0-9+.-]*:/i.test(s) || s.startsWith('#') || s.startsWith('/')) return s;
    if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s)) return 'mailto:' + s;
    return 'https://' + s;
  }
  const looksLikeURL = (s) => /^(https?:\/\/|mailto:|www\.)\S+$/i.test(s.trim()) || /^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(s.trim());
  function openURL(href) { if (href) post('openURL', { url: normalizeURL(href) }); }

  function linkAtSelection() {
    const s = getSelection();
    if (!s || !s.rangeCount) return null;
    let n = s.anchorNode;
    if (n && n.nodeType === 3) n = n.parentNode;
    const a = n && n.closest ? n.closest('a[href]') : null;
    return a && doc.contains(a) ? a : null;
  }
  function placePop(rect) {
    lpop.style.display = 'block';
    const top = rect.bottom + 6 + lpop.offsetHeight > window.innerHeight ? rect.top - lpop.offsetHeight - 6 : rect.bottom + 6;
    lpop.style.top = Math.max(46, top) + 'px';
    lpop.style.left = Math.max(10, Math.min(window.innerWidth - lpop.offsetWidth - 10, rect.left)) + 'px';
  }
  function hideLinkPop() { lpop.style.display = 'none'; lpop.dataset.mode = ''; linkEl = null; }
  function showLinkView(a) {
    linkEl = a;
    lpop.dataset.mode = 'view';
    const href = a.getAttribute('href');
    lhref.textContent = href.replace(/^mailto:/, '');
    lhref.title = href;
    placePop(a.getBoundingClientRect());
  }
  function syncLinkPop() {
    if (lpop.dataset.mode === 'edit' || doc.classList.contains('ro')) return;
    const a = linkAtSelection();
    if (a && a.isContentEditable) showLinkView(a); else if (lpop.dataset.mode === 'view') hideLinkPop();
  }
  document.addEventListener('selectionchange', () => { if (document.activeElement !== lurl) syncLinkPop(); });

  function editLink() {
    if (doc.classList.contains('ro')) return;
    const s = getSelection();
    if (!s || !s.rangeCount || !doc.contains(s.anchorNode)) return;
    const a = linkAtSelection();
    if (a && !a.isContentEditable) return;
    linkEl = a;
    linkRange = s.getRangeAt(0).cloneRange();
    if (!a && linkRange.collapsed) {
      // No selection: link the word under the caret, if any.
      s.modify('move', 'backward', 'word'); s.modify('extend', 'forward', 'word');
      linkRange = s.getRangeAt(0).cloneRange();
      if (!linkRange.toString().trim()) return;
    }
    if (a && a.closest('del')) return;
    const r = (a || linkRange).getBoundingClientRect();
    lpop.dataset.mode = 'edit';
    lurl.value = a ? a.getAttribute('href') : (looksLikeURL(linkRange.toString()) ? linkRange.toString().trim() : '');
    placePop(r);
    lurl.focus(); lurl.select();
  }
  function restoreRange() {
    const s = getSelection();
    s.removeAllRanges();
    if (linkRange) s.addRange(linkRange);
  }
  function applyLink() {
    const url = normalizeURL(lurl.value);
    const a = linkEl;
    doc.focus();
    restoreRange();
    if (!url) { if (a) unlink(a); hideLinkPop(); return; }
    if (a) { a.setAttribute('href', url); noteEdit(a); }
    else {
      document.execCommand('createLink', false, url);
      const s = getSelection();
      if (s.rangeCount) s.collapseToEnd();
    }
    hideLinkPop();
    const now = linkAtSelection() || a;
    if (now) showLinkView(now);
  }
  function unlink(a) {
    const parent = a.parentNode;
    while (a.firstChild) parent.insertBefore(a.firstChild, a);
    a.remove();
    parent.normalize();
    noteEdit(parent);
  }
  $('#lopen').addEventListener('click', () => { if (linkEl) openURL(linkEl.getAttribute('href')); });
  lhref.addEventListener('click', () => { if (linkEl) openURL(linkEl.getAttribute('href')); });
  $('#ledbtn').addEventListener('click', () => {
    const a = linkEl; if (!a) return;
    const r = document.createRange(); r.selectNodeContents(a);
    const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    editLink();
  });
  $('#lrm').addEventListener('click', () => { if (linkEl) { unlink(linkEl); hideLinkPop(); } });
  lpop.addEventListener('mousedown', (e) => { if (e.target !== lurl) e.preventDefault(); });
  lurl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); applyLink(); }
    else if (e.key === 'Escape') { e.preventDefault(); hideLinkPop(); doc.focus(); restoreRange(); }
  });
  document.addEventListener('mousedown', (e) => { if (lpop.dataset.mode === 'edit' && !lpop.contains(e.target)) hideLinkPop(); });
  doc.addEventListener('scroll', hideLinkPop);
  $('#scroll').addEventListener('scroll', () => { if (lpop.dataset.mode) { if (linkEl && lpop.dataset.mode === 'view') showLinkView(linkEl); else hideLinkPop(); } });

  // Paste a URL over selected text → link it.
  doc.addEventListener('paste', (e) => {
    const text = (e.clipboardData && e.clipboardData.getData('text/plain')) || '';
    const s = getSelection();
    if (!looksLikeURL(text) || !s || !s.rangeCount || s.isCollapsed) return;
    e.preventDefault();
    document.execCommand('createLink', false, normalizeURL(text));
    s.collapseToEnd();
  });

  // ---------- images ----------
  // Remember where the caret was so menu-driven inserts land there even after focus moves away.
  let lastRange = null;
  document.addEventListener('selectionchange', () => {
    const s = getSelection();
    if (s && s.rangeCount && doc.contains(s.anchorNode) && !doc.classList.contains('ro')) lastRange = s.getRangeAt(0).cloneRange();
  });
  const imageFiles = (dt) => [...((dt && dt.files) || [])].filter((f) => /^image\//.test(f.type));
  function readBase64(file) {
    return new Promise((res, rej) => {
      const r = new FileReader();
      r.onload = () => res(String(r.result).split(',')[1] || '');
      r.onerror = rej;
      r.readAsDataURL(file);
    });
  }
  async function storeImage(mime, data) {
    const h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.assets;
    if (h) { try { return await h.postMessage({ mime, data }); } catch (_) { return null; } }
    return `data:${mime};base64,${data}`; // standalone (browser) testing
  }
  function insertImage(src, alt) {
    if (doc.classList.contains('ro') || !SAFE_IMG.test(src || '')) return false;
    doc.focus();
    const s = getSelection();
    s.removeAllRanges();
    if (lastRange && doc.contains(lastRange.startContainer)) s.addRange(lastRange);
    else { const r = document.createRange(); r.selectNodeContents(doc); r.collapse(false); s.addRange(r); }
    const marker = 'margins-img-' + Math.random().toString(36).slice(2);
    document.execCommand('insertImage', false, src + '#' + marker);
    const img = [...doc.querySelectorAll('img')].find((i) => i.getAttribute('src').endsWith('#' + marker));
    if (!img) return false;
    img.removeAttribute('style');
    img.setAttribute('src', src);
    img.setAttribute('alt', alt || '');
    normalize();
    noteEdit(img);
    return true;
  }
  async function insertFiles(files) {
    for (const f of files) {
      const src = await storeImage(f.type, await readBase64(f));
      if (src) insertImage(src, f.name.replace(/\.[^.]+$/, ''));
    }
  }
  doc.addEventListener('paste', (e) => {
    const files = imageFiles(e.clipboardData);
    if (!files.length || doc.classList.contains('ro')) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    insertFiles(files);
  }, true);
  doc.addEventListener('dragover', (e) => { if (e.dataTransfer && [...e.dataTransfer.types].includes('Files')) e.preventDefault(); });
  doc.addEventListener('drop', (e) => {
    const files = imageFiles(e.dataTransfer);
    if (!files.length || doc.classList.contains('ro')) return;
    e.preventDefault();
    const pos = document.caretRangeFromPoint && document.caretRangeFromPoint(e.clientX, e.clientY);
    if (pos && doc.contains(pos.startContainer)) lastRange = pos;
    insertFiles(files);
  });

  // ---------- outline ----------
  // A rail beside the page when there's room, otherwise a strip of ticks on the right edge that expands on hover.
  const outline = $('#outline'), otoc = $('#otoc'), oticks = $('#oticks'), scroller = $('#scroll');
  let outlineOn = true, outlineTimer = null, heads = [];
  const RAIL_MIN_WIDTH = 940;
  function scheduleOutline() { clearTimeout(outlineTimer); outlineTimer = setTimeout(buildOutline, 120); }
  function outlineHeads() {
    // Live headings plus headings the agent is proposing (inside <ins>); deleted ones are skipped.
    const out = [];
    let cur = null;
    tops().forEach((el) => {
      const hs = /^H[1-3]$/.test(el.tagName) ? [el] : isChg(el) ? [...(insOf(el) || el).querySelectorAll('h1,h2,h3')] : [];
      hs.forEach((h) => { cur = { el: h, level: +h.tagName[1], text: h.textContent.trim(), proposed: isChg(el), ins: false, del: false }; out.push(cur); });
      if (isChg(el) && cur) { if (el.dataset.kind === 'delete') cur.del = true; else cur.ins = true; }
    });
    return out.filter((h) => h.text);
  }
  function buildOutline() {
    heads = outlineHeads();
    const show = outlineOn && heads.length >= 2;
    document.body.classList.toggle('has-outline', show);
    if (!show) return;
    const minLevel = Math.min(...heads.map((h) => h.level));
    otoc.innerHTML = ''; oticks.innerHTML = '';
    heads.forEach((h, i) => {
      const depth = h.level - minLevel;
      const a = document.createElement('a');
      a.className = 'd' + depth + (h.proposed ? ' prop' : '');
      a.dataset.i = i;
      a.title = h.text;
      const t = document.createElement('span'); t.className = 't'; t.textContent = h.text; a.appendChild(t);
      if (h.ins || h.del) { const d = document.createElement('span'); d.className = 'pd' + (h.ins ? '' : ' del'); d.title = 'Pending changes'; a.appendChild(d); }
      a.addEventListener('mousedown', (e) => e.preventDefault());
      a.addEventListener('click', () => goHead(i));
      otoc.appendChild(a);
      const k = document.createElement('i');
      k.className = 'd' + Math.min(depth, 2) + (h.ins ? ' ins' : h.del ? ' del' : '');
      k.dataset.i = i;
      oticks.appendChild(k);
    });
    layoutOutline();
    spyOutline();
  }
  function layoutOutline() {
    document.body.classList.toggle('outline-rail', innerWidth >= RAIL_MIN_WIDTH);
    outline.style.top = ($('#bar').offsetHeight + 1) + 'px';
  }
  function goHead(i) {
    const h = heads[i]; if (!h) return;
    const top = h.el.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop - 24;
    scroller.scrollTo({ top, behavior: 'smooth' });
    flash(h.el);
  }
  function spyOutline() {
    if (!document.body.classList.contains('has-outline')) return;
    const edge = scroller.getBoundingClientRect().top + 80;
    let cur = 0;
    heads.forEach((h, i) => { if (h.el.isConnected && h.el.getBoundingClientRect().top <= edge) cur = i; });
    outline.querySelectorAll('[data-i]').forEach((e) => e.classList.toggle('cur', +e.dataset.i === cur));
    const a = otoc.querySelector('a.cur');
    if (a && document.body.classList.contains('outline-rail')) {
      const r = a.getBoundingClientRect(), o = otoc.getBoundingClientRect();
      if (r.top < o.top || r.bottom > o.bottom) a.scrollIntoView({ block: 'nearest' });
    }
  }
  oticks.addEventListener('click', (e) => { const i = e.target.dataset && e.target.dataset.i; if (i != null) goHead(+i); });
  $('#ohide').addEventListener('click', () => { setOutline(false); post('outline', { visible: false }); });
  scroller.addEventListener('scroll', spyOutline, { passive: true });
  addEventListener('resize', () => { if (document.body.classList.contains('has-outline')) layoutOutline(); });
  function setOutline(on) { outlineOn = !!on; buildOutline(); }

  // ---------- inline discussion threads ----------
  // Select text → "Ask" chip (or ⌘J) → a popover thread anchored to that passage. The agent answers
  // in the thread; any edits it makes land as ordinary tracked changes. Threads persist as 💬 markers.
  const chip = $('#askchip'), tpop = $('#tpop'), tquote = $('#tquote'), tmsgs = $('#tmsgs'), tchips = $('#tchips'),
    tin = $('#tin'), tmarks = $('#tmarks');
  let threads = [], openT = null, chipFor = null, chipTimer = null, marksTimer = null;
  const hasHL = !!(window.CSS && CSS.highlights && window.Highlight);
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
    : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }));
  const trunc = (s, n) => (s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s);
  const plain = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const threadOpen = () => tpop.style.display === 'flex';

  function setHL(range) {
    if (!hasHL) return;
    if (range && !range.collapsed) CSS.highlights.set('thread', new Highlight(range)); else CSS.highlights.delete('thread');
  }

  function selInfo() {
    if (doc.classList.contains('ro')) return null;
    const s = getSelection();
    if (!s || !s.rangeCount || s.isCollapsed) return null;
    const r = s.getRangeAt(0);
    if (!doc.contains(r.commonAncestorContainer)) return null;
    const quote = plain(s.toString());
    if (quote.length < 2) return null;
    const focus = tops().filter((el) => el.dataset.bid && r.intersectsNode(el)).map((el) => el.dataset.bid);
    if (!focus.length) return null;
    return { range: r.cloneRange(), quote: quote.slice(0, 2000), focus, anchor: focus[0] };
  }

  // Re-find a thread's quote in its blocks (the original Range dies when blocks are rewritten).
  function findQuote(t) {
    const want = plain(t.quote);
    if (!want) return null;
    for (const id of [...new Set([t.anchor, ...(t.focus || [])])]) {
      const el = id && byBid(id);
      if (!el) continue;
      const map = [];
      let norm = '', prevSpace = true;
      const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let n; (n = w.nextNode());) {
        if (n.parentNode.closest && n.parentNode.closest('.tools,.rb')) continue;
        const v = n.nodeValue;
        for (let i = 0; i < v.length; i++) {
          const sp = /\s/.test(v[i]);
          if (sp && prevSpace) continue;
          norm += sp ? ' ' : v[i];
          map.push([n, i]);
          prevSpace = sp;
        }
      }
      for (const q of [want, want.slice(0, 80).trim(), want.slice(0, 32).trim()]) {
        if (q.length < 2) continue;
        const k = norm.indexOf(q);
        if (k < 0) continue;
        const a = map[k], b = map[k + q.length - 1], r = document.createRange();
        r.setStart(a[0], a[1]);
        r.setEnd(b[0], b[1] + 1);
        return r;
      }
    }
    return null;
  }
  const rangeLive = (r) => r && !r.collapsed && doc.contains(r.startContainer) && doc.contains(r.endContainer);

  // ----- the "Ask" chip on selections -----
  function hideChip() { chip.style.display = 'none'; chipFor = null; }
  function syncChip() {
    clearTimeout(chipTimer);
    chipTimer = setTimeout(() => {
      const i = threadOpen() ? null : selInfo();
      if (!i) { hideChip(); return; }
      chipFor = i;
      const rects = i.range.getClientRects();
      const first = rects[0] || i.range.getBoundingClientRect();
      chip.style.display = 'flex';
      const above = first.top - chip.offsetHeight - 8;
      chip.style.top = (above > 46 ? above : first.bottom + 8) + 'px';
      chip.style.left = Math.max(10, Math.min(window.innerWidth - chip.offsetWidth - 10, first.left)) + 'px';
    }, 160);
  }
  document.addEventListener('selectionchange', () => { if (document.activeElement !== tin) syncChip(); });
  chip.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); const i = chipFor || selInfo(); if (i) startThread(i); });

  // ----- the popover -----
  function startThread(i) {
    hideChip();
    hideLinkPop();
    closeRefine();
    openT = { id: uuid(), quote: i.quote, focus: i.focus, anchor: i.anchor, range: i.range };
    getSelection().removeAllRanges();
    showThread();
  }
  function openThreadId(id) {
    const th = threads.find((x) => x.id === id);
    if (!th || doc.classList.contains('ro')) return;
    hideChip();
    openT = { id: th.id, quote: th.quote, focus: th.focus || [], anchor: th.anchor, range: null };
    openT.range = findQuote(openT);
    const el = (openT.range && openT.range.startContainer.parentElement) || byBid(th.anchor);
    if (el) el.scrollIntoView({ block: 'center' });
    showThread();
  }
  function showThread() {
    tquote.textContent = '“' + trunc(openT.quote, 220) + '”';
    tquote.title = openT.quote;
    tin.value = '';
    renderThread();
    placeThread();
    setHL(openT.range);
    drawMarks();
    tin.focus();
  }
  function closeThread() {
    if (!openT) return;
    openT = null;
    tpop.style.display = 'none';
    setHL(null);
    drawMarks();
  }
  function placeThread() {
    if (!openT) return;
    tpop.style.display = 'flex';
    let rect = rangeLive(openT.range) ? openT.range.getBoundingClientRect() : null;
    if (!rect || (!rect.width && !rect.height)) { const b = byBid(openT.anchor); rect = b ? b.getBoundingClientRect() : null; }
    if (!rect) rect = { top: 80, bottom: 80, left: 80, right: 80 };
    const W = tpop.offsetWidth, H = tpop.offsetHeight, art = doc.getBoundingClientRect();
    let left, top;
    if (window.innerWidth - art.right >= W + 20) { left = art.right + 12; top = rect.top - 10; }
    else {
      // Below (or above) the whole passage block so its tracked changes stay visible; else hug the quote.
      const blk = byBid(openT.anchor), br = blk ? blk.getBoundingClientRect() : rect;
      left = Math.max(10, Math.min(window.innerWidth - W - 10, rect.left));
      if (br.bottom + 8 + H <= window.innerHeight - 10) top = br.bottom + 8;
      else if (br.top - H - 8 >= 46) top = br.top - H - 8;
      else {
        top = rect.bottom + 8;
        if (top + H > window.innerHeight - 10 && rect.top - H - 8 > 46) top = rect.top - H - 8;
      }
    }
    tpop.style.left = left + 'px';
    tpop.style.top = Math.max(46, Math.min(window.innerHeight - H - 10, top)) + 'px';
  }
  function bubble(cls, text) {
    const d = document.createElement('div');
    d.className = 'tm ' + cls;
    if (text) d.textContent = text;
    tmsgs.appendChild(d);
    return d;
  }
  function renderThread() {
    if (!openT) return;
    const th = threads.find((x) => x.id === openT.id);
    const msgs = th ? th.messages : [];
    tmsgs.innerHTML = '';
    tchips.style.display = msgs.length ? 'none' : 'flex';
    let working = false;
    for (const m of msgs) {
      bubble('me', m.text);
      if (m.status === 'working') {
        working = true;
        const a = bubble('ai working');
        a.innerHTML = '<span class="spin"></span><span class="act"></span>';
        a.querySelector('.act').textContent = m.waiting ? 'Waiting for your permission — see the panel on the left' : (m.activity || 'Thinking…');
        if (m.step) {
          const b = document.createElement('button');
          b.className = 'stop'; b.textContent = 'Stop';
          b.addEventListener('click', () => post('stop', { step: m.step }));
          a.appendChild(b);
        }
        continue;
      }
      if (m.status === 'failed') { bubble('ai err', m.error || 'Something went wrong.'); continue; }
      const a = bubble('ai', m.reply || '');
      if (m.status === 'pending' || m.status === 'reviewed') {
        if (m.summary && !m.reply) { const s = document.createElement('span'); s.className = 'sum'; s.textContent = m.summary; a.appendChild(s); }
        const c = document.createElement('span');
        if (m.changes > 0) {
          c.className = 'chgs';
          c.textContent = `Proposed ${m.changes} change${m.changes > 1 ? 's' : ''} · Review ↓`;
          c.addEventListener('click', () => { window.margins.revealStep(m.step); });
        } else { c.className = 'chgs done'; c.textContent = 'Changes reviewed'; }
        a.appendChild(c);
      } else if (!m.reply && !(m.files || []).length) a.textContent = m.summary || 'No changes needed.';
      if ((m.files || []).length) {
        const f = document.createElement('span');
        f.className = 'files';
        f.textContent = `Changed ${m.files.length} file${m.files.length > 1 ? 's' : ''}: ${m.files.slice(0, 4).join(', ')}${m.files.length > 4 ? ', …' : ''}`;
        f.title = m.files.join('\n');
        a.appendChild(f);
      }
      (m.notes || []).forEach((n) => { const s = document.createElement('span'); s.className = 'sum'; s.textContent = n; a.appendChild(s); });
    }
    tin.disabled = working;
    tin.placeholder = working ? 'Working…' : (msgs.length ? 'Reply…' : 'Ask about this, or say how to change it…');
    tmsgs.scrollTop = tmsgs.scrollHeight;
  }
  function sendThread(text) {
    text = (text || '').trim();
    if (!openT || !text || tin.disabled) return;
    const t = openT;
    post('ask', { thread: t.id, quote: t.quote, focus: t.focus, anchor: t.anchor, message: text });
    let th = threads.find((x) => x.id === t.id);
    if (!th) { th = { id: t.id, anchor: t.anchor, focus: t.focus, quote: t.quote, messages: [] }; threads.push(th); }
    th.messages.push({ text, status: 'working', activity: 'Starting…' });
    tin.value = '';
    autosize();
    renderThread();
    placeThread();
    drawMarks();
  }
  function autosize() { tin.style.height = 'auto'; tin.style.height = Math.min(120, tin.scrollHeight + 2) + 'px'; }
  tin.addEventListener('input', autosize);
  tin.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendThread(tin.value); }
    else if (e.key === 'Escape') { e.preventDefault(); closeThread(); }
  });
  tchips.querySelectorAll('[data-q]').forEach((b) => b.addEventListener('click', () => sendThread(b.dataset.q)));
  $('#tclose').addEventListener('click', closeThread);
  document.addEventListener('mousedown', (e) => {
    if (openT && !tpop.contains(e.target) && !e.target.closest('.tmark') && !e.target.closest('.tools')) closeThread();
  });

  // ----- margin markers -----
  function scheduleMarks() { clearTimeout(marksTimer); marksTimer = setTimeout(drawMarks, 80); }
  function drawMarks() {
    tmarks.innerHTML = '';
    if (doc.classList.contains('ro')) return;
    const sr = scroller.getBoundingClientRect(), ar = doc.getBoundingClientRect();
    const stack = new Map();
    for (const t of threads) {
      const el = [t.anchor, ...(t.focus || [])].map((id) => id && byBid(id)).find(Boolean);
      if (!el) continue;
      const n = stack.get(el) || 0;
      stack.set(el, n + 1);
      const r = el.getBoundingClientRect();
      const m = document.createElement('button');
      const busy = t.messages.some((x) => x.status === 'working');
      m.className = 'tmark' + (openT && openT.id === t.id ? ' on' : '') + (busy ? ' busy' : '');
      m.innerHTML = '<span class="bub"></span>' + (t.messages.length > 1 ? t.messages.length : '');
      m.title = `“${trunc(t.quote, 120)}” — ${t.messages.length} message${t.messages.length === 1 ? '' : 's'}`;
      m.style.top = (r.top - sr.top + scroller.scrollTop + 2 + n * 24) + 'px';
      m.style.left = (ar.left - sr.left + scroller.scrollLeft + 10) + 'px';
      m.addEventListener('mousedown', (e) => {
        e.preventDefault(); e.stopPropagation();
        if (openT && openT.id === t.id) closeThread(); else openThreadId(t.id);
      });
      tmarks.appendChild(m);
    }
  }
  new ResizeObserver(scheduleMarks).observe(doc);
  window.addEventListener('resize', () => { scheduleMarks(); placeThread(); hideChip(); });
  scroller.addEventListener('scroll', () => { if (openT) placeThread(); if (chipFor) syncChip(); }, { passive: true });
  doc.addEventListener('input', scheduleMarks);

  function setThreads(list) {
    threads = Array.isArray(list) ? list : [];
    if (openT) {
      const th = threads.find((x) => x.id === openT.id);
      if (th && th.focus && th.focus.length) openT.focus = th.focus;
      if (!rangeLive(openT.range)) { openT.range = findQuote(openT); setHL(openT.range); }
      renderThread();
      placeThread();
    }
    drawMarks();
  }

  // ---------- keyboard review ----------
  let cur = -1;
  function move(d) {
    const all = chgs(); if (!all.length) return;
    all.forEach((c) => c.classList.remove('cur'));
    cur = Math.max(0, Math.min(all.length - 1, (cur < 0 && d < 0 ? all.length : cur) + d));
    all[cur].classList.add('cur');
    all[cur].scrollIntoView({ block: 'center', behavior: 'smooth' });
  }
  document.addEventListener('keydown', (e) => {
    if (e.target === popin || e.target === lurl || e.target === tin) return;
    if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'j') {
      const i = selInfo();
      if (i) { e.preventDefault(); startThread(i); }
      return;
    }
    if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'k' && e.target.isContentEditable) {
      e.preventDefault();
      editLink();
      return;
    }
    if (e.target.isContentEditable) {
      if (e.key === 'Escape') { if (openT) { closeThread(); return; } doc.blur(); getSelection().removeAllRanges(); flushEdits(); }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey || doc.classList.contains('ro')) return;
    const all = chgs(), c = all[cur], k = e.key.toLowerCase();
    if (k === 'j') { e.preventDefault(); move(1); }
    else if (k === 'k') { e.preventDefault(); move(-1); }
    else if (k === 'x' && c) { e.preventDefault(); c.classList.toggle('sel'); emitPending(); }
    else if ((k === 'a' || k === 'r') && c) {
      e.preventDefault();
      resolve(c, k === 'a'); normalize(); emitPending();
      const rest = chgs(); if (rest.length) { cur = Math.min(cur, rest.length - 1) - 1; move(1); } else cur = -1;
    } else if (k === 'c' && c) { e.preventDefault(); openRefine(c); }
    else if (k === 'escape') { closeThread(); closeRefine(); chgs().forEach((x) => x.classList.remove('cur', 'sel')); cur = -1; emitPending(); }
  });

  // ---------- preview of historical versions ----------
  let live = null;
  function preview(html) {
    flushEdits();
    if (live === null) live = currentHTML();
    doc.innerHTML = html;
    doc.contentEditable = 'false';
    doc.classList.add('ro');
    document.body.classList.add('previewing');
    closeRefine();
    closeThread();
    hideChip();
    hideLinkPop();
    buildOutline();
    drawMarks();
  }
  function endPreview() {
    if (live === null) return;
    doc.innerHTML = live;
    live = null;
    doc.contentEditable = 'true';
    doc.classList.remove('ro');
    document.body.classList.remove('previewing');
    normalize();
    emitPending();
  }

  // ---------- API for Swift ----------
  window.margins = {
    load(html) {
      live = null;
      closeThread();
      doc.innerHTML = html || '';
      doc.contentEditable = 'true';
      doc.classList.remove('ro');
      document.body.classList.remove('previewing');
      bumpSeq();
      normalize();
      emitPending();
      return currentHTML();
    },
    html: () => { flushEdits(); return currentHTML(); },
    getBlocks() {
      endPreview();
      flushEdits();
      normalize();
      const s = getSelection();
      let focus = [];
      if (s && s.rangeCount && !s.isCollapsed) {
        const r = s.getRangeAt(0);
        if (doc.contains(r.commonAncestorContainer)) focus = tops().filter((el) => r.intersectsNode(el)).map((el) => el.dataset.bid);
      }
      const blocks = tops().filter((el) => el.dataset.bid)
        .map((el) => ({ id: el.dataset.bid, html: blockHTML(el), pending: isChg(el) }))
        .filter((b) => b.html);
      return { blocks, focus };
    },
    applyEdits(step, edits, direct) { endPreview(); return applyEdits(step, edits, !!direct); },
    accept: (filter) => resolveWhere(filter, true),
    reject: (filter) => resolveWhere(filter, false),
    refineContext(cid) {
      const ch = byCid(cid); if (!ch) return null;
      return { blockId: ch.dataset.bid, step: +ch.dataset.step, original: clean(delOf(ch)).innerHTML.trim(), proposed: clean(insOf(ch)).innerHTML.trim() };
    },
    applyRefinement(cid, html, count) {
      const ch = byCid(cid); if (!ch) return null;
      ch.classList.remove('refining');
      const h = sanitize(html);
      insOf(ch).innerHTML = h;
      if (h && ch.dataset.kind === 'delete') ch.dataset.kind = delOf(ch).innerHTML.trim() ? 'replace' : 'insert';
      let rb = ch.querySelector(':scope > .rb');
      if (!rb) { rb = document.createElement('span'); rb.className = 'rb'; rb.contentEditable = 'false'; ch.appendChild(rb); }
      rb.textContent = '↻' + count;
      rb.title = `Refined ${count}×`;
      flash(ch);
      emitPending();
      return currentHTML();
    },
    insertImage: (src, alt) => insertImage(src, alt),
    setOutline: (on) => setOutline(on),
    editLink: () => editLink(),
    refineFailed(cid) { const ch = byCid(cid); if (ch) ch.classList.remove('refining'); },
    highlightStep(step) {
      chgs().forEach((c) => c.classList.toggle('peek', step != null && c.dataset.step === String(step)));
    },
    revealStep(step) { const c = select({ step })[0]; if (c) { c.scrollIntoView({ block: 'center', behavior: 'smooth' }); flash(c); } },
    preview,
    endPreview,
    setThreads: (list) => setThreads(list),
    openThread: (id) => openThreadId(id),
  };

  normalize();
  post('ready');
})();
