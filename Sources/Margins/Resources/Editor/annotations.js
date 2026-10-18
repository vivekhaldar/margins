// Text attribution and author comments. Metadata never enters the editable DOM.
// Offsets are UTF-16 code units in textContent, excluding editor controls. A top-level
// block is one coordinate space (including lists/tables); pending original/proposal
// are separate spaces. Public UI offsets join the active blocks with one newline.
(() => {
  'use strict';
  const clone = value => JSON.parse(JSON.stringify(value));
  const uid = () => globalThis.crypto?.randomUUID?.() || 'a-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
  const now = () => new Date().toISOString();
  const key = value => value.blockId + ':' + (value.side || 'live');
  const endpoint = (record, offset) => Object.assign({blockId: record.blockId, offset}, record.side ? {side: record.side} : {});
  const origins = new Set(['author', 'agent', 'unattributed', 'pasted', 'uncertain']);
  const sameOrigin = (a, b) => a.origin === b.origin && a.runId === b.runId && a.parentRunId === b.parentRunId;

  // Bounded Myers alignment. Prefix/suffix make ordinary typing constant in the
  // unchanged text. If the edit budget is exhausted, unique word anchors retain
  // confidently unchanged regions; unmatched text is explicitly uncertain.
  function align(a, b) {
    const result = [];
    let complete = true;
    const add = (x, y, length) => {
      if (!length) return;
      const last = result[result.length - 1];
      if (last && last.a + last.length === x && last.b + last.length === y) last.length += length;
      else result.push({a: x, b: y, length});
    };
    function segment(x0, x1, y0, y1, depth = 0) {
      let prefix = 0;
      while (x0 + prefix < x1 && y0 + prefix < y1 && a[x0 + prefix] === b[y0 + prefix]) prefix++;
      add(x0, y0, prefix); x0 += prefix; y0 += prefix;
      let suffix = 0;
      while (x1 - suffix > x0 && y1 - suffix > y0 && a[x1 - suffix - 1] === b[y1 - suffix - 1]) suffix++;
      const ax = x1 - suffix, by = y1 - suffix, n = ax - x0, m = by - y0;
      if (n && m) {
        const limit = Math.min(n + m, 384), trace = [], started = Date.now();
        let v = new Map([[1, 0]]), found = false;
        for (let d = 0; d <= limit && Date.now() - started < 35; d++) {
          trace.push(new Map(v));
          for (let k = -d; k <= d; k += 2) {
            let x = (k === -d || (k !== d && (v.get(k - 1) ?? -1) < (v.get(k + 1) ?? -1)))
              ? (v.get(k + 1) ?? 0) : (v.get(k - 1) ?? 0) + 1;
            let y = x - k;
            while (x < n && y < m && a[x0 + x] === b[y0 + y]) { x++; y++; }
            v.set(k, x);
            if (x < n || y < m) continue;
            const pairs = [];
            let px = n, py = m;
            for (let distance = d; distance >= 0; distance--) {
              const prior = trace[distance], diagonal = px - py;
              const pk = (diagonal === -distance || (diagonal !== distance && (prior.get(diagonal - 1) ?? -1) < (prior.get(diagonal + 1) ?? -1))) ? diagonal + 1 : diagonal - 1;
              const previousX = prior.get(pk) ?? 0, previousY = previousX - pk;
              while (px > previousX && py > previousY) { pairs.push([x0 + --px, y0 + --py]); }
              px = previousX; py = previousY;
            }
            pairs.reverse().forEach(pair => add(pair[0], pair[1], 1));
            found = true; break;
          }
          if (found) break;
        }
        if (!found) {
          // A patience-style fallback handles long documents with many separate
          // edits without an unbounded quadratic diff or invented attribution.
          const tokens = (s, lo, hi) => {
            const out = new Map(), pattern = /[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/gu;
            pattern.lastIndex = lo;
            for (let match; (match = pattern.exec(s)) && match.index < hi;) {
              if (match.index + match[0].length > hi) break;
              const prior = out.get(match[0]);
              out.set(match[0], prior === undefined ? {offset: match.index, length: match[0].length} : null);
            }
            return out;
          };
          const left = tokens(a, x0, ax), right = tokens(b, y0, by);
          const candidates = [...left].filter(([word, value]) => value && right.get(word))
            .map(([word, value]) => ({a: value.offset, b: right.get(word).offset, length: value.length})).sort((p, q) => p.a - q.a);
          const tails = [], indexes = [], previous = [];
          candidates.forEach((value, index) => {
            let lo = 0, hi = tails.length;
            while (lo < hi) { const mid = (lo + hi) >> 1; if (tails[mid] < value.b) lo = mid + 1; else hi = mid; }
            previous[index] = lo ? indexes[lo - 1] : -1;
            tails[lo] = value.b; indexes[lo] = index;
          });
          const anchors = [];
          for (let i = indexes[tails.length - 1]; i !== undefined && i >= 0; i = previous[i]) anchors.push(candidates[i]);
          anchors.reverse();
          if (anchors.length && depth < 5) {
            let x = x0, y = y0;
            for (const anchor of anchors) { segment(x, anchor.a, y, anchor.b, depth + 1); add(anchor.a, anchor.b, anchor.length); x = anchor.a + anchor.length; y = anchor.b + anchor.length; }
            segment(x, ax, y, by, depth + 1);
          } else complete = false;
        }
      }
      add(x1 - suffix, y1 - suffix, suffix);
    }
    segment(0, a.length, 0, b.length);
    const high = code => code >= 0xD800 && code <= 0xDBFF, low = code => code >= 0xDC00 && code <= 0xDFFF;
    const safe = result.flatMap(match => {
      let {a: x, b: y, length} = match;
      if ((low(a.charCodeAt(x)) && high(a.charCodeAt(x - 1))) || (low(b.charCodeAt(y)) && high(b.charCodeAt(y - 1)))) { x++; y++; length--; }
      if ((high(a.charCodeAt(x + length - 1)) && low(a.charCodeAt(x + length))) || (high(b.charCodeAt(y + length - 1)) && low(b.charCodeAt(y + length)))) length--;
      return length > 0 ? [{a: x, b: y, length}] : [];
    });
    return {matches: safe, complete};
  }

  function flatten(records) {
    let text = '';
    const list = records.map((record, index) => {
      if (index) text += '\n';
      const value = Object.assign({}, record, {globalStart: text.length});
      text += record.text;
      return value;
    });
    return {text, records: list};
  }
  const active = records => records.filter(record => record.side !== 'original');
  function project(spans, matches) {
    const out = [];
    for (const match of matches) for (const span of spans) {
      if (span.end <= match.a) continue;
      if (span.start >= match.a + match.length) break;
      const start = Math.max(span.start, match.a), end = Math.min(span.end, match.a + match.length);
      if (end > start) out.push(Object.assign({}, span, {start: match.b + start - match.a, end: match.b + end - match.a}));
    }
    return out.sort((a, b) => a.start - b.start || a.end - b.end);
  }
  function mapRange(start, end, matches) {
    const pieces = matches.filter(match => match.a < end && match.a + match.length > start);
    const count = pieces.reduce((sum, match) => sum + Math.min(end, match.a + match.length) - Math.max(start, match.a), 0);
    if (!pieces.length || count < Math.min(end - start, Math.max(2, (end - start) * 0.5))) return null;
    const first = pieces[0], last = pieces[pieces.length - 1];
    return {start: first.b + Math.max(0, start - first.a), end: last.b + Math.min(last.length, end - last.a)};
  }

  class AnnotationEngine {
    constructor(doc, options = {}) {
      this.doc = doc; this.options = options;
      this.state = {schema: 1, revision: 0, spans: [], comments: [], runs: [], texts: []};
      this.records = []; this.cachedSelection = null; this.resolutions = new Map();
      this.history = []; this.future = []; this.maxHistory = 80;
      this.load(null);
      document.addEventListener('selectionchange', () => {
        const selection = this.selectionFromDOM();
        if (selection) this.cachedSelection = selection;
        this.notify(false);
      });
    }
    views() {
      const out = [];
      for (const block of this.doc.children) {
        if (!block.dataset.bid) continue;
        const add = (el, side) => {
          if (!el) return;
          const nodes = [], walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          let text = '';
          for (let node; (node = walker.nextNode());) {
            if (node.parentElement?.closest('.tools,.rb,script,style')) continue;
            nodes.push({node, start: text.length}); text += node.nodeValue;
          }
          out.push({blockId: block.dataset.bid, ...(side ? {side} : {}), text, el, nodes});
        };
        if (block.classList.contains('chg')) { add(block.querySelector(':scope > del'), 'original'); add(block.querySelector(':scope > ins'), 'proposal'); }
        else add(block);
      }
      return out;
    }
    textRecords() { return this.records.map(({blockId, side, text}) => ({blockId, ...(side ? {side} : {}), text})); }
    allSpans(records) {
      return records.flatMap(record => this.state.spans.filter(span => key(span) === key(record)).map(span => Object.assign({}, span, {start: record.globalStart + span.start, end: record.globalStart + span.end})));
    }
    fill(record, projected, origin, runId, parentRunId) {
      const out = [], append = (start, end, attrs) => {
        if (end <= start) return;
        const span = Object.assign({id: uid(), blockId: record.blockId, ...(record.side ? {side: record.side} : {}), start, end}, attrs);
        delete span.globalStart; delete span.text; delete span.el; delete span.nodes;
        const last = out[out.length - 1];
        if (last && last.end === start && sameOrigin(last, span)) last.end = end;
        else out.push(span);
      };
      let position = 0;
      for (const span of projected.sort((a, b) => a.start - b.start)) {
        const start = Math.max(position, Math.min(record.text.length, span.start)), end = Math.min(record.text.length, span.end);
        append(position, start, {origin, ...(runId ? {runId} : {}), ...(parentRunId ? {parentRunId} : {})});
        const attrs = {origin: origins.has(span.origin) ? span.origin : 'uncertain', ...(span.runId ? {runId: span.runId} : {}), ...(span.parentRunId ? {parentRunId: span.parentRunId} : {})};
        append(start, end, attrs); position = Math.max(position, end);
      }
      append(position, record.text.length, {origin, ...(runId ? {runId} : {}), ...(parentRunId ? {parentRunId} : {})});
      return out;
    }
    load(value) {
      const records = this.views(), incoming = value && typeof value === 'object' ? clone(value) : {};
      this.state = {schema: 1, revision: Number.isSafeInteger(incoming.revision) ? incoming.revision : 0,
        spans: Array.isArray(incoming.spans) ? incoming.spans : [], comments: Array.isArray(incoming.comments) ? incoming.comments : [], runs: Array.isArray(incoming.runs) ? incoming.runs : [], texts: []};
      const oldTexts = Array.isArray(incoming.texts) ? incoming.texts : [];
      const spans = [];
      for (const record of records) {
        const oldText = oldTexts.find(value => key(value) === key(record));
        const saved = this.state.spans.filter(span => key(span) === key(record) && Number.isFinite(span.start) && Number.isFinite(span.end));
        const aligned = oldText && oldText.text !== record.text ? project(saved, align(oldText.text, record.text).matches) : saved;
        spans.push(...this.fill(record, aligned, oldText && oldText.text !== record.text ? 'uncertain' : 'unattributed'));
      }
      this.state.spans = spans; this.records = records;
      for (const comment of this.state.comments) {
        if (!comment.id) comment.id = uid();
        comment.messages = Array.isArray(comment.messages) ? comment.messages : [{id: uid(), text: comment.body || '', createdAt: comment.createdAt || now()}];
        if (!comment.anchor?.detached && !this.anchorValid(comment.anchor)) this.recover(comment);
      }
      this.state.texts = this.textRecords(); this.history = []; this.future = []; this.cachedSelection = null; this.resolutions.clear();
      this.remember(); this.notify(false);
    }
    snapshot() { return clone(Object.assign({}, this.state, {texts: this.textRecords()})); }
    fingerprint() { return this.records.map(record => key(record) + '\u0000' + record.text).join('\u0001'); }
    revisionHTML() { return this.options.getRevisionHTML?.() ?? this.doc.innerHTML; }
    remember() {
      this.htmlSignature = this.revisionHTML();
      this.history.push({signature: this.fingerprint(), html: this.doc.innerHTML, state: this.snapshot()});
      if (this.history.length > this.maxHistory) this.history.shift();
      const size = entry => entry.html.length + entry.signature.length * 2 + entry.state.spans.length * 160 + entry.state.comments.length * 600 + entry.state.runs.length * 1200;
      let units = this.history.reduce((total, entry) => total + size(entry), 0);
      while (this.history.length > 2 && units > 12 * 1024 * 1024) {
        units -= size(this.history.shift());
      }
    }
    restoreHistory(direction) {
      const signature = this.views().map(record => key(record) + '\u0000' + record.text).join('\u0001');
      const stack = direction === 'redo' ? this.future : this.history;
      let index = -1;
      // The DOM has already performed its native undo. Find the matching text
      // snapshot instead of guessing which input events WebKit coalesced.
      for (let i = stack.length - 1; i >= 0; i--) if (stack[i].signature === signature && (direction === 'redo' || i < stack.length - 1)) { index = i; break; }
      if (index < 0) return false;
      const priorRevision = this.state.revision;
      const entry = stack[index];
      if (direction === 'undo') this.future.push(...this.history.splice(index + 1).reverse());
      else { this.future.splice(index, 1); this.history.push(entry); }
      this.state = clone(entry.state); this.state.revision = priorRevision + 1; this.records = this.views(); this.htmlSignature = this.revisionHTML();
      this.notify(true); return true;
    }
    resolveChange(blockId, accepted) {
      const side = accepted ? 'proposal' : 'original';
      this.resolutions.set(blockId, side);
      const remaining = this.records.find(record => record.blockId === blockId && record.side === side);
      if (remaining && !remaining.text) this.detachBlock(blockId);
    }
    detachBlock(blockId) {
      for (const comment of this.state.comments) if (!comment.anchor?.detached && comment.anchor.start?.blockId === blockId && comment.anchor.end?.blockId === blockId) comment.anchor.detached = true;
    }
    sync(options = {}) {
      const next = this.views();
      if (options.history && this.restoreHistory(options.history)) return true;
      if (this.records.length === next.length && this.records.every((record, index) => key(record) === key(next[index]) && record.text === next[index].text)) {
        this.records = next; this.resolutions.clear();
        // Formatting, links, checkboxes and images can change without changing
        // text coordinates. They still invalidate an in-flight agent response.
        if (this.htmlSignature !== this.revisionHTML()) {
          this.state.revision++; this.future = []; this.remember(); this.notify(options.silent !== true); return true;
        }
        return false;
      }
      const previous = this.records, before = this.snapshot(), sourceRecords = [];
      for (const record of active(previous)) {
        const side = this.resolutions.get(record.blockId);
        sourceRecords.push(side ? previous.find(value => value.blockId === record.blockId && value.side === side) || record : record);
      }
      const from = flatten(sourceRecords), to = flatten(active(next));
      const comparison = align(from.text, to.text);
      const sourceSpans = this.allSpans(from.records);
      const projected = project(sourceSpans, comparison.matches);
      // Native undo can outlive the bounded metadata history. Restored text
      // without a retained origin is uncertain, rather than new author typing.
      const insertion = options.history ? 'uncertain' : options.origin || 'author', spans = [];
      for (const record of next) {
        if (record.side === 'original') {
          const source = previous.find(value => key(value) === key(record)) || previous.find(value => value.blockId === record.blockId && !value.side);
          const saved = source ? before.spans.filter(span => key(span) === key(source)) : [];
          const aligned = source ? project(saved, align(source.text, record.text).matches) : [];
          spans.push(...this.fill(record, aligned, 'unattributed')); continue;
        }
        const global = to.records.find(value => key(value) === key(record));
        let matched = projected.filter(span => span.start < global.globalStart + record.text.length && span.end > global.globalStart)
          .map(span => Object.assign({}, span, {start: Math.max(0, span.start - global.globalStart), end: Math.min(record.text.length, span.end - global.globalStart)}));
        // Exact block moves are independent of order in the global alignment.
        const stable = previous.find(value => key(value) === key(record) && value.text === record.text);
        const exact = previous.filter(value => value.text === record.text && value.side !== 'original');
        if (record.text && stable) matched = before.spans.filter(span => key(span) === key(stable));
        else if (record.text && exact.length === 1 && !this.resolutions.has(record.blockId)) matched = before.spans.filter(span => key(span) === key(exact[0]));
        spans.push(...this.fill(record, matched, comparison.complete ? insertion : 'uncertain', options.runId, options.parentRunId));
      }
      this.records = next; this.state.spans = spans;
      this.cachedSelection = null;
      for (const comment of this.state.comments) {
        if (comment.anchor?.detached) continue;
        const oldAnchor = clone(comment.anchor);
        // A tracked proposal must not consume comments on the original. Keep
        // the saved original surface, including intermediate blocks in a range.
        const oldCoordinates = this.anchorRecords(oldAnchor, previous);
        const firstIndex = oldCoordinates.findIndex(value => key(value) === key(oldAnchor.start || {}));
        const lastIndex = oldCoordinates.findIndex(value => key(value) === key(oldAnchor.end || {}));
        const sides = Object.assign({}, oldAnchor.surfaceSides || {});
        if (firstIndex >= 0 && lastIndex >= firstIndex) for (const prior of oldCoordinates.slice(firstIndex, lastIndex + 1)) {
          const original = !prior.side && next.find(value => value.blockId === prior.blockId && value.side === 'original');
          if (!original) continue;
          sides[prior.blockId] = 'original';
          if (oldAnchor.start.blockId === prior.blockId) comment.anchor.start.side = 'original';
          if (oldAnchor.end.blockId === prior.blockId) comment.anchor.end.side = 'original';
        }
        if (Object.keys(sides).length) comment.anchor.surfaceSides = sides;
        if (this.anchorText(comment.anchor) === oldAnchor.quote && this.anchorValid(comment.anchor)) continue;
        const startRecord = previous.find(value => key(value) === key(oldAnchor.start || {}));
        const endRecord = previous.find(value => key(value) === key(oldAnchor.end || {}));
        if (!startRecord || !endRecord) { this.recover(comment); continue; }
        const sameStart = next.find(value => key(value) === key(startRecord));
        const sameEnd = next.find(value => key(value) === key(endRecord));
        if (sameStart && sameEnd && startRecord.text === sameStart.text && endRecord.text === sameEnd.text && this.anchorText(comment.anchor) === oldAnchor.quote) continue;
        // Prefer the anchor's original/proposed coordinate spaces while they
        // exist. Resolving a change maps that saved side into the live document.
        const anchorSources = this.anchorRecords(oldAnchor, previous);
        const old = flatten(anchorSources), target = flatten(active(next));
        if (sameStart && sameEnd && (startRecord.side === 'original' || endRecord.side === 'original')) {
          const a = mapRange(oldAnchor.start.offset, oldAnchor.end.offset, align(startRecord.text, sameStart.text).matches);
          if (startRecord === endRecord && a) { comment.anchor.start = endpoint(sameStart, a.start); comment.anchor.end = endpoint(sameEnd, a.end); this.refreshQuote(comment); continue; }
        }
        const a = old.records.find(value => key(value) === key(startRecord)), b = old.records.find(value => key(value) === key(endRecord));
        const mapped = a && b ? mapRange(a.globalStart + oldAnchor.start.offset, b.globalStart + oldAnchor.end.offset, align(old.text, target.text).matches) : null;
        if (mapped && mapped.end > mapped.start) { comment.anchor = this.anchorFromGlobal(mapped.start, mapped.end); continue; }
        this.recover(comment);
      }
      this.state.revision++; this.state.texts = this.textRecords(); this.resolutions.clear(); this.future = [];
      this.remember(); this.notify(options.silent !== true); return true;
    }
    anchorValid(anchor) {
      if (!anchor || anchor.detached || !anchor.start || !anchor.end) return false;
      const a = this.records.find(record => key(record) === key(anchor.start)), b = this.records.find(record => key(record) === key(anchor.end));
      if (!a || !b || anchor.start.offset < 0 || anchor.start.offset > a.text.length || anchor.end.offset < 0 || anchor.end.offset > b.text.length) return false;
      const text = this.anchorText(anchor);
      return !!text && (!anchor.quote || text === anchor.quote);
    }
    anchorText(anchor) {
      if (!anchor?.start || !anchor?.end) return '';
      const selected = this.anchorRecords(anchor, this.records);
      const flat = flatten(selected), a = flat.records.find(record => key(record) === key(anchor.start)), b = flat.records.find(record => key(record) === key(anchor.end));
      return a && b ? flat.text.slice(a.globalStart + anchor.start.offset, b.globalStart + anchor.end.offset) : '';
    }
    anchorRecords(anchor, records = this.records) {
      return active(records).map(record => {
        const side = record.blockId === anchor.start?.blockId ? anchor.start.side : record.blockId === anchor.end?.blockId ? anchor.end.side : anchor.surfaceSides?.[record.blockId];
        return side ? records.find(value => value.blockId === record.blockId && value.side === side) || record : record;
      });
    }
    refreshQuote(comment) {
      const text = this.anchorText(comment.anchor);
      if (text) comment.anchor.quote = text;
    }
    anchorFromGlobal(start, end) {
      const flat = flatten(active(this.records));
      const locate = (offset, ending) => {
        const candidates = flat.records.filter(record => offset >= record.globalStart && offset <= record.globalStart + record.text.length);
        const record = ending ? candidates[0] : candidates[candidates.length - 1];
        if (record) return endpoint(record, offset - record.globalStart);
        const near = flat.records.find(record => record.globalStart > offset) || flat.records[flat.records.length - 1];
        return near ? endpoint(near, Math.max(0, Math.min(near.text.length, offset - near.globalStart))) : null;
      };
      return {start: locate(start, false), end: locate(end, true), quote: flat.text.slice(start, end), prefix: flat.text.slice(Math.max(0, start - 48), start), suffix: flat.text.slice(end, end + 48), detached: false};
    }
    globalAnchor(anchor) {
      if (anchor?.detached) return null;
      const flat = flatten(active(this.records)), a = flat.records.find(record => key(record) === key(anchor?.start || {})), b = flat.records.find(record => key(record) === key(anchor?.end || {}));
      return a && b ? {start: a.globalStart + anchor.start.offset, end: b.globalStart + anchor.end.offset} : null;
    }
    recover(comment) {
      const anchor = comment.anchor || {}, quote = anchor.quote || '';
      const flat = flatten(active(this.records));
      const candidates = [];
      if (quote) for (let offset = 0; offset <= flat.text.length - quote.length;) {
        const index = flat.text.indexOf(quote, offset); if (index < 0) break;
        candidates.push(index); offset = index + Math.max(1, quote.length);
      }
      let matches = candidates;
      if (matches.length > 1 && (anchor.prefix || anchor.suffix)) matches = matches.filter(start =>
        (!anchor.prefix || flat.text.slice(Math.max(0, start - anchor.prefix.length), start) === anchor.prefix) &&
        (!anchor.suffix || flat.text.slice(start + quote.length, start + quote.length + anchor.suffix.length) === anchor.suffix));
      if (matches.length === 1) comment.anchor = this.anchorFromGlobal(matches[0], matches[0] + quote.length);
      else comment.anchor = Object.assign({}, anchor, {detached: true});
    }
    selectionFromDOM() {
      const selection = window.getSelection();
      if (!selection?.rangeCount || selection.isCollapsed || this.doc.classList.contains('ro')) return null;
      const range = selection.getRangeAt(0);
      if (!this.doc.contains(range.commonAncestorContainer)) return null;
      const toOffset = (node, offset) => {
        const record = this.records.find(value => value.side !== 'original' && (value.el === node || value.el.contains(node)));
        if (!record || node.parentElement?.closest('.tools,.rb')) return null;
        const r = document.createRange(); r.selectNodeContents(record.el);
        try { r.setEnd(node, offset); } catch (_) { return null; }
        const content = r.cloneContents(); content.querySelectorAll?.('.tools,.rb').forEach(value => value.remove());
        return {record, offset: content.textContent.length};
      };
      const a = toOffset(range.startContainer, range.startOffset), b = toOffset(range.endContainer, range.endOffset);
      if (!a || !b) return null;
      const flat = flatten(active(this.records));
      const start = flat.records.find(record => key(record) === key(a.record)).globalStart + a.offset;
      const end = flat.records.find(record => key(record) === key(b.record)).globalStart + b.offset;
      return end > start ? {start, end, text: flat.text.slice(start, end), anchor: this.anchorFromGlobal(start, end), revision: this.state.revision} : null;
    }
    getSelection() { const value = this.selectionFromDOM(); if (value) this.cachedSelection = value; return clone(value || this.cachedSelection); }
    getCaretOffset() {
      const selection = window.getSelection();
      if (!selection?.rangeCount || !this.doc.contains(selection.anchorNode)) return null;
      return this.offsetForDOM(selection.anchorNode, selection.anchorOffset);
    }
    offsetForDOM(node, offset) {
      const record = active(this.records).find(value => value.el === node || value.el.contains(node));
      if (!record) return null;
      const range = document.createRange(); range.selectNodeContents(record.el);
      try { range.setEnd(node, offset); } catch (_) { return null; }
      const fragment = range.cloneContents(); fragment.querySelectorAll?.('.tools,.rb').forEach(value => value.remove());
      const flat = flatten(active(this.records));
      return flat.records.find(value => key(value) === key(record)).globalStart + fragment.textContent.length;
    }
    rangesForAnchor(anchor) {
      if (!anchor || anchor.detached) return [];
      const records = this.anchorRecords(anchor);
      const start = records.findIndex(record => key(record) === key(anchor.start || {})), end = records.findIndex(record => key(record) === key(anchor.end || {}));
      if (start < 0 || end < start) return [];
      const out = [];
      for (let i = start; i <= end; i++) {
        const record = records[i], lo = i === start ? anchor.start.offset : 0, hi = i === end ? anchor.end.offset : record.text.length;
        if (hi <= lo) continue;
        const a = record.nodes.find(node => node.start + node.node.length > lo), b = record.nodes.find(node => node.start + node.node.length >= hi);
        if (!a || !b) continue;
        const range = document.createRange(); range.setStart(a.node, lo - a.start); range.setEnd(b.node, hi - b.start); out.push(range);
      }
      return out;
    }
    getRanges(start, end) { return this.rangesForAnchor(this.anchorFromGlobal(start, end)); }
    getRects(start, end) { return this.getRanges(start, end).flatMap(range => [...range.getClientRects()].map(rect => ({x: rect.x, y: rect.y, left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height}))); }
    getCommentRects(id) { const comment = this.state.comments.find(value => value.id === id); return this.rangesForAnchor(comment?.anchor).flatMap(range => [...range.getClientRects()].map(rect => ({x: rect.x, y: rect.y, left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height}))); }
    getState() {
      const flat = flatten(active(this.records));
      return {schema: 1, revision: this.state.revision, text: flat.text, runs: clone(this.state.runs), spans: clone(this.allSpans(flat.records)),
        comments: this.state.comments.map(comment => {
          const global = this.globalAnchor(comment.anchor), first = comment.messages?.[0];
          return Object.assign({}, clone(comment), global || {start: -1, end: -1}, {body: first?.text || '', detached: !!comment.anchor?.detached, replies: (comment.messages || []).slice(1).map(message => Object.assign({}, message, {body: message.text}))});
        })};
    }
    notify(persist) {
      if (persist) this.options.onChange?.(this.snapshot());
      document.dispatchEvent(new CustomEvent('margins-annotations-changed', {detail: {state: this.getState(), text: flatten(active(this.records)).text, selection: this.cachedSelection, pending: this.records.some(record => record.side === 'proposal')}}));
    }
    mutate(action) {
      if (this.doc.classList.contains('ro')) return null;
      this.sync({silent: true}); const value = action(); if (value === false) return null;
      this.state.revision++; this.future = []; this.remember(); this.notify(true); return value;
    }
    addComment(body, selection) {
      body = String(body || '').trim(); selection = selection || this.getSelection();
      if (!body || !selection || selection.end <= selection.start) return null;
      return this.mutate(() => {
        const stamp = now(), comment = {id: uid(), anchor: this.selectionAnchor(selection), messages: [{id: uid(), text: body, createdAt: stamp}], resolved: false, createdAt: stamp, updatedAt: stamp};
        if (!this.anchorValid(comment.anchor)) this.recover(comment);
        this.state.comments.push(comment); return comment.id;
      });
    }
    selectionAnchor(selection) {
      const anchor = clone(selection.anchor || this.anchorFromGlobal(selection.start, selection.end));
      for (const edge of [anchor.start, anchor.end]) if (edge && !edge.side && !this.records.some(record => key(record) === key(edge)) && this.records.some(record => record.blockId === edge.blockId && record.side === 'original')) {
        edge.side = 'original'; anchor.surfaceSides = Object.assign({}, anchor.surfaceSides, {[edge.blockId]: 'original'});
      }
      return anchor;
    }
    changeComment(id, action) { return this.mutate(() => { const comment = this.state.comments.find(value => value.id === id); if (!comment) return false; action(comment); comment.updatedAt = now(); return id; }); }
    updateComment(id, body) { if (!String(body || '').trim()) return null; return this.changeComment(id, comment => { if (comment.messages[0]) { comment.messages[0].text = String(body).trim(); comment.messages[0].editedAt = now(); } }); }
    deleteComment(id) { return this.mutate(() => { const index = this.state.comments.findIndex(value => value.id === id); if (index < 0) return false; this.state.comments.splice(index, 1); return id; }); }
    replyComment(id, body) { if (!String(body || '').trim()) return null; return this.changeComment(id, comment => comment.messages.push({id: uid(), text: String(body).trim(), createdAt: now()})); }
    editReply(id, messageId, body) { if (!String(body || '').trim()) return null; return this.changeComment(id, comment => { const message = comment.messages.find(value => value.id === messageId); if (message) { message.text = String(body).trim(); message.editedAt = now(); } }); }
    deleteReply(id, messageId) { return this.changeComment(id, comment => { comment.messages = comment.messages.filter((message, index) => index === 0 || message.id !== messageId); }); }
    resolveComment(id, resolved = true) { return this.changeComment(id, comment => { comment.resolved = !!resolved; }); }
    reattachComment(id, selection) { selection = selection || this.getSelection(); if (!selection || selection.end <= selection.start) return null; return this.changeComment(id, comment => { comment.anchor = this.selectionAnchor(selection); if (!this.anchorValid(comment.anchor)) this.recover(comment); }); }
    setRuns(runs) {
      const merged = new Map(this.state.runs.map(run => [String(run.id || run.runId).toLowerCase(), run]));
      for (const run of Array.isArray(runs) ? runs : []) merged.set(String(run.id || run.runId).toLowerCase(), clone(run));
      this.state.runs = [...merged.values()]; this.notify(false);
    }
    detachDeleted(start, end) {
      if (end <= start) return;
      for (const comment of this.state.comments) {
        const range = this.globalAnchor(comment.anchor);
        if (range && range.start >= start && range.end <= end) comment.anchor.detached = true;
      }
    }
    reconcileReplacement(start, end, affected) {
      const inserted = flatten(active(this.records)).text.slice(start, end);
      for (const prior of affected || []) {
        const comment = this.state.comments.find(value => value.id === prior.id);
        if (!comment) continue;
        const index = prior.quote ? inserted.indexOf(prior.quote) : -1;
        if (index >= 0 && inserted.indexOf(prior.quote, index + 1) < 0) comment.anchor = this.anchorFromGlobal(start + index, start + index + prior.quote.length);
        else comment.anchor.detached = true;
      }
    }
    markOrigin(start, end, origin, advanceRevision = false, parentRunId) {
      const flat = flatten(active(this.records));
      start = Math.max(0, start); end = Math.min(flat.text.length, end);
      if (end <= start) return;
      const retained = this.allSpans(flat.records).flatMap(span => {
        if (span.end <= start || span.start >= end) return [span];
        return [span.start < start ? Object.assign({}, span, {end: start}) : null, span.end > end ? Object.assign({}, span, {start: end}) : null].filter(Boolean);
      });
      retained.push({start, end, origin, ...(parentRunId ? {parentRunId} : {})});
      this.state.spans = this.records.flatMap(record => {
        if (record.side === 'original') return this.state.spans.filter(span => key(span) === key(record));
        const global = flat.records.find(value => key(value) === key(record));
        const projected = retained.filter(span => span.start < global.globalStart + record.text.length && span.end > global.globalStart).map(span => Object.assign({}, span, {start: Math.max(0, span.start - global.globalStart), end: Math.min(record.text.length, span.end - global.globalStart)}));
        return this.fill(record, projected, origin);
      });
      if (advanceRevision) { this.state.revision++; this.remember(); }
      else if (this.history.length) this.history[this.history.length - 1] = {signature: this.fingerprint(), html: this.doc.innerHTML, state: this.snapshot()};
      else this.remember();
      this.notify(false);
    }
    applyExactEdit(priorSpans, start, end, insertedLength, origin, parentRunId, advanceRevision = false) {
      const flat = flatten(active(this.records)), shift = insertedLength - (end - start), newEnd = start + insertedLength;
      const transported = priorSpans.flatMap(span => {
        const pieces = [];
        if (span.start < start) pieces.push(Object.assign({}, span, {end: Math.min(start, span.end)}));
        if (span.end > end) pieces.push(Object.assign({}, span, {start: Math.max(end, span.start) + shift, end: span.end + shift}));
        return pieces;
      });
      if (insertedLength > 0) transported.push({start, end: newEnd, origin, ...(parentRunId ? {parentRunId} : {})});
      this.state.spans = this.records.flatMap(record => {
        if (record.side === 'original') return this.state.spans.filter(span => key(span) === key(record));
        const global = flat.records.find(value => key(value) === key(record));
        const projected = transported.filter(span => span.start < global.globalStart + record.text.length && span.end > global.globalStart).map(span => Object.assign({}, span, {start: Math.max(0, span.start - global.globalStart), end: Math.min(record.text.length, span.end - global.globalStart)}));
        return this.fill(record, projected, 'uncertain');
      });
      if (advanceRevision) { this.state.revision++; this.remember(); }
      else if (this.history.length) this.history[this.history.length - 1] = {signature: this.fingerprint(), html: this.doc.innerHTML, state: this.snapshot()};
      this.notify(false);
    }
    clipboardPayload(selection) {
      const flat = flatten(active(this.records));
      const spans = this.allSpans(flat.records).filter(span => span.start < selection.end && span.end > selection.start).map(span => Object.assign({}, span, {start: Math.max(span.start, selection.start) - selection.start, end: Math.min(span.end, selection.end) - selection.start}));
      const wanted = new Set(spans.flatMap(span => [span.runId, span.parentRunId]).filter(Boolean).map(id => String(id).toLowerCase()));
      let expanded = true;
      while (expanded) { expanded = false; for (const run of this.state.runs) if (wanted.has(String(run.id).toLowerCase()) && run.parentRunId && !wanted.has(String(run.parentRunId).toLowerCase())) { wanted.add(String(run.parentRunId).toLowerCase()); expanded = true; } }
      return {schema: 1, text: flat.text.slice(selection.start, selection.end), spans, runs: clone(this.state.runs.filter(run => wanted.has(String(run.id).toLowerCase())))};
    }
    applyClipboard(payload, start, end) {
      if (!payload || payload.schema !== 1 || typeof payload.text !== 'string' || !Array.isArray(payload.spans)) return false;
      const flat = flatten(active(this.records));
      const inserted = flat.text.slice(start, end);
      const matches = align(payload.text, inserted).matches;
      const copied = project(payload.spans, matches).map(span => Object.assign({}, span, {start: start + span.start, end: start + span.end}));
      const keep = this.allSpans(flat.records).flatMap(span => {
        if (span.end <= start || span.start >= end) return [span];
        return [span.start < start ? Object.assign({}, span, {end: start}) : null, span.end > end ? Object.assign({}, span, {start: end}) : null].filter(Boolean);
      });
      this.state.spans = this.records.flatMap(record => {
        if (record.side === 'original') return this.state.spans.filter(span => key(span) === key(record));
        const global = flat.records.find(value => key(value) === key(record));
        const projected = [...keep, ...copied].filter(span => span.start < global.globalStart + record.text.length && span.end > global.globalStart).map(span => Object.assign({}, span, {start: Math.max(0, span.start - global.globalStart), end: Math.min(record.text.length, span.end - global.globalStart)}));
        return this.fill(record, projected, 'pasted');
      });
      const runIds = new Set(this.state.runs.map(run => run.id));
      this.state.runs.push(...(payload.runs || []).filter(run => !runIds.has(run.id)));
      this.state.revision++;
      const entry = {signature: this.fingerprint(), html: this.doc.innerHTML, state: this.snapshot()};
      if (this.history.length && this.history[this.history.length - 1].signature === entry.signature) this.history[this.history.length - 1] = entry;
      else this.remember();
      this.notify(true); return true;
    }
  }
  globalThis.MarginsAnnotationEngine = AnnotationEngine;
  // Exposed for independent deterministic alignment regression tests.
  globalThis.MarginsAnnotationAlignment = align;
})();
