// Real WebKit integration checks; no model requests or user documents.
const api = window.margins, doc = document.querySelector('#doc'), A = window.MarginsAnnotations;
const passed = [];
const assert = (value, message) => { if (!value) throw new Error(message); passed.push(message); };
const added = () => [...CSS.highlights.get('margins-added')].map(r => r.toString());
const removed = () => [...doc.querySelectorAll('.diff-before > del')].map(el => el.textContent);
const compact = () => !!doc.querySelector('.diff-compact');
const replace = (old, proposal) => {
  api.load(old);
  const id = api.getBlocks().blocks[0].id;
  api.applyEdits(1, [{op: 'replace', blockId: id, html: proposal}], false);
  return id;
};
const before = '<p>The first sentence stays. The old sentence changes. The final sentence stays.</p>';
const after = '<p>The first sentence stays. The new sentence changes. The final sentence stays.</p>';
let id = replace(before, after);
assert(compact(), 'A one-word edit uses the compact view');
assert(JSON.stringify(added()) === '["new"]' && JSON.stringify(removed()) === '["old"]', 'Only changed words receive insertion/deletion styling');
assert(getComputedStyle(doc.querySelector('.chg > del')).display === 'none', 'The full original paragraph is hidden');
assert(getComputedStyle(doc.querySelector('.chg > ins')).backgroundColor === 'rgba(0, 0, 0, 0)', 'Unchanged proposed text has no block highlight');
assert(api.getBlocks().blocks[0].html === after, 'Agent context contains the clean proposal');
assert(!/diff-compact|diff-before|margins-added/.test(api.html()), 'Presentation markup never enters saved HTML');
assert(A.getState().text === doc.querySelector('.chg > ins').textContent, 'Removal snippets do not enter annotation text');
const sameParagraph = doc.querySelector('.chg > ins p');
sameParagraph.innerHTML = sameParagraph.innerHTML;
api.getBlocks();
assert(added()[0] === 'new', 'Replacing identical DOM content rebuilds detached highlight ranges');
const pending = api.snapshot();
api.load(pending.html, pending.annotations);
assert(compact() && added()[0] === 'new', 'Saved pending edits reopen with granular highlights');
api.reject({all: true});
assert(api.getBlocks().blocks[0].html === before && api.getBlocks().blocks[0].id === id, 'Reject restores the exact original and block ID');
assert(added().length === 0 && !doc.querySelector('.diff-before'), 'Review clears transient diff presentation');

replace(before, after); api.accept({all: true});
assert(api.getBlocks().blocks[0].html === after, 'Accept keeps the exact proposal without diff markup');

replace('<p>Start. An old sentence. End.</p>', '<p>Start. A completely new thought. End.</p>');
assert(removed().join(' ') === 'An old sentence' && added().join(' ') === 'A completely new thought', 'A sentence rewrite leaves surrounding sentences and punctuation unmarked');
replace('<p>One red apple and one blue pear.</p>', '<p>One green apple and one ripe pear.</p>');
assert(JSON.stringify(added()) === '["green","ripe"]' && JSON.stringify(removed()) === '["red","blue"]', 'Separate edits keep the intervening words unchanged');
replace('<p>Keep this sentence.</p>', '<p>Keep this useful sentence.</p>');
assert(compact() && added()[0] === 'useful' && removed().length === 0, 'Word insertion does not duplicate the paragraph');
replace('<p>Keep this redundant sentence.</p>', '<p>Keep this sentence.</p>');
assert(compact() && removed()[0] === 'redundant' && added().length === 0, 'Word deletion shows only removed wording');
replace('<p>Same same word.</p>', '<p>Same word.</p>');
assert(compact() && removed()[0] === 'same', 'Repeated words align without losing a deletion');
replace('<p>Hello, world!</p>', '<p>Hello, world?</p>');
assert(added()[0] === '?' && removed()[0] === '!', 'Punctuation-only changes stay visible');
replace('<p>Café déjà vu 👩🏽‍💻.</p>', '<p>Café encore vu 👩🏽‍💻.</p>');
assert(added()[0] === 'encore' && removed()[0] === 'déjà', 'Accented words and emoji retain correct range offsets');

const unlinked = '<p>It was called the editor of a lifetime. Agents lower the cost.</p>';
const linked = '<p>It was called <a href="https://example.com/emacs">the editor of a lifetime</a>. Agents lower the cost.</p>';
replace(unlinked, linked);
assert(compact() && added().join('') === 'the editor of a lifetime', 'Adding only a link highlights just its anchor text');
assert(removed().join('') === 'the editor of a lifetime', 'Link-only edits do not repeat surrounding prose');
api.accept({all: true});
assert(api.getBlocks().blocks[0].html === linked, 'Accept preserves the added link');
replace(linked, linked.replace('example.com/emacs', 'example.com/lifetime'));
assert(compact() && added().join('') === 'the editor of a lifetime', 'A changed URL is visible even when the label is unchanged');
assert(doc.querySelector('.diff-before a')?.getAttribute('href') === 'https://example.com/emacs', 'The removed snippet retains the original link target');
api.reject({all: true});
assert(api.getBlocks().blocks[0].html === linked, 'Reject restores the original link target');
replace('<p>Keep the important word.</p>', '<p>Keep the <strong>important</strong> word.</p>');
assert(compact() && added()[0] === 'important', 'Formatting-only edits highlight the formatted word');
replace('<p>Keep <em>the old wording</em> here.</p>', '<p>Keep <em>the new wording</em> here.</p>');
assert(doc.querySelector('.diff-before em')?.textContent === 'old', 'Removed snippets preserve nested formatting');

