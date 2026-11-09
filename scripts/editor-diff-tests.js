// Real WebKit integration checks; no model requests or user documents.
const api = window.margins, doc = document.querySelector('#doc'), A = window.MarginsAnnotations;
const passed = [];
const assert = (value, message) => { if (!value) throw new Error(message + ': ' + api.html() + ' | text=' + A.getState().text); passed.push(message); };
// execCommand does not dispatch beforeinput; reproduce the native event order.
const command = (name, value) => {
  const inputType = {undo: 'historyUndo', redo: 'historyRedo', insertText: 'insertText'}[name] || name;
  doc.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, inputType}));
  document.execCommand(name, false, value);
};
const added = () => [...CSS.highlights.get('margins-added')].map(r => r.toString());
const removed = () => [...doc.querySelectorAll('.diff-removed')].map(el => el.textContent);
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
const inlineRemoval = doc.querySelector('.chg > ins p .diff-removed');
assert(inlineRemoval?.previousSibling.textContent === 'The first sentence stays. The ' &&
  inlineRemoval.nextSibling.textContent.startsWith('new sentence'), 'Deleted and inserted words sit together at the edit location');
const removalRect = inlineRemoval.getBoundingClientRect(), additionRect = [...CSS.highlights.get('margins-added')][0].getBoundingClientRect();
assert(Math.abs(removalRect.top - additionRect.top) < 2 && additionRect.left >= removalRect.right &&
  additionRect.left - removalRect.right < 8, 'Replacement words render adjacent on the same line');
assert(JSON.stringify(added()) === '["new"]' && JSON.stringify(removed()) === '["old"]', 'Only changed words receive insertion/deletion styling');
assert(getComputedStyle(doc.querySelector('.chg > del')).display === 'none', 'The full original paragraph is hidden');
assert(getComputedStyle(doc.querySelector('.chg > ins')).backgroundColor === 'rgba(0, 0, 0, 0)', 'Unchanged proposed text has no block highlight');
assert(api.getBlocks().blocks[0].html === after, 'Agent context contains the clean proposal');
assert(!/diff-compact|diff-removed|margins-added/.test(api.html()), 'Presentation markup never enters saved HTML');
assert(A.getState().text === 'The first sentence stays. The new sentence changes. The final sentence stays.', 'Removal snippets do not enter annotation text');
const sameParagraph = doc.querySelector('.chg > ins p');
sameParagraph.innerHTML = sameParagraph.innerHTML;
api.getBlocks();
assert(added()[0] === 'new', 'Replacing identical DOM content rebuilds detached highlight ranges');
const pending = api.snapshot();
api.load(pending.html, pending.annotations);
assert(compact() && added()[0] === 'new', 'Saved pending edits reopen with granular highlights');
api.reject({all: true});
assert(api.getBlocks().blocks[0].html === before && api.getBlocks().blocks[0].id === id, 'Reject restores the exact original and block ID');
assert(added().length === 0 && !doc.querySelector('.diff-removed'), 'Review clears transient diff presentation');

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
assert(doc.querySelector('.diff-removed a')?.getAttribute('href') === 'https://example.com/emacs', 'The removed snippet retains the original link target');
api.reject({all: true});
assert(api.getBlocks().blocks[0].html === linked, 'Reject restores the original link target');
replace('<p>Keep the important word.</p>', '<p>Keep the <strong>important</strong> word.</p>');
assert(compact() && added()[0] === 'important', 'Formatting-only edits highlight the formatted word');
replace('<p>Keep <em>the old wording</em> here.</p>', '<p>Keep <em>the new wording</em> here.</p>');
assert(doc.querySelector('.diff-removed em')?.textContent === 'old', 'Removed snippets preserve nested formatting');

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

// Presentation is suspended before editing so native undo sees stable text nodes.
const paragraph = doc.querySelector('.chg > ins p'), textNode = paragraph.lastChild;
doc.focus(); getSelection().setPosition(textNode, textNode.length);
command('insertText', ' More.');
api.flushForSave();
assert(paragraph.contains(getSelection().anchorNode) && A.getState().text.endsWith(' More.'), 'Typing retains the proposal text and caret');
assert(added().join(' ').includes('More'), 'Typing refreshes the diff');
command('undo'); api.flushForSave();
assert(!paragraph.textContent.includes('More.') && added()[0] === 'latest', 'Native undo refreshes highlights without corrupting the proposal');
command('redo'); api.flushForSave();
assert(paragraph.textContent.endsWith(' More.'), 'Native redo still works in a pending replacement');

api.showFind();
const input = document.querySelector('#findin');
const query = text => { input.value = text; input.dispatchEvent(new Event('input')); return document.querySelector('#findcount').textContent; };
assert(query('first sentence') === '1 of 1', 'Find does not count the hidden unchanged original');
assert(query('old') === '1 of 1', 'Find includes the visible removed wording once');
assert(query('The latest sentence') === '1 of 1', 'Find matches proposal phrases across inline deletions');
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

