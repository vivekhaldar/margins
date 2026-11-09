// Transient inline deletions over the editable proposal. The original stays
// intact; display-only snippets are excluded from saved HTML and text offsets.
(() => {
  'use strict';
  const prose = /^(P|H[1-6]|PRE)$/;
  const inline = /^(A|B|STRONG|I|EM|CODE|SPAN|U|S|SUB|SUP|MARK|SMALL)$/;
  const segmenter = typeof Intl.Segmenter === 'function' ? new Intl.Segmenter(undefined, {granularity: 'word'}) : null;
  const canonical = tag => ({B: 'STRONG', I: 'EM'}[tag] || tag);

  function tokens(root) {
    const nodes = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let text = '';
    for (let node; (node = walker.nextNode());) {
      if (node.parentElement.closest('.diff-removed')) continue;
      const style = [];
      for (let el = node.parentElement; el !== root; el = el.parentElement) {
        if (el.tagName !== 'SPAN') style.push([canonical(el.tagName), el.getAttribute('href')]);
      }
      nodes.push({node, start: text.length, end: text.length + node.length, style: JSON.stringify(style)});
      text += node.data;
    }
    const segments = segmenter ? [...segmenter.segment(text)].map(s => ({text: s.segment, start: s.index})) :
      [...text.matchAll(/\s+|[\p{L}\p{M}\p{N}_]+|[^\s]/gu)].map(m => ({text: m[0], start: m.index}));
    // A word can cross formatting boundaries; keep those boundaries in its key.
    let cursor = 0;
    const items = segments.map(s => {
      const end = s.start + s.text.length, styles = [];
      while (nodes[cursor]?.end <= s.start) cursor++;
      for (let i = cursor; nodes[i] && nodes[i].start < end; i++) {
        const n = nodes[i], length = Math.min(end, n.end) - Math.max(s.start, n.start);
        const last = styles[styles.length - 1];
        if (last?.[0] === n.style) last[1] += length;
        else styles.push([n.style, length]);
      }
      return {...s, end, key: JSON.stringify([s.text, styles])};
    });
    return {items, nodes};
  }

  // Bound both memory and work for large rewrites; keep the full block view if
  // the unmatched middle is too large. Small edits in long prose stay cheap.
  function matches(a, b) {
    const pairs = [];
    let prefix = 0, suffix = 0;
    while (prefix < a.length && prefix < b.length && a[prefix].key === b[prefix].key) {
      pairs.push([prefix, prefix]); prefix++;
    }
    while (suffix < a.length - prefix && suffix < b.length - prefix &&
      a[a.length - suffix - 1].key === b[b.length - suffix - 1].key) suffix++;
    const n = a.length - prefix - suffix, m = b.length - prefix - suffix;
    if ((n + 1) * (m + 1) > 1000000) return null;
    const width = m + 1, table = new Uint32Array((n + 1) * width);
    for (let x = n - 1; x >= 0; x--) for (let y = m - 1; y >= 0; y--) {
      table[x * width + y] = a[prefix + x].key === b[prefix + y].key ?
        1 + table[(x + 1) * width + y + 1] : Math.max(table[(x + 1) * width + y], table[x * width + y + 1]);
    }
    for (let x = 0, y = 0; x < n && y < m;) {
      if (a[prefix + x].key === b[prefix + y].key) { pairs.push([prefix + x++, prefix + y++]); }
      else if (table[(x + 1) * width + y] >= table[x * width + y + 1]) x++;
      else y++;
    }
    for (let i = suffix; i > 0; i--) pairs.push([a.length - i, b.length - i]);
    return pairs;
  }

  function ranges(data, kept) {
    const result = [];
    for (let i = 0; i < data.items.length;) {
      if (kept.has(i)) { i++; continue; }
      let first = i;
      while (i < data.items.length && !kept.has(i)) i++;
      let last = i - 1;
      // Whitespace around a changed phrase is context, not an extra deletion.
      while (first <= last && !data.items[first].text.trim()) first++;
      while (last >= first && !data.items[last].text.trim()) last--;
      if (first > last) continue;
      const start = data.items[first].start, end = data.items[last].end;
      const a = data.nodes.find(n => n.end > start), b = data.nodes.find(n => n.end >= end);
      const range = document.createRange();
      range.setStart(a.node, start - a.start); range.setEnd(b.node, end - b.start);
      result.push(range);
    }
    return result;
  }

  function strip(root) {
    root.querySelectorAll('.diff-before,.diff-removed').forEach(el => el.remove());
    root.querySelectorAll('.diff-compact').forEach(el => el.classList.remove('diff-compact'));
  }

  function cleanHTML(root) {
    const copy = root.cloneNode(true); strip(copy); return copy.innerHTML;
  }

  function point(root, offset, end = false) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let last;
    for (let node; (node = walker.nextNode());) {
      if (!node.length || node.parentElement.closest('.diff-removed')) continue;
      if (offset < node.length || (end && offset === node.length)) return [node, offset];
      offset -= node.length; last = node;
    }
    return last ? [last, last.length] : [root, 0];
  }

  function offsetAt(root, node, offset) {
    const r = document.createRange(); r.selectNodeContents(root); r.setEnd(node, offset);
    const copy = r.cloneContents(); strip(copy); return copy.textContent.length;
  }

  // Keep unchanged snippets in place. Rebuilding or normalizing the proposal on
  // every keystroke would invalidate WebKit's native undo text-node references.
  function placeRemovals(root, removals, splits) {
    const selection = getSelection();
    const endpoints = selection?.rangeCount && root.contains(selection.anchorNode) && root.contains(selection.focusNode)
      ? [offsetAt(root, selection.anchorNode, selection.anchorOffset), offsetAt(root, selection.focusNode, selection.focusOffset)] : null;
    const existing = [...root.querySelectorAll('.diff-removed')];
    for (const removal of removals) {
      const found = existing.find(el => el.innerHTML === removal.html &&
        offsetAt(root, el.parentNode, [...el.parentNode.childNodes].indexOf(el)) === removal.offset);
      if (found) { removal.element = found; existing.splice(existing.indexOf(found), 1); }
    }
    existing.forEach(el => el.remove());
    for (const removal of removals) {
      const el = removal.element || document.createElement('span');
      el.className = 'diff-removed'; el.contentEditable = 'false';
      el.setAttribute('aria-label', 'Deleted: ' + removal.text);
      el.classList.toggle('diff-space-before', removal.spaceBefore);
      el.classList.toggle('diff-space-after', removal.spaceAfter);
      if (removal.element) continue;
      el.innerHTML = removal.html;
      let [node, offset] = point(root, removal.offset);
      // At a formatting boundary, put the old wording outside the new style/link.
      while (offset === 0 && node !== root && node === node.parentNode.firstChild) {
        node = node.parentNode; offset = 0;
      }
      if (node.nodeType === Node.TEXT_NODE) {
        if (offset === node.length) node.after(el);
        else if (offset === 0) node.before(el);
        else {
          const right = node.splitText(offset); splits.push({left: node, right}); right.before(el);
        }
      } else node.insertBefore(el, node.childNodes[offset] || null);
    }
    if (endpoints) selection.setBaseAndExtent(...point(root, endpoints[0], true), ...point(root, endpoints[1], true));
  }

  function create(doc) {
    const cache = new WeakMap();
    const decorated = new Set();
    let composing = false;
    function suspend() {
      if (!decorated.size) return;
      const selection = getSelection();
      const savePoint = (node, offset) => {
        const root = (node.nodeType === 1 ? node : node.parentElement).closest('.chg > ins');
        return root ? {root, offset: offsetAt(root, node, offset)} : {node, offset};
      };
      const endpoints = selection?.rangeCount && doc.contains(selection.anchorNode) && doc.contains(selection.focusNode)
        ? [savePoint(selection.anchorNode, selection.anchorOffset), savePoint(selection.focusNode, selection.focusOffset)] : null;
      for (const ch of decorated) {
        const entry = cache.get(ch);
        strip(ch);
        // Reverse only our own splits, preserving the canonical text nodes that
        // WebKit's undo stack refers to. Do this BEFORE native editing starts.
        for (const {left, right} of [...(entry?.splits || [])].reverse()) {
          if (left.parentNode && left.nextSibling === right) { left.appendData(right.data); right.remove(); }
        }
        cache.delete(ch);
      }
      decorated.clear();
      CSS.highlights?.delete('margins-added');
      if (endpoints) {
        const restore = p => p.root ? point(p.root, p.offset, true) : [p.node, p.offset];
        selection.setBaseAndExtent(...restore(endpoints[0]), ...restore(endpoints[1]));
      }
    }
    doc.addEventListener('beforeinput', suspend);
    // Keydown precedes WebKit's target-range calculation; beforeinput also
    // covers menu-driven undo, dictation, and other native editing commands.
    doc.addEventListener('keydown', e => {
      if (e.key.length === 1 || ['Backspace', 'Delete', 'Enter'].includes(e.key)) {
        suspend(); setTimeout(refresh, 0);
      }
    });
    for (const event of ['cut', 'paste', 'drop']) doc.addEventListener(event, suspend);
    doc.addEventListener('compositionstart', () => { suspend(); composing = true; });
    doc.addEventListener('compositionend', () => { composing = false; refresh(); });
    function refresh() {
      if (composing || !globalThis.Highlight || !globalThis.CSS?.highlights) return;
      for (const ch of decorated) if (!doc.contains(ch)) decorated.delete(ch);
      const highlights = [];
      doc.querySelectorAll(':scope > .chg').forEach(ch => {
        const old = ch.querySelector(':scope > del'), proposal = ch.querySelector(':scope > ins');
        if (!old || !proposal) return;
        const key = JSON.stringify([old.innerHTML, cleanHTML(proposal)]);
        const previous = cache.get(ch);
        if (previous?.key === key && previous.old === old.firstElementChild && previous.proposal === proposal.firstElementChild &&
          previous.snippets.every(el => proposal.contains(el)) &&
          previous.ranges.every(range => !range.collapsed && proposal.contains(range.startContainer) && proposal.contains(range.endContainer))) {
          highlights.push(...previous.ranges); return;
        }
        ch.querySelector(':scope > .diff-before')?.remove();
        ch.classList.remove('diff-compact');
        const entry = {key, old: old.firstElementChild, proposal: proposal.firstElementChild, ranges: [], snippets: [], splits: previous?.splits || []}; cache.set(ch, entry);
        const a = old.firstElementChild, b = proposal.firstElementChild;
        if (old.children.length !== 1 || proposal.children.length !== 1 || !a || !b ||
          !prose.test(a.tagName) || a.tagName !== b.tagName ||
          [...old.childNodes, ...proposal.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) ||
          [...a.querySelectorAll('*'), ...b.querySelectorAll('*')].some(el => !el.closest('.diff-removed') && !inline.test(el.tagName)) ||
          a.textContent.length + b.textContent.length > 100000) { strip(proposal); return; }
        const left = tokens(a), right = tokens(b), pairs = matches(left.items, right.items);
        if (!pairs || !pairs.some(([i]) => left.items[i].text.trim())) { strip(proposal); return; }
        const removed = ranges(left, new Set(pairs.map(p => p[0])));
        const added = ranges(right, new Set(pairs.map(p => p[1])));
        // Whitespace-only changes remain visible in the full before/after view.
        if (!removed.length && !added.length && left.items.map(t => t.text).join('') !== right.items.map(t => t.text).join('')) { strip(proposal); return; }
        ch.classList.add('diff-compact');
        const removals = removed.map(range => {
            const start = offsetAt(a, range.startContainer, range.startOffset);
            const end = offsetAt(a, range.endContainer, range.endOffset);
            const previous = pairs.filter(([i]) => left.items[i].end <= start).at(-1);
            const next = pairs.find(([i]) => left.items[i].start >= end);
            const first = previous ? previous[1] + 1 : 0;
            const limit = next ? next[1] : right.items.length;
            let index = first;
            while (index < limit && !right.items[index].text.trim()) index++;
            const offset = right.items[index]?.start ?? right.items.at(-1)?.end ?? 0;
            const text = range.toString();
            const before = right.items.map(t => t.text).join('').slice(0, offset);
            const after = right.items.map(t => t.text).join('').slice(offset);
            const snippet = document.createElement('span');
            let fragment = range.cloneContents();
            let ancestor = range.commonAncestorContainer;
            if (ancestor.nodeType === 3) ancestor = ancestor.parentElement;
            for (; ancestor !== a; ancestor = ancestor.parentElement) {
              const wrapper = ancestor.cloneNode(false); wrapper.removeAttribute('data-bid');
              wrapper.append(fragment); fragment = wrapper;
            }
            snippet.append(fragment);
            return {offset, text, html: snippet.innerHTML,
              spaceBefore: /\S$/.test(before) && /\s/.test(a.textContent[start - 1] || ''),
              spaceAfter: /^\S/.test(after) && (index < limit || /\s/.test(a.textContent[end] || ''))};
          });
        placeRemovals(b, removals, entry.splits);
        decorated.add(ch);
        entry.snippets = [...b.querySelectorAll('.diff-removed')];
        // Inserting an inline snippet can split a text node; resolve highlights
        // against the final DOM, excluding the display-only deletion nodes.
        entry.ranges = ranges(tokens(b), new Set(pairs.map(p => p[1])));
        highlights.push(...entry.ranges);
      });
      CSS.highlights.set('margins-added', new Highlight(...highlights));
    }
    return {refresh, suspend};
  }
  window.MarginsTrackedDiff = {create, strip};
})();
