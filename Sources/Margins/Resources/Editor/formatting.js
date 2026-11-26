// Author formatting controls, keyboard shortcuts, and Markdown heading shortcuts.
(() => {
  'use strict';
  const BLOCK_TAGS = {paragraph: 'p', h1: 'h1', h2: 'h2', h3: 'h3'};
  const BLOCK_COMMANDS = {P: 'paragraph', H1: 'h1', H2: 'h2', H3: 'h3'};
  const INLINE_COMMANDS = {
    bold: 'bold',
    italic: 'italic',
    underline: 'underline',
    bullets: 'insertUnorderedList',
    numbers: 'insertOrderedList',
    removeFormat: 'removeFormat',
  };
  const SHIFT_SHORTCUTS = {
    '0': 'paragraph', ')': 'paragraph',
    '7': 'numbers', '&': 'numbers',
    '8': 'bullets', '*': 'bullets',
    '9': 'checklist', '(': 'checklist',
    x: 'toggleCheck',
  };
  const ALT_SHORTCUTS = {
    Digit0: 'removeFormat', '0': 'removeFormat',
    Digit1: 'h1', '1': 'h1',
    Digit2: 'h2', '2': 'h2',
    Digit3: 'h3', '3': 'h3',
  };
  const MD_HEADINGS = {'#': 'h1', '##': 'h2', '###': 'h3'};

  function resolveShortcut(e) {
    if (!e || (!e.metaKey && !e.ctrlKey)) return null;
    if (e.altKey) {
      if (e.shiftKey) return null;
      return ALT_SHORTCUTS[e.code] || ALT_SHORTCUTS[e.key] || null;
    }
    const key = (e.key || '').toLowerCase();
    if (e.shiftKey) {
      if (e.code === 'Digit0') return 'paragraph';
      return SHIFT_SHORTCUTS[key] || null;
    }
    return {b: 'bold', i: 'italic', u: 'underline'}[key] || null;
  }

  function markdownHeadingCommand(prefix) {
    return MD_HEADINGS[prefix] || null;
  }

  const nodeEl = n => (n && n.nodeType === 1 ? n : n?.parentElement || null);

  function activeBlockCommand(doc, range) {
    if (!range) return null;
    const el = nodeEl(range.startContainer);
    if (!el || !doc.contains(el) || el.closest('ul,ol,pre,blockquote')) return null;
    const block = el.closest('p,h1,h2,h3');
    if (!block || !doc.contains(block)) return null;
    return BLOCK_COMMANDS[block.tagName] || null;
  }

  function selectedBlockElements(doc, range) {
    if (!range) return [];
    const blocks = [...doc.querySelectorAll('p,h1,h2,h3,div:not(.chg)')].filter(el =>
      !el.closest('.chg > del,.tools,ul,ol,pre,blockquote') &&
      (el.contains(range.startContainer) || (!range.collapsed && range.intersectsNode(el))));
    return blocks;
  }

  function stripChecklistMarkup(lists) {
    lists.forEach(list => {
      list.removeAttribute('data-task');
      list.querySelectorAll(':scope > li > input[type=checkbox]').forEach(box => box.remove());
    });
  }

  function applyBlockFormat(doc, sel, range, command, lists) {
    let target = BLOCK_TAGS[command];
    const blocks = selectedBlockElements(doc, range);
    if (command !== 'paragraph' && blocks.length && blocks.every(b => b.tagName === target.toUpperCase())) {
      target = 'p';
    }
    const activeLists = lists();
    if (activeLists.length) {
      stripChecklistMarkup(activeLists);
      const list = nodeEl(sel.anchorNode)?.closest('ul,ol') || activeLists[0];
      document.execCommand(list.tagName === 'OL' ? 'insertOrderedList' : 'insertUnorderedList', false, null);
    }
    document.execCommand('formatBlock', false, target);
  }

  function isEditableRange(doc, range) {
    if (!range || doc.classList.contains('ro')) return false;
    return [range.startContainer, range.endContainer].every(n => doc.contains(n) &&
      !nodeEl(n)?.closest('[contenteditable="false"],.tools')) &&
      ![...doc.querySelectorAll('.chg > del,.tools')].some(el => range.intersectsNode(el));
  }

  function updateFormatbarState(doc, formatbar) {
    const sel = window.getSelection();
    const range = sel?.rangeCount && isEditableRange(doc, sel.getRangeAt(0)) ? sel.getRangeAt(0) : null;
    const activeBlock = activeBlockCommand(doc, range);
    formatbar.querySelectorAll('[data-format]').forEach(button => {
      const cmd = button.dataset.format;
      if (['bold', 'italic', 'underline'].includes(cmd)) {
        button.setAttribute('aria-pressed', String(document.queryCommandState(cmd)));
      } else if (BLOCK_TAGS[cmd]) {
        button.setAttribute('aria-pressed', String(activeBlock === cmd));
      }
    });
  }

  function applyChecklist(sel, lists, syncChecklists) {
    const anchor = nodeEl(sel.anchorNode);
    if (!anchor?.closest('ul,ol') || anchor.closest('ol')) document.execCommand('insertUnorderedList');
    const targets = lists().filter(list => list.tagName === 'UL');
    const remove = targets.length && targets.every(list => list.hasAttribute('data-task'));
    targets.forEach(list => {
      list.toggleAttribute('data-task', !remove);
      if (remove) list.querySelectorAll(':scope > li > input[type=checkbox]').forEach(box => box.remove());
    });
    syncChecklists();
  }

  function applyToggleCheck(doc, sel, range) {
    const items = [...doc.querySelectorAll('ul[data-task] > li')].filter(li =>
      li.contains(sel.anchorNode) || (!sel.isCollapsed && range.intersectsNode(li)));
    const boxes = items.map(li => li.querySelector(':scope > input[type=checkbox]')).filter(Boolean);
    const checked = boxes.some(box => !box.checked);
    boxes.forEach(box => { box.checked = checked; box.toggleAttribute('checked', checked); });
  }

  function tryMarkdownHeading(doc, e, runFormat) {
    if (e.key !== ' ' || e.metaKey || e.ctrlKey || e.altKey || e.isComposing) return false;
    const sel = window.getSelection();
    if (!sel?.rangeCount || !sel.isCollapsed) return false;
    const range = sel.getRangeAt(0);
    if (!isEditableRange(doc, range)) return false;
    const el = nodeEl(range.startContainer);
    if (!el || el.closest('pre,code,li,blockquote,h1,h2,h3')) return false;
    const block = el.closest('p,div');
    if (!block || block === doc || block.classList.contains('chg') || !doc.contains(block)) return false;
    const prefix = document.createRange();
    prefix.setStart(block, 0);
    prefix.setEnd(range.startContainer, range.startOffset);
    const cmd = markdownHeadingCommand(prefix.toString());
    if (!cmd) return false;
    e.preventDefault();
    prefix.deleteContents();
    if (!block.firstChild) {
      block.append(document.createElement('br'));
      sel.setPosition(block, 0);
    }
    runFormat(cmd);
    return true;
  }

  function executeFormat(deps, state, command) {
    const {doc, formatbar, trackedDiff, syncChecklists, prepareTypingParagraph, noteEdit, normalize, scheduleOutline} = deps;
    const active = document.activeElement;
    if (active !== document.body && !doc.contains(active) && !formatbar.contains(active)) return;
    const sel = window.getSelection();
    let range = sel.rangeCount ? sel.getRangeAt(0) : null;
    if (!range || !doc.contains(range.commonAncestorContainer)) range = state.formatRange;
    if (!isEditableRange(doc, range) || !range.startContainer.isConnected) return;
    doc.focus(); sel.removeAllRanges(); sel.addRange(range);
    if (BLOCK_TAGS[command]) prepareTypingParagraph();
    trackedDiff?.suspend();
    range = sel.getRangeAt(0);
    const lists = () => [...doc.querySelectorAll('ul,ol')].filter(list =>
      list.contains(sel.anchorNode) || (!sel.isCollapsed && sel.getRangeAt(0).intersectsNode(list)));
    if (command === 'toggleCheck') {
      applyToggleCheck(doc, sel, range);
    } else if (command === 'checklist') {
      applyChecklist(sel, lists, syncChecklists);
    } else if (BLOCK_TAGS[command]) {
      applyBlockFormat(doc, sel, range, command, lists);
    } else if (INLINE_COMMANDS[command]) {
      if (command === 'bullets' || command === 'numbers') stripChecklistMarkup(lists());
      document.execCommand(INLINE_COMMANDS[command], false, null);
    } else {
      return;
    }
    noteEdit(); normalize(); scheduleOutline();
    state.formatRange = sel.rangeCount ? sel.getRangeAt(0).cloneRange() : null;
    updateFormatbarState(doc, formatbar);
  }

  function create(deps) {
    const {doc, formatbar, prepareTypingParagraph, noteEdit} = deps;
    const state = {formatRange: null};
    const format = command => executeFormat(deps, state, command);
    const updateFormatbar = () => updateFormatbarState(doc, formatbar);

    document.addEventListener('selectionchange', () => {
      const sel = window.getSelection();
      if (sel.rangeCount && isEditableRange(doc, sel.getRangeAt(0))) state.formatRange = sel.getRangeAt(0).cloneRange();
      updateFormatbar();
    });
    formatbar.addEventListener('mousedown', e => e.preventDefault());
    formatbar.addEventListener('click', e => {
      const button = e.target.closest('[data-format]');
      if (button) format(button.dataset.format);
    });
    doc.addEventListener('click', e => {
      if (!e.target.matches('input[type=checkbox]')) return;
      if (doc.classList.contains('ro') || e.target.closest('.chg > del')) { e.preventDefault(); return; }
      e.target.toggleAttribute('checked', e.target.checked);
      noteEdit(e.target);
    });
    doc.addEventListener('keydown', e => {
      if (!e.metaKey && !e.ctrlKey && (e.key.length === 1 || e.key === 'Enter')) prepareTypingParagraph();
      if (tryMarkdownHeading(doc, e, format)) return;
      const command = resolveShortcut(e);
      if (command) {
        e.preventDefault(); format(command);
      } else if (e.key === 'Enter' && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey) {
        const li = nodeEl(window.getSelection().anchorNode)?.closest('ul[data-task] > li');
        // Let WebKit's empty-list-item behavior exit a checklist normally.
        if (li && !li.textContent.trim()) li.querySelector(':scope > input[type=checkbox]')?.remove();
      }
    });

    return {
      format,
      editableRange: range => isEditableRange(doc, range),
      updateFormatbar,
      reset() { state.formatRange = null; updateFormatbar(); },
    };
  }

  globalThis.MarginsFormatting = {create, resolveShortcut, markdownHeadingCommand};
})();