// The reported easier → cheaper case, including selections and clipboard hygiene.
const enterpriseBefore = '<p>The entire enterprise software complex rests on one bedrock assumption: it is easier to buy a solution with a million knobs and dials and then hire an IT department to manage and turn them.</p>';
const enterpriseAfter = '<p>The entire enterprise software complex rests on one bedrock assumption: it is cheaper to buy a solution with a million knobs and dials and hire an IT department to turn them.</p>';
replace(enterpriseBefore, enterpriseAfter);
assert(doc.querySelector('.diff-removed').textContent === 'easier' && doc.querySelector('.diff-removed').nextSibling.textContent.startsWith('cheaper'), 'Easier is deleted immediately before cheaper');
const enterpriseP = doc.querySelector('.chg > ins p');
doc.focus(); getSelection().selectAllChildren(enterpriseP);
assert(A.selectionFromDOM().text === enterpriseAfter.slice(3, -4), 'Selections and comment anchors exclude inline deletions');
const clipboard = new DataTransfer();
doc.dispatchEvent(new ClipboardEvent('copy', {bubbles: true, cancelable: true, clipboardData: clipboard}));
assert(clipboard.getData('text/plain') === enterpriseAfter.slice(3, -4) && !/easier|diff-removed/.test(clipboard.getData('text/html')), 'Copy contains only proposal text and formatting');
const enterprisePending = api.snapshot();
assert(!enterprisePending.html.includes('diff-removed') && A.getState().text === enterpriseAfter.slice(3, -4), 'Snapshots and attribution exclude inline deletions');
api.accept({all: true});
assert(api.getBlocks().blocks[0].html === enterpriseAfter && !doc.querySelector('.diff-removed'), 'Accept removes every inline deletion');
api.load(enterprisePending.html, enterprisePending.annotations); api.reject({all: true});
assert(api.getBlocks().blocks[0].html === enterpriseBefore, 'Reject after reload restores the original paragraph');

// Edit beside a deletion, then undo/redo without replacing live text nodes.
replace('<p>It is easier to use.</p>', '<p>It is cheaper to use.</p>');
const editedWord = [...CSS.highlights.get('margins-added')][0].startContainer;
doc.focus(); getSelection().setPosition(editedWord, 7);
command('insertText', ' still'); api.flushForSave();
assert(A.getState().text === 'It is cheaper still to use.' && doc.querySelector('.chg > ins').contains(getSelection().anchorNode), 'Typing beside an inline deletion retains the caret');
command('undo'); api.flushForSave();
assert(A.getState().text === 'It is cheaper to use.' && removed().join('') === 'easier', 'Undo beside an inline deletion restores the proposal');
command('redo'); api.flushForSave();
assert(A.getState().text === 'It is cheaper still to use.', 'Redo beside an inline deletion restores typed text');

// Manual edits in unchanged text can introduce a new deletion hunk.
replace('<p>It is easier to use every day.</p>', '<p>It is cheaper to use every day.</p>');
const suffix = doc.querySelector('.chg > ins p').lastChild;
const day = suffix.textContent.indexOf('every');
doc.focus(); getSelection().setBaseAndExtent(suffix, day, suffix, day + 5);
command('insertText', 'each'); api.flushForSave();
assert(A.getState().text === 'It is cheaper to use each day.', 'Manual replacement creates a second inline diff');
command('undo'); api.flushForSave();
assert(A.getState().text === 'It is cheaper to use every day.', 'Undo restores a manually replaced unchanged word');
command('redo'); api.flushForSave();
assert(A.getState().text === 'It is cheaper to use each day.', 'Redo restores a manually replaced unchanged word');

// Boundary carets stay in the proposal, never its hidden original or controls.
replace('<p>It is easier to use.</p>', '<p>It is cheaper to use.</p>');
let boundary = doc.querySelector('.chg > ins p');
doc.focus(); getSelection().setPosition(boundary.firstChild, 0);
command('insertText', 'Now '); api.flushForSave();
assert(A.getState().text === 'Now It is cheaper to use.', 'Typing at the start stays in the proposal');
command('undo'); api.flushForSave();
assert(A.getState().text === 'It is cheaper to use.', 'Undo at the start restores the proposal');

// Formatting a selection across a deletion changes only the proposal.
boundary = doc.querySelector('.chg > ins p');
doc.focus(); getSelection().selectAllChildren(boundary); api.format('bold');
assert(A.getState().text === 'It is cheaper to use.' && !api.getBlocks().blocks[0].html.includes('easier'), 'Formatting excludes inline deleted text');
api.reject({all: true});
assert(api.getBlocks().blocks[0].html === '<p>It is easier to use.</p>', 'Reject after formatting retains the untouched original');

// Leave the reported example in a realistic preview for screenshot inspection.
api.load('<h1>Inline tracked changes</h1>' + enterpriseBefore + '<p>Keep this redundant sentence.</p>');
const blocks = api.getBlocks().blocks;
api.applyEdits(1, [{op: 'replace', blockId: blocks[1].id, html: enterpriseAfter}, {op: 'replace', blockId: blocks[2].id, html: '<p>Keep this sentence.</p>'}], false);
doc.blur(); getSelection().removeAllRanges();
await new Promise(resolve => setTimeout(resolve, 1600));
document.querySelector('#scroll').scrollTop = 0;
return {passed: passed.length, checks: passed};
