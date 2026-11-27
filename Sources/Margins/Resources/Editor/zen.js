// Zen Mode: distraction-free writing surface, optional typewriter centering and paragraph focus,
// and a whisper-quiet hover pill. Toggled from Swift via window.margins.setZenMode.
// Paragraph focus is drawn with a generated stylesheet rule so no class or attribute is ever
// added to #doc content — Zen state can never leak into saved HTML, snapshots, or annotations.
(() => {
  'use strict';
  const root = typeof window !== 'undefined' ? window : globalThis;
  const BLOCKS = 'p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,div,td,th,tr,figcaption,br,hr';
  const EXCLUDED = '.chg > del,.diff-removed,.tools,.rb';

  function countWords(text) {
    return String(text || '').split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;
  }

  // Visible prose only: proposed deletions, removed wording, and margin controls are excluded.
  function proseText(el) {
    const clone = el.cloneNode(true);
    clone.querySelectorAll(EXCLUDED).forEach((n) => n.remove());
    clone.querySelectorAll(BLOCKS).forEach((n) => n.after(' '));
    return clone.textContent;
  }

  function formatWords(n) { return `${n.toLocaleString('en-US')} word${n === 1 ? '' : 's'}`; }

  root.MarginsZen = { countWords, formatWords };
  if (typeof document === 'undefined' || !document.getElementById('zenpill')) return;

  const $ = (id) => document.getElementById(id);
  const body = document.body, doc = $('doc'), scroll = $('scroll'), pill = $('zenpill');
  const words = $('zenwords'), pendingBtn = $('zenpending'), acceptBtn = $('zenaccept');
  const typeBtn = $('zentype'), focusBtn = $('zenfocus');
  const focusRule = document.createElement('style');
  focusRule.id = 'zen-focus-rule';
  document.head.appendChild(focusRule);
  const state = { enabled: false, typewriter: false, paragraphFocus: false };
  let countTimer = null, centerFrame = 0;
  const reduced = () => !!root.MarginsTheme?.reducedMotion();

  const post = (type, data = {}) => {
    const msg = Object.assign({ type }, data);
    const h = root.webkit?.messageHandlers?.margins;
    if (h) h.postMessage(msg);
    else (root.__marginsLog = root.__marginsLog || []).push(msg);
  };

  function wordCount() { return countWords(proseText(doc)); }
  function pendingCount() { return doc.querySelectorAll(':scope > .chg').length; }

  function refreshCounts() {
    clearTimeout(countTimer);
    countTimer = null;
    if (!state.enabled) return;
    words.textContent = formatWords(wordCount());
    const pending = pendingCount();
    pendingBtn.hidden = acceptBtn.hidden = pending === 0;
    pendingBtn.textContent = `${pending} pending`;
  }
  const scheduleCounts = () => { if (state.enabled && !countTimer) countTimer = setTimeout(refreshCounts, 250); };
  const observer = new MutationObserver(scheduleCounts);

  function topBlock(node) {
    while (node && node.parentNode !== doc) node = node.parentNode;
    return node && node.nodeType === 1 ? node : null;
  }

  function updateFocus() {
    if (!(state.enabled && state.paragraphFocus)) { focusRule.textContent = ''; return; }
    const sel = getSelection();
    const a = sel.rangeCount ? topBlock(sel.anchorNode) : null;
    const f = sel.rangeCount ? topBlock(sel.focusNode) : null;
    const index = a && a === f ? [...doc.children].indexOf(a) : -1;
    focusRule.textContent = index >= 0
      ? `body.zen.zen-focus #doc > :nth-child(${index + 1}){opacity:1}`
      : 'body.zen.zen-focus #doc > *{opacity:1}';
  }

  function caretRect() {
    const sel = getSelection();
    if (!sel.rangeCount || !doc.contains(sel.focusNode)) return null;
    const range = document.createRange();
    range.setStart(sel.focusNode, sel.focusOffset);
    const rect = range.getClientRects()[0];
    if (rect && (rect.height || rect.top)) return rect;
    const el = sel.focusNode.nodeType === 1 ? sel.focusNode : sel.focusNode.parentElement;
    return el ? el.getBoundingClientRect() : null;
  }

  function centerCaret() {
    centerFrame = 0;
    if (!(state.enabled && state.typewriter) || !doc.contains(document.activeElement)) return;
    const rect = caretRect();
    if (!rect) return;
    const box = scroll.getBoundingClientRect();
    const delta = rect.top + rect.height / 2 - (box.top + box.height * 0.45);
    if (Math.abs(delta) > 6) scroll.scrollBy({ top: delta, behavior: reduced() ? 'auto' : 'smooth' });
  }
  const scheduleCenter = () => { if (!centerFrame) centerFrame = requestAnimationFrame(centerCaret); };

  function syncControls() {
    body.classList.toggle('zen', state.enabled);
    body.classList.toggle('zen-typewriter', state.enabled && state.typewriter);
    body.classList.toggle('zen-focus', state.enabled && state.paragraphFocus);
    typeBtn.setAttribute('aria-pressed', String(state.typewriter));
    focusBtn.setAttribute('aria-pressed', String(state.paragraphFocus));
    pill.hidden = !state.enabled;
    if (!state.enabled) pill.classList.remove('on');
  }

  function set(options) {
    const o = options && typeof options === 'object' ? options : {};
    const was = state.enabled;
    state.enabled = !!o.enabled;
    state.typewriter = !!o.typewriter;
    state.paragraphFocus = !!o.paragraphFocus;
    syncControls();
    if (state.enabled && !was) observer.observe(doc, { childList: true, characterData: true, subtree: true });
    if (!state.enabled && was) observer.disconnect();
    updateFocus();
    refreshCounts();
    scheduleCenter();
  }

  function togglePref(key) {
    state[key] = !state[key];
    syncControls();
    updateFocus();
    scheduleCenter();
    post('zenPrefs', { typewriter: state.typewriter, paragraphFocus: state.paragraphFocus });
  }

  // Inner overlays, form controls, and active diff-navigation consume Escape first;
  // pressing Escape while writing in #doc exits Zen immediately.
  function escapeConsumed() {
    const shown = (id, display) => { const el = $(id); return !!el && el.style.display === display; };
    if (!$('findbar').hidden || shown('pop', 'block') || (shown('lpop', 'block') && $('lpop').dataset.mode === 'edit') || shown('tpop', 'flex')) return true;
    if (!$('annotation-card').hidden || document.querySelector('.annotation-context')) return true;
    const active = document.activeElement;
    if (active && /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName)) return true;
    if ((!active || !doc.contains(active)) && doc.querySelector('.chg.cur, .chg.sel')) return true;
    if (!active || active === body || pill.contains(active) || doc.contains(active)) return false;
    return active.isContentEditable;
  }

  window.addEventListener('keydown', (e) => {
    if (!state.enabled || e.key !== 'Escape' || e.defaultPrevented || e.isComposing) return;
    if (escapeConsumed()) return;
    e.preventDefault();
    e.stopPropagation();
    post('zenExit');
  }, true);

  document.addEventListener('selectionchange', () => { if (state.enabled && state.paragraphFocus) updateFocus(); });
  doc.addEventListener('input', scheduleCenter);
  doc.addEventListener('keyup', (e) => { if (!['Shift', 'Meta', 'Alt', 'Control'].includes(e.key)) scheduleCenter(); });
  document.addEventListener('mousemove', (e) => {
    if (state.enabled) pill.classList.toggle('on', e.clientY <= 34 || pill.contains(e.target));
  }, { passive: true });
  document.documentElement.addEventListener('mouseleave', () => pill.classList.remove('on'));
  pill.addEventListener('mousedown', (e) => { if (e.target.closest('button')) e.preventDefault(); });
  typeBtn.addEventListener('click', () => togglePref('typewriter'));
  focusBtn.addEventListener('click', () => togglePref('paragraphFocus'));
  $('zenexit').addEventListener('click', () => post('zenExit'));
  acceptBtn.addEventListener('click', () => $('accAll').click());
  pendingBtn.addEventListener('click', () => {
    const next = doc.querySelector(':scope > .chg');
    if (next) next.scrollIntoView({ block: 'center', behavior: reduced() ? 'auto' : 'smooth' });
  });

  Object.assign(root.MarginsZen, { set, state: () => Object.assign({}, state), wordCount, escapeConsumed });
})();