id = replace(before, after);
let cid = doc.querySelector('.chg').dataset.cid;
api.applyRefinement(cid, after.replace('new sentence', 'better sentence'), 1);
assert(added()[0] === 'better' && removed()[0] === 'old', 'Refinements recompute against the original text');
api.applyEdits(2, [{op: 'replace', blockId: id, html: after.replace('new sentence', 'latest sentence')}], false);
assert(added()[0] === 'latest' && removed()[0] === 'old', 'A later instruction recomputes the existing change');
api.preview(pending.html, pending.annotations);
assert(compact() && added()[0] === 'new' && doc.contentEditable === 'false', 'History displays the same granular diff read-only');
api.endPreview();
assert(compact() && added()[0] === 'latest', 'Leaving history restores the live diff');

// Highlight ranges must not wrap/reparent editable text or disturb native undo.
const paragraph = doc.querySelector('.chg > ins p'), textNode = paragraph.firstChild;
doc.focus(); getSelection().setPosition(textNode, textNode.length);
document.execCommand('insertText', false, ' More.');
api.flushForSave();
assert(paragraph.firstChild === textNode && getSelection().anchorNode === textNode, 'Typing retains the original text node and caret');
assert(added().join(' ').includes('More'), 'Typing refreshes the diff');
document.execCommand('undo'); api.flushForSave();
assert(!paragraph.textContent.includes('More.') && added()[0] === 'latest', 'Native undo refreshes highlights without corrupting the proposal');
document.execCommand('redo'); api.flushForSave();
assert(paragraph.textContent.endsWith(' More.'), 'Native redo still works in a pending replacement');

api.showFind();
const input = document.querySelector('#findin');
const query = text => { input.value = text; input.dispatchEvent(new Event('input')); return document.querySelector('#findcount').textContent; };
assert(query('first sentence') === '1 of 1', 'Find does not count the hidden unchanged original');
assert(query('old') === '1 of 1', 'Find includes the visible removed wording once');
document.querySelector('#findclose').click();

for (const [old, proposal, name] of [
  ['<p>Same text</p>', '<h2>Same text</h2>', 'block type changes'],
  ['<p>One paragraph.</p>', '<p>One paragraph.</p><p>Another.</p>', 'multiple blocks'],
  ['<ul><li>Old</li></ul>', '<ul><li>New</li></ul>', 'lists'],
  ['<table><tr><td>Old</td></tr></table>', '<table><tr><td>New</td></tr></table>', 'tables'],
  ['<p>Image <img src="https://example.com/a.png"></p>', '<p>Image <img src="https://example.com/b.png"></p>', 'images'],
  ['<p>Line<br>break</p>', '<p>Line break</p>', 'line breaks'],
  ['<p>Entire original</p>', '<p>Fresh replacement</p>', 'whole rewrites'],
  [`<p>${'old '.repeat(2000)}</p>`, `<p>${'new '.repeat(2000)}</p>`, 'large rewrites']
]) {
  replace(old, proposal);
  assert(doc.querySelector('.chg') && !compact() && added().length === 0, `${name} retain the complete before/after view`);
}
api.load('<div class="chg" data-bid="b1" data-cid="c1" data-step="1" data-kind="replace"><del><pre>Keep  spacing</pre></del><ins><pre>Keep spacing</pre></ins></div>');
assert(!compact() && getComputedStyle(doc.querySelector('.chg > del')).display !== 'none', 'Stored whitespace-only changes retain the complete before/after view');
api.load('<p>Keep.</p>'); id = api.getBlocks().blocks[0].id;
api.applyEdits(1, [{op: 'delete', blockId: id}], false);
assert(!compact() && getComputedStyle(doc.querySelector('.chg > del')).display !== 'none', 'Whole-block deletion remains visible');
api.load(''); api.applyEdits(1, [{op: 'insertAfter', blockId: '^', html: '<p>First draft.</p>'}], false);
assert(!compact() && doc.querySelector('.chg > ins').textContent === 'First draft.', 'First drafts keep their insertion view');

// Leave a realistic preview for screenshot inspection.
api.load('<h1>Granular tracked changes</h1>' + unlinked + '<p>The first sentence stays. The old sentence changes. The final sentence stays.</p>');
const blocks = api.getBlocks().blocks;
api.applyEdits(1, [{op: 'replace', blockId: blocks[1].id, html: linked}, {op: 'replace', blockId: blocks[2].id, html: after}], false);
doc.blur(); getSelection().removeAllRanges();
await new Promise(resolve => setTimeout(resolve, 1600));
document.querySelector('#scroll').scrollTop = 0;
return {passed: passed.length, checks: passed};
