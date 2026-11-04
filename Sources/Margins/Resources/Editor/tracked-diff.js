// A transient, word-level view over the original/proposal blocks. Neither side
// is rewritten: native editing, review, provenance, and saved HTML stay intact.
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
    root.querySelectorAll('.diff-before').forEach(el => el.remove());
    root.querySelectorAll('.diff-compact').forEach(el => el.classList.remove('diff-compact'));
  }

  function create(doc) {
    const cache = new WeakMap();
    function refresh() {
      if (!globalThis.Highlight || !globalThis.CSS?.highlights) return;
      const highlights = [];
      doc.querySelectorAll(':scope > .chg').forEach(ch => {
        const old = ch.querySelector(':scope > del'), proposal = ch.querySelector(':scope > ins');
        if (!old || !proposal) return;
        const key = JSON.stringify([old.innerHTML, proposal.innerHTML]);
        const previous = cache.get(ch);
        if (previous?.key === key && previous.old === old.firstElementChild && previous.proposal === proposal.firstElementChild &&
          previous.ranges.every(range => !range.collapsed && proposal.contains(range.startContainer) && proposal.contains(range.endContainer))) {
          highlights.push(...previous.ranges); return;
        }
        ch.querySelector(':scope > .diff-before')?.remove();
        ch.classList.remove('diff-compact');
        const entry = {key, old: old.firstElementChild, proposal: proposal.firstElementChild, ranges: []}; cache.set(ch, entry);
        const a = old.firstElementChild, b = proposal.firstElementChild;
        if (old.children.length !== 1 || proposal.children.length !== 1 || !a || !b ||
          !prose.test(a.tagName) || a.tagName !== b.tagName ||
          [...old.childNodes, ...proposal.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) ||
          [...a.querySelectorAll('*'), ...b.querySelectorAll('*')].some(el => !inline.test(el.tagName)) ||
          a.textContent.length + b.textContent.length > 100000) return;
        const left = tokens(a), right = tokens(b), pairs = matches(left.items, right.items);
        if (!pairs || !pairs.some(([i]) => left.items[i].text.trim())) return;
        const removed = ranges(left, new Set(pairs.map(p => p[0])));
        const added = ranges(right, new Set(pairs.map(p => p[1])));
        // Whitespace-only changes remain visible in the full before/after view.
        if (!removed.length && !added.length && a.textContent !== b.textContent) return;
        ch.classList.add('diff-compact');
        if (removed.length) {
          const before = document.createElement('div');
          before.className = 'diff-before'; before.contentEditable = 'false';
          before.setAttribute('aria-label', 'Removed text');
          removed.forEach((range, i) => {
            if (i) { const gap = document.createElement('span'); gap.className = 'diff-gap'; gap.textContent = ' … '; before.append(gap); }
            const snippet = document.createElement('del');
            let fragment = range.cloneContents();
            let ancestor = range.commonAncestorContainer;
            if (ancestor.nodeType === 3) ancestor = ancestor.parentElement;
            for (; ancestor !== a; ancestor = ancestor.parentElement) {
              const wrapper = ancestor.cloneNode(false); wrapper.removeAttribute('data-bid');
              wrapper.append(fragment); fragment = wrapper;
            }
            snippet.append(fragment); before.append(snippet);
          });
          ch.insertBefore(before, proposal);
        }
        entry.ranges = added; highlights.push(...added);
      });
      CSS.highlights.set('margins-added', new Highlight(...highlights));
    }
    return {refresh};
  }
  window.MarginsTrackedDiff = {create, strip};
})();
