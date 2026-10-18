// Annotation presentation lives beside the editor, never inside its saved HTML.
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const doc = $('doc'), scroll = $('scroll'), toggle = $('annotation-toggle');
  const layer = $('annotation-layer'), highlights = $('annotation-highlights'), markers = $('annotation-markers');
  const card = $('annotation-card'), content = $('annotation-card-content'), title = $('annotation-card-title');
  const browse = $('annotation-list-button'), count = $('annotation-count'), status = $('annotation-status');
  let state = { spans: [], runs: [], comments: [] }, enabled = false, frame = 0;
  let view = null, returnFocus = null, rectangles = [], selection = null, listFilter = 'all', listQuery = '';
  let wasReadOnly = doc.classList.contains('ro');
  let renderedKey = '';
  let contextMenu = null;
  const engine = () => window.MarginsAnnotations;
  const asArray = value => Array.isArray(value) ? value : [];
  const text = value => value == null ? '' : String(value);
  const trim = value => text(value).trim();
  const shorten = (value, n = 110) => { const s = text(value).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  const date = value => { if (!value) return ''; const d = new Date(value); return Number.isNaN(d.valueOf()) ? text(value) : d.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }); };
  const runById = id => asArray(state.runs).find(run => text(run.id) === text(id));
  const commentById = id => asArray(state.comments).find(comment => text(comment.id) === text(id));
  const attributedSpans = () => asArray(state.spans).filter(span => (span.origin === 'agent' || span.origin === 'uncertain') && span.runId);
  const spansFor = id => attributedSpans().filter(span => text(span.runId) === text(id));
  const announce = message => { status.textContent = ''; requestAnimationFrame(() => { status.textContent = message; }); };
  function node(tag, className, value) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (value != null) el.textContent = value;
    return el;
  }
  function button(label, action, className = '') {
    const el = node('button', 'btn ' + className, label); el.type = 'button';
    el.addEventListener('click', action); return el;
  }
  function paragraph(value, className = '') { const el = node('p', className, text(value)); content.append(el); return el; }
  function section(label, parent = content) { const el = node('section', 'annotation-section'); el.append(node('h3', '', label)); parent.append(el); return el; }
  function syncState() { if (engine()) state = engine().getState() || state; }
  function getSelection() {
    const live = window.getSelection();
    if (live && live.rangeCount && !live.isCollapsed && doc.contains(live.getRangeAt(0).commonAncestorContainer)) {
      const s = engine() && engine().getSelection();
      if (s && s.end > s.start) selection = Object.assign({}, s);
    }
    return selection && selection.end > selection.start ? Object.assign({}, selection) : null;
  }
  function rectsFor(item) {
    if (!engine()) return [];
    try {
      const rects = item.kind === 'comment' && engine().getCommentRects
        ? engine().getCommentRects(item.value.id) : engine().getRects(item.value.start, item.value.end);
      return Array.from(rects || []).filter(r => r.width > 0 && r.height > 0);
    } catch (_) { return []; }
  }
  function itemRects(kind, value) { return rectsFor({ kind, value }); }
  function setEnabled(on) {
    enabled = !!on; toggle.checked = enabled;
    layer.hidden = !enabled;
    document.body.classList.toggle('annotations-visible', enabled);
    if (!enabled) { highlights.replaceChildren(); markers.replaceChildren(); rectangles = []; close(false); }
    schedulePaint();
  }
  function schedulePaint() { if (!frame) frame = requestAnimationFrame(() => { frame = 0; paint(); }); }
  function paint() {
    syncState();
    const nComments = asArray(state.comments).length, nRuns = new Set(attributedSpans().map(s => s.runId)).size;
    count.textContent = nComments + nRuns ? '(' + (nComments + nRuns) + ')' : '';
    if (!enabled) { layer.hidden = true; highlights.replaceChildren(); markers.replaceChildren(); rectangles = []; return; }
    layer.hidden = false;
    const sr = scroll.getBoundingClientRect(), dr = doc.getBoundingClientRect();
    const offsetX = -sr.left + scroll.scrollLeft, offsetY = -sr.top + scroll.scrollTop;
    const hf = document.createDocumentFragment(), mf = document.createDocumentFragment(), anchors = [];
    const blockBounds = new Map(Array.from(doc.children).map(block => [block.dataset.bid, block.getBoundingClientRect()]));
    const visible = item => {
      const start = item.kind === 'run' ? item.value.blockId : item.value.anchor && item.value.anchor.start && item.value.anchor.start.blockId;
      const end = item.kind === 'run' ? start : item.value.anchor && item.value.anchor.end && item.value.anchor.end.blockId;
      const a = blockBounds.get(start), b = blockBounds.get(end);
      return !a || !b || Math.max(a.bottom, b.bottom) >= sr.top - 60 && Math.min(a.top, b.top) <= sr.bottom + 60;
    };
    rectangles = [];
    const items = attributedSpans().map(value => ({ kind: 'run', value }))
      .concat(asArray(state.comments).filter(c => !c.detached && !c.resolved).map(value => ({ kind: 'comment', value })));
    for (const item of items) {
      if (!visible(item)) continue;
      const rects = rectsFor(item).filter(r => r.bottom >= sr.top - 60 && r.top <= sr.bottom + 60);
      if (!rects.length) continue;
      const key = item.kind === 'run' ? 'run:' + item.value.runId : 'comment:' + item.value.id;
      for (const r of rects) {
        const el = node('div', 'annotation-highlight ' + (item.kind === 'run' ? 'annotation-attribution' + (item.value.origin === 'uncertain' ? ' annotation-uncertain' : '') : 'annotation-comment-line'));
        Object.assign(el.style, { left: r.left + offsetX + 'px', top: r.top + offsetY + 'px', width: r.width + 'px', height: r.height + 'px' });
        hf.append(el);
        rectangles.push({ rect: r, kind: item.kind, id: item.kind === 'run' ? item.value.runId : item.value.id, key });
      }
      anchors.push({ y: rects[0].top + offsetY, key, kind: item.kind, id: item.kind === 'run' ? item.value.runId : item.value.id, uncertain: item.value.origin === 'uncertain' });
    }
    // Nearby range starts share one marker. Counts refer to unique contributions and threads.
    anchors.sort((a, b) => a.y - b.y);
    const groups = [];
    for (const anchor of anchors) {
      let group = groups[groups.length - 1];
      if (!group || anchor.y - group.y > 25) { group = { y: anchor.y, items: [] }; groups.push(group); }
      const existing = group.items.find(item => item.key === anchor.key);
      if (!existing) group.items.push(anchor); else if (anchor.uncertain) existing.uncertain = true;
    }
    let previousBottom = -Infinity;
    const gutter = Math.min(scroll.clientWidth - 78, dr.right + offsetX + 7);
    for (const group of groups) {
      const y = Math.max(group.y, previousBottom + 4); previousBottom = y + 24;
      const runs = group.items.filter(i => i.kind === 'run').length, comments = group.items.filter(i => i.kind === 'comment').length;
      const uncertain = group.items.some(i => i.uncertain);
      const label = [runs ? (uncertain ? 'AI? ' : 'AI ') + runs : '', comments ? 'C ' + comments : ''].filter(Boolean).join(' · ');
      const el = button(label, () => showGroup(group.items, el), 'annotation-marker');
      el.setAttribute('aria-label', [runs ? runs + ' agent contribution' + (runs > 1 ? 's' : '') : '', comments ? comments + ' comment thread' + (comments > 1 ? 's' : '') : ''].filter(Boolean).join(', '));
      if (uncertain) el.setAttribute('aria-label', el.getAttribute('aria-label') + '. Agent revised; exact span uncertain.');
      el.title = el.getAttribute('aria-label');
      Object.assign(el.style, { left: Math.max(6, gutter) + 'px', top: y + 'px' }); mf.append(el);
    }
    highlights.replaceChildren(hf); markers.replaceChildren(mf);
  }
  function place(anchor) {
    const headerBottom = $('formatbar').getBoundingClientRect().bottom;
    const width = Math.min(400, window.innerWidth - 24);
    card.style.width = width + 'px';
    card.style.maxHeight = Math.max(160, window.innerHeight - headerBottom - 24) + 'px';
    const top = Math.max(headerBottom + 10, Math.min(anchor && anchor.top || headerBottom + 16, window.innerHeight - 300));
    card.style.top = top + 'px';
    card.style.left = Math.max(12, window.innerWidth - width - 16) + 'px';
  }
  function open(next, origin, anchor) {
    getSelection();
    if (card.hidden) returnFocus = origin || document.activeElement;
    setEnabled(true); view = next;
    card.hidden = false; browse.setAttribute('aria-expanded', 'true');
    $('askchip').style.display = 'none'; $('commentchip').style.display = 'none';
    renderCard(); place(anchor);
    const focus = content.querySelector('textarea,input,select,button');
    (focus || $('annotation-close')).focus({ preventScroll: true });
  }
  function close(restore = true) {
    card.hidden = true; view = null; content.replaceChildren(); browse.setAttribute('aria-expanded', 'false');
    if (restore && returnFocus && returnFocus.isConnected) returnFocus.focus({ preventScroll: true });
  }
  function focusRange(kind, id) {
    const value = kind === 'comment' ? commentById(id) : spansFor(id)[0];
    if (!value) return null;
    let rects = itemRects(kind, value);
    if (!rects.length) return null;
    const sr = scroll.getBoundingClientRect();
    if (rects[0].top < sr.top + 30 || rects[0].bottom > sr.bottom - 50) {
      scroll.scrollTop += rects[0].top - sr.top - scroll.clientHeight / 3;
      rects = itemRects(kind, value); schedulePaint();
    }
    return rects[0];
  }
  function showRun(id, origin) { syncState(); if (!runById(id) && !spansFor(id).length) return; const anchor = focusRange('run', id); open({ kind: 'run', id }, origin, anchor); }
  function showComment(id, origin) { syncState(); if (!commentById(id)) return; const anchor = focusRange('comment', id); open({ kind: 'comment', id }, origin, anchor); }
  function showGroup(items, origin) {
    if (items.length === 1) { const item = items[0]; return item.kind === 'run' ? showRun(item.id, origin) : showComment(item.id, origin); }
    open({ kind: 'group', items }, origin, origin && origin.getBoundingClientRect());
  }
  function compose() {
    const target = getSelection() || selection;
    if (!target || target.end <= target.start || doc.classList.contains('ro')) { announce('Select a passage in the document to comment on.'); return false; }
    open({ kind: 'compose', selection: Object.assign({}, target) }, document.activeElement);
    return true;
  }
  function formEditor(options) {
    const form = node('form', 'annotation-editor');
    const label = node('label', '', options.label); label.htmlFor = 'annotation-composer';
    const input = node('textarea'); input.id = 'annotation-composer'; input.rows = options.rows || 4;
    input.value = options.value || ''; input.required = true; input.placeholder = options.placeholder || 'Write a comment…';
    const actions = node('div', 'annotation-actions');
    const save = button(options.save || 'Save comment', () => {}, 'p'); save.type = 'submit'; save.id = 'annotation-save';
    const cancel = button('Cancel', options.cancel || (() => close()));
    actions.append(cancel, save); form.append(label, input, actions);
    form.addEventListener('submit', event => { event.preventDefault(); const value = input.value.trim(); if (value) options.submit(value); });
    input.addEventListener('keydown', event => { if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); event.stopPropagation(); form.requestSubmit(); } });
    content.append(form); return input;
  }
  function quote(value) { if (trim(value)) content.append(node('blockquote', 'annotation-quote', '“' + shorten(value, 260) + '”')); }
  function renderCard() {
    if (!view) return;
    const active = document.activeElement;
    const focused = content.contains(active) ? { id: active.id, tag: active.tagName, label: active.textContent } : null;
    const nextKey = view.kind + ':' + (view.id || '');
    const sameView = nextKey === renderedKey, savedScroll = sameView ? content.scrollTop : 0;
    const expandedTools = sameView ? new Set(Array.from(content.querySelectorAll('details[open]')).map(el => el.dataset.stepId)) : new Set();
    renderedKey = nextKey;
    content.replaceChildren();
    title.textContent = view.kind === 'compose' ? 'Add a comment' : view.kind === 'run' ? 'Agent attribution' : view.kind === 'comment' ? 'Comment thread' : 'Attribution & comments';
    if (view.kind === 'compose') {
      quote(view.selection.text);
      paragraph('Comments stay in this document. Use “Ask agent about this” to start an agent discussion.', 'annotation-hint');
      const target = view.selection;
      formEditor({ label: 'Comment', save: 'Save comment', submit: body => {
        const result = engine().addComment(body, target); syncState();
        const id = typeof result === 'string' ? result : result && result.id;
        announce('Comment saved.');
        if (id) showComment(id); else { view = { kind: 'list' }; renderCard(); }
      } });
    } else if (view.kind === 'run') renderRun(runById(view.id));
    else if (view.kind === 'comment') renderComment(commentById(view.id));
    else if (view.kind === 'group') renderGroup(view.items);
    else renderList();
    content.querySelectorAll('details').forEach(el => { if (expandedTools.has(el.dataset.stepId)) el.open = true; });
    content.scrollTop = savedScroll;
    if (focused) {
      const controls = Array.from(content.querySelectorAll('textarea,input,select,button'));
      const replacement = controls.find(el => focused.id && el.id === focused.id) || controls.find(el => el.tagName === focused.tag && el.textContent === focused.label) || controls[0];
      if (replacement) replacement.focus({ preventScroll: true });
    }
  }
  function renderRun(run) {
    if (view && spansFor(view.id).some(span => span.origin === 'uncertain')) paragraph('Agent revised; exact span uncertain.', 'annotation-uncertain-label');
    if (!run) { paragraph('Details were not recorded for this agent contribution.', 'annotation-hint'); return; }
    const meta = node('div', 'annotation-meta');
    const providerModel = [trim(run.provider) || 'Provider not recorded', trim(run.model) || 'Model not recorded'].join(' · ');
    meta.append(node('span', '', providerModel));
    if (run.createdAt) meta.append(node('time', '', date(run.createdAt)));
    if (run.status) meta.append(node('span', 'annotation-badge', text(run.status)));
    content.append(meta);
    const instruction = section('Original instruction'); instruction.append(node('p', 'annotation-preserve', run.instruction || run.text || 'Instruction was not recorded.'));
    if (trim(run.refinement)) { const s = section('This refinement'); s.append(node('p', 'annotation-preserve', text(run.refinement))); }
    if (trim(run.summary)) { const s = section('Summary'); s.append(node('p', 'annotation-preserve', text(run.summary))); }
    const notes = asArray(run.notes).filter(Boolean);
    if (notes.length) { const s = section('Notes'); const ul = node('ul'); notes.forEach(note => ul.append(node('li', '', text(note)))); s.append(ul); }
    const refinements = asArray(run.refinements);
    if (refinements.length) {
      const s = section('Refinement history'); const ol = node('ol');
      refinements.forEach(refinement => { const li = node('li', '', typeof refinement === 'string' ? refinement : refinement.text || refinement.instruction || ''); if (refinement.at || refinement.createdAt) li.append(node('span', 'annotation-date', date(refinement.at || refinement.createdAt))); ol.append(li); }); s.append(ol);
    }
    const steps = asArray(run.steps || run.toolSteps);
    const activity = section('Recorded tool activity');
    activity.append(node('p', 'annotation-hint', steps.length ? 'Only recorded activity is shown.' : 'No tool activity was recorded for this run.'));
    steps.forEach((step, index) => {
      const details = node('details', 'annotation-tool');
      details.dataset.stepId = text(step.id || index);
      const summary = node('summary'); summary.append(node('span', 'annotation-tool-title', step.title || step.kind || 'Tool step'));
      if (step.status) summary.append(node('span', 'annotation-badge', text(step.status)));
      details.append(summary);
      if (step.kind) details.append(node('p', 'annotation-hint', 'Tool: ' + text(step.kind)));
      if (trim(step.detail)) details.append(node('pre', '', text(step.detail)));
      activity.append(details);
    });
    const files = asArray(run.files || run.changedFiles);
    if (files.length) { const s = section('Changed project files'); const ul = node('ul', 'annotation-files'); files.forEach(file => ul.append(node('li', '', typeof file === 'string' ? file : file.path || file.name || ''))); s.append(ul); }
    const actions = node('div', 'annotation-actions');
    const reveal = button('Show in instructions', () => window.editorShowAnnotationIntent(run.id));
    if (run.canRevealInstruction === false) {
      reveal.disabled = true;
      reveal.title = 'The source instruction is not in this document’s instruction log.';
      paragraph('The original instruction log is not available in this document.', 'annotation-hint');
    }
    actions.append(reveal);
    if (run.parentRunId && runById(run.parentRunId)) actions.append(button('Previous attribution', () => showRun(run.parentRunId)));
    content.append(actions);
  }
  function commentActions(comment) {
    const actions = node('div', 'annotation-actions');
    actions.append(button(comment.resolved ? 'Reopen' : 'Resolve', () => {
      engine().resolveComment(comment.id, !comment.resolved); syncState(); renderCard(); announce(comment.resolved ? 'Comment reopened.' : 'Comment resolved.');
    }));
    actions.append(button('Edit', () => editMessage(comment)));
    actions.append(button('Delete', () => { engine().deleteComment(comment.id); syncState(); view = { kind: 'list' }; renderCard(); announce('Comment deleted.'); }));
    if (doc.classList.contains('ro')) actions.querySelectorAll('button').forEach(el => { el.disabled = true; });
    return actions;
  }
  function renderComment(comment) {
    if (!comment) { paragraph('This comment has been deleted.'); return; }
    const meta = node('div', 'annotation-meta');
    const readOnly = doc.classList.contains('ro');
    meta.append(node('span', 'annotation-badge', comment.resolved ? 'Resolved' : 'Open'));
    if (comment.detached) meta.append(node('span', 'annotation-badge', 'Detached'));
    if (comment.createdAt) meta.append(node('time', '', date(comment.createdAt))); content.append(meta);
    if (readOnly) paragraph('History preview · comments are read only.', 'annotation-hint');
    quote(comment.quote || (comment.anchor && (comment.anchor.quote || comment.anchor.text)));
    if (comment.detached) paragraph('The passage was removed or could not be located. Select a passage, then reattach this thread.', 'annotation-hint');
    const body = node('div', 'annotation-message'); body.append(node('strong', '', 'You'), node('p', 'annotation-preserve', comment.body || '')); content.append(body, commentActions(comment));
    for (const reply of asArray(comment.replies)) {
      const message = node('div', 'annotation-message annotation-reply');
      const head = node('div', 'annotation-meta'); head.append(node('strong', '', 'You'));
      if (reply.createdAt) head.append(node('time', '', date(reply.createdAt)));
      if (reply.editedAt) head.append(node('span', '', 'Edited'));
      message.append(head, node('p', 'annotation-preserve', reply.body || ''));
      const actions = node('div', 'annotation-actions');
      actions.append(button('Edit reply', () => editMessage(comment, reply)), button('Delete reply', () => { engine().deleteReply(comment.id, reply.id); syncState(); renderCard(); announce('Reply deleted.'); }));
      if (readOnly) actions.querySelectorAll('button').forEach(el => { el.disabled = true; });
      message.append(actions); content.append(message);
    }
    const actions = node('div', 'annotation-actions annotation-thread-actions');
    actions.append(button('Ask agent about this', () => { close(false); window.editorAskAboutAnnotation(comment.id); }));
    const selected = getSelection() || selection;
    const reattach = button('Reattach to selection', () => {
      const target = getSelection() || selection;
      if (!target || target.end <= target.start) { announce('Select a passage in the document, then reattach this thread.'); return; }
      engine().reattachComment(comment.id, target); syncState(); renderCard(); schedulePaint(); announce('Comment reattached to the selected passage.');
    });
    reattach.disabled = readOnly || !selected || selected.end <= selected.start;
    reattach.title = readOnly ? 'History preview is read only' : reattach.disabled ? 'Select a passage in the document first' : 'Move this thread to the selected passage';
    actions.append(reattach); content.append(actions);
    if (readOnly) actions.querySelectorAll('button').forEach(el => { el.disabled = true; });
    else formEditor({ label: 'Reply', placeholder: 'Write a reply…', rows: 2, save: 'Add reply', cancel: () => close(), submit: body => { engine().replyComment(comment.id, body); syncState(); renderCard(); announce('Reply added.'); } });
  }
  function editMessage(comment, reply) {
    content.replaceChildren(); title.textContent = reply ? 'Edit reply' : 'Edit comment';
    formEditor({ label: reply ? 'Reply' : 'Comment', value: reply ? reply.body : comment.body, save: 'Save changes', cancel: () => { renderCard(); }, submit: body => {
      if (reply) engine().editReply(comment.id, reply.id, body); else engine().updateComment(comment.id, body);
      syncState(); renderCard(); announce('Changes saved.');
    } }).focus();
  }
  function itemRow(kind, item) {
    const el = button('', () => kind === 'run' ? showRun(item.id) : showComment(item.id), 'annotation-list-item');
    el.append(node('span', 'annotation-list-label', kind === 'run' ? spansFor(item.id).some(span => span.origin === 'uncertain') ? 'AI? · Agent revised; exact span uncertain' : 'AI · Agent contribution' : 'C · ' + (item.resolved ? 'Resolved comment' : 'Comment') + (item.detached ? ' · Detached' : '')));
    el.append(node('span', '', shorten(kind === 'run' ? item.instruction || item.text || item.summary || 'Agent contribution' : item.body)));
    const detail = [kind === 'run' ? item.provider : '', date(item.createdAt)].filter(Boolean).join(' · ');
    if (detail) el.append(node('span', 'annotation-list-detail', detail));
    return el;
  }
  function renderGroup(items) {
    paragraph('Several annotations start near this passage.', 'annotation-hint');
    const list = node('div', 'annotation-items');
    items.forEach(item => { const value = item.kind === 'run' ? runById(item.id) : commentById(item.id); if (value) list.append(itemRow(item.kind, value)); }); content.append(list);
    content.append(button('Browse all annotations', () => { view = { kind: 'list' }; renderCard(); }));
  }
  function renderList() {
    const filters = node('div', 'annotation-filters');
    const filter = node('select'); filter.id = 'annotation-filter'; filter.setAttribute('aria-label', 'Filter annotations');
    [['all', 'All annotations'], ['open', 'Open comments'], ['resolved', 'Resolved comments'], ['detached', 'Detached comments'], ['agent', 'Agent contributions']].forEach(([value, label]) => { const option = node('option', '', label); option.value = value; filter.append(option); }); filter.value = listFilter;
    const search = node('input'); search.type = 'search'; search.id = 'annotation-search'; search.placeholder = 'Search annotations'; search.setAttribute('aria-label', 'Search annotations'); search.value = listQuery;
    filters.append(filter, search); content.append(filters);
    const list = node('div', 'annotation-items'); list.id = 'annotation-items'; content.append(list);
    const draw = () => {
      list.replaceChildren(); const query = listQuery.toLocaleLowerCase();
      const items = [];
      if (listFilter === 'all' || listFilter === 'agent') {
        const usedRuns = new Set(attributedSpans().map(span => text(span.runId)));
        asArray(state.runs).filter(run => usedRuns.has(text(run.id))).forEach(value => items.push({ kind: 'run', value }));
      }
      if (listFilter !== 'agent') asArray(state.comments).filter(comment => listFilter === 'all' || listFilter === 'open' && !comment.resolved && !comment.detached || listFilter === 'resolved' && comment.resolved || listFilter === 'detached' && comment.detached).forEach(value => items.push({ kind: 'comment', value }));
      const filtered = items.filter(item => !query || JSON.stringify([item.value.body, item.value.instruction, item.value.summary, item.value.provider, item.value.notes, item.value.replies]).toLocaleLowerCase().includes(query));
      filtered.sort((a, b) => text(b.value.createdAt).localeCompare(text(a.value.createdAt)));
      if (!filtered.length) list.append(node('p', 'annotation-empty', query ? 'No matching annotations.' : listFilter === 'all' ? 'No attribution or comments yet. Select text to add a comment.' : 'No annotations in this filter.'));
      filtered.forEach(item => list.append(itemRow(item.kind, item.value)));
    };
    filter.addEventListener('change', () => { listFilter = filter.value; draw(); });
    search.addEventListener('input', () => { listQuery = search.value; draw(); }); draw();
  }
  function dismissContext() { if (contextMenu) contextMenu.remove(); contextMenu = null; }
  doc.addEventListener('contextmenu', event => {
    const liveSelection = window.getSelection();
    if (!liveSelection || !liveSelection.rangeCount || liveSelection.isCollapsed || !doc.contains(liveSelection.getRangeAt(0).commonAncestorContainer)) return;
    const target = getSelection();
    if (!target || doc.classList.contains('ro')) return;
    const savedRange = liveSelection.getRangeAt(0).cloneRange();
    const restoreSelection = () => { doc.focus(); const live = window.getSelection(); live.removeAllRanges(); live.addRange(savedRange); };
    event.preventDefault(); dismissContext();
    contextMenu = node('div', 'annotation-context'); contextMenu.setAttribute('role', 'menu');
    const comment = button('Comment on selection', () => { dismissContext(); compose(); }); comment.setAttribute('role', 'menuitem');
    const ask = button('Ask agent about selection', () => { dismissContext(); restoreSelection(); window.editorAskAboutSelection(); }); ask.setAttribute('role', 'menuitem');
    const copy = button('Copy', () => { dismissContext(); restoreSelection(); document.execCommand('copy'); }); copy.setAttribute('role', 'menuitem');
    const cut = button('Cut', () => { dismissContext(); restoreSelection(); document.execCommand('cut'); }); cut.setAttribute('role', 'menuitem');
    const separator = node('div', 'annotation-menu-separator'); separator.setAttribute('role', 'separator');
    const menuItems = [comment, ask, copy, cut];
    contextMenu.append(comment, ask, separator, copy, cut); document.body.append(contextMenu);
    contextMenu.style.left = Math.max(8, Math.min(event.clientX, window.innerWidth - contextMenu.offsetWidth - 8)) + 'px';
    contextMenu.style.top = Math.max(8, Math.min(event.clientY, window.innerHeight - contextMenu.offsetHeight - 8)) + 'px';
    contextMenu.addEventListener('mousedown', e => e.preventDefault());
    contextMenu.addEventListener('keydown', e => {
      e.stopPropagation();
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); const index = menuItems.indexOf(document.activeElement); menuItems[(index + (e.key === 'ArrowDown' ? 1 : menuItems.length - 1)) % menuItems.length].focus(); }
      else if (e.key === 'Home' || e.key === 'End') { e.preventDefault(); menuItems[e.key === 'Home' ? 0 : menuItems.length - 1].focus(); }
    });
    comment.focus({ preventScroll: true });
  });
  document.addEventListener('pointerdown', event => { if (contextMenu && !contextMenu.contains(event.target)) dismissContext(); }, true);
  doc.addEventListener('click', event => {
    if (!enabled || event.metaKey || event.ctrlKey || event.altKey || (getSelection() && window.getSelection() && !window.getSelection().isCollapsed)) return;
    const hits = rectangles.filter(item => event.clientX >= item.rect.left && event.clientX <= item.rect.right && event.clientY >= item.rect.top && event.clientY <= item.rect.bottom);
    const unique = []; hits.forEach(hit => { if (!unique.some(item => item.key === hit.key)) unique.push(hit); });
    if (unique.length) showGroup(unique, doc);
  });
  toggle.checked = false;
  toggle.addEventListener('change', () => setEnabled(toggle.checked));
  browse.addEventListener('click', () => open({ kind: 'list' }, browse));
  $('annotation-close').addEventListener('click', () => close());
  card.addEventListener('keydown', event => event.stopPropagation());
  $('commentchip').addEventListener('mousedown', event => { event.preventDefault(); event.stopPropagation(); });
  $('commentchip').addEventListener('click', () => compose());
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && (contextMenu || !card.hidden)) {
      event.preventDefault(); event.stopImmediatePropagation();
      if (contextMenu) { dismissContext(); doc.focus({ preventScroll: true }); }
      else close();
    }
  }, true);
  document.addEventListener('selectionchange', () => {
    const live = window.getSelection();
    if (doc.contains(document.activeElement) && (!live || live.isCollapsed)) selection = null;
    const selected = getSelection();
    // Refresh reattach availability without replacing an in-progress reply.
    if (view && view.kind === 'comment' && !doc.classList.contains('ro')) {
      const reattach = Array.from(content.querySelectorAll('button')).find(el => el.textContent === 'Reattach to selection'); if (reattach) reattach.disabled = !selected;
    }
  });
  document.addEventListener('margins-annotations-changed', event => {
    const changed = event.detail && event.detail.state && (event.detail.state.revision !== state.revision || event.detail.text !== state.text || event.detail.selection === null);
    const runChanged = view && view.kind === 'run' && event.detail && event.detail.state && JSON.stringify(runById(view.id)) !== JSON.stringify(asArray(event.detail.state.runs).find(run => text(run.id) === text(view.id)));
    if (event.detail && (event.detail.selection === null || event.detail.text !== state.text)) selection = null;
    if (event.detail && event.detail.state) state = event.detail.state;
    if (changed) schedulePaint();
    if (view && view.kind === 'comment' && !commentById(view.id)) close(false);
    const typing = document.activeElement && content.contains(document.activeElement) && document.activeElement.matches('input,textarea');
    if (view && view.kind === 'comment' && changed && !typing) renderCard();
    else if (view && view.kind === 'list' && changed && !typing) renderCard();
    else if (runChanged) renderCard();
  });
  scroll.addEventListener('scroll', schedulePaint, { passive: true });
  window.addEventListener('resize', () => { schedulePaint(); if (!card.hidden) place(); });
  if (window.ResizeObserver) { const observer = new ResizeObserver(schedulePaint); observer.observe(doc); observer.observe($('formatbar')); }
  doc.addEventListener('load', schedulePaint, true);
  new MutationObserver(() => {
    const readOnly = doc.classList.contains('ro');
    if (readOnly !== wasReadOnly) { wasReadOnly = readOnly; if (view) renderCard(); }
    schedulePaint();
  }).observe(doc, { childList: true, subtree: true, characterData: true, attributes: true });
  window.MarginsAnnotationUI = { compose, commentSelection: compose, setEnabled, refresh: schedulePaint, close, showRun, showComment, showList: () => open({ kind: 'list' }, browse), isEnabled: () => enabled };
  setEnabled(false); syncState(); schedulePaint();
})();
