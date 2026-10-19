// Runs in the real WebKit editor; no provider request is made.
const api = window.margins, doc = document.querySelector('#doc'), A = window.MarginsAnnotations;
const passed = [];
const assert = (value, message) => { if (!value) throw new Error(message); passed.push(message); };
const runA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', runB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const options = (snapshot, runId = runA) => ({expectedRevision: snapshot.revision, blockStates: snapshot.blockStates, runId});
const replace = (id, text) => ({op: 'replace', blockId: id, html: `<p>${text}</p>`});
const caret = el => { doc.focus(); getSelection().setPosition(el, el.childNodes.length); };
const type = text => document.execCommand('insertText', false, text);
const setup = () => {
  api.load('<p>First rough prompt.</p><p>Second rough prompt.</p><p>My continuing draft.</p>');
  return api.getBlocks();
};
const unchangedAfterConflict = (result, html, message) => assert(result.conflict && api.html() === html, message);

// Independent results can finish in either order while the author keeps typing.
for (const order of [[0, 1], [1, 0]]) {
  const snapshot = setup(), ids = snapshot.blocks.map(b => b.id);
  api.setParagraphWorking(10, ids[0]); api.setParagraphWorking(11, ids[1]);
  const writing = doc.lastElementChild;
  caret(writing); type(' More thoughts.');
  const node = getSelection().anchorNode, offset = getSelection().anchorOffset;
  let scrolls = 0;
  const scrollIntoView = Element.prototype.scrollIntoView;
  Element.prototype.scrollIntoView = () => { scrolls++; };
  try {
    for (const index of order) {
      const result = api.applyEdits(10 + index, [replace(ids[index], `Finished answer ${index + 1}.`)], false,
        options(snapshot, index ? runB : runA));
      assert(!result.conflict && result.changes === 1, `Parallel paragraph ${index + 1} applies in order ${order}`);
      api.setParagraphWorking(10 + index, null);
    }
  } finally { Element.prototype.scrollIntoView = scrollIntoView; }
  assert(doc.querySelectorAll(':scope > .chg').length === 2, 'Both parallel answers remain independently reviewable');
  assert(getSelection().anchorNode === node && getSelection().anchorOffset === offset && document.activeElement === doc,
    'Parallel completions preserve the typing caret and focus');
  assert(scrolls === 0, 'Background completions do not scroll away from the author');
  type(' Still writing.'); api.flushForSave();
  assert(writing.textContent === 'My continuing draft. More thoughts. Still writing.', 'Typing continues after both agent results');
  const spans = A.getState().spans;
  assert([runA, runB].every(runId => spans.some(s => s.origin === 'agent' && s.runId === runId)),
    'Parallel results retain distinct agent provenance');
  assert(spans.some(s => s.origin === 'author' && s.blockId === ids[2]), 'Concurrent typing retains author provenance');
  assert(!doc.querySelector('.paragraph-working'), 'All completed paragraph markers clear');
}

let snapshot = setup(), ids = snapshot.blocks.map(b => b.id);
api.applyEdits(1, [replace(ids[0], 'First answer.')], false, options(snapshot));
api.accept({all: true}); api.flushForSave();
assert(!api.applyEdits(2, [replace(ids[1], 'Second answer.')], false, options(snapshot, runB)).conflict,
  'Reviewing an unrelated result does not invalidate another run');
let before = api.html();
unchangedAfterConflict(api.applyEdits(3, [replace(ids[1], 'Overlapping answer.')], false, options(snapshot)), before,
  'Two runs on the same paragraph cannot overwrite each other');

for (const mutation of ['text', 'format', 'image', 'delete']) {
  snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
  const target = doc.firstElementChild;
  if (mutation === 'text') { caret(target); type(' Manual change.'); }
  if (mutation === 'format') target.innerHTML = '<strong>First rough prompt.</strong>';
  if (mutation === 'image') { const img = document.createElement('img'); img.src = 'margins-asset://img/fixture.png'; target.append(img); }
  if (mutation === 'delete') target.remove();
  before = api.html();
  unchangedAfterConflict(api.applyEdits(3, [replace(ids[1], 'Must not partially apply.'), replace(ids[0], 'Stale answer.')], false,
    options(snapshot)), before, `Target ${mutation} change rejects the entire plan atomically`);
}

snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
caret(doc.lastElementChild); type(' More context.');
assert(!api.applyEdits(1, [{op: 'delete', blockId: ids[0], html: ''}], false, options(snapshot)).conflict,
  'Deletion of an unchanged block survives unrelated typing');

snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
caret(doc.lastElementChild); type(' More context.');
assert(!api.applyEdits(1, [{op: 'insertAfter', blockId: ids[0], html: '<p>New passage.</p>'}], false, options(snapshot)).conflict,
  'Insertion at an unchanged anchor survives unrelated typing');
caret(doc.querySelector(`[data-bid="${ids[0]}"]`)); type(' Changed anchor.'); before = api.html();
unchangedAfterConflict(api.applyEdits(2, [{op: 'insertAfter', blockId: ids[0], html: '<p>Stale insertion.</p>'}], false,
  options(snapshot)), before, 'A changed insertion anchor is protected');
assert(!api.applyEdits(3, [{op: 'insertAfter', blockId: '^', html: '<h1>New heading</h1>'}], false, options(snapshot)).conflict,
  'Insertion at the document start survives unrelated typing');

for (const review of ['accept', 'reject']) {
  snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
  api.applyEdits(1, [replace(ids[0], 'Pending answer.')], false, options(snapshot));
  const pending = api.getBlocks();
  api[review]({all: true}); api.flushForSave(); before = api.html();
  unchangedAfterConflict(api.applyEdits(2, [replace(ids[0], 'Stale pending replacement.')], false, options(pending)), before,
    `${review} of a targeted pending change invalidates the older result`);
}

snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
api.applyEdits(1, [replace(ids[0], 'Pending answer.')], false, options(snapshot));
let cid = doc.querySelector('.chg').dataset.cid, ctx = api.refineContext(cid);
caret(doc.lastElementChild); type(' While refining.');
assert(!api.applyRefinement(cid, '<p>Refined answer.</p>', 1, options(ctx, runB)).conflict,
  'Refinement survives typing in a different paragraph');
before = api.html();
unchangedAfterConflict(api.applyRefinement(cid, '<p>Stale refinement.</p>', 2, options(ctx)), before,
  'Overlapping refinements cannot overwrite newer proposals');
ctx = api.refineContext(cid);
doc.querySelector('.chg > del p').textContent += ' Changed original.'; before = api.html();
unchangedAfterConflict(api.applyRefinement(cid, '<p>Stale original.</p>', 2, options(ctx)), before,
  'Refinement validates the original side as well as the proposal');

snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
const target = doc.firstElementChild, range = document.createRange(); range.selectNodeContents(target);
getSelection().removeAllRanges(); getSelection().addRange(range); A.addComment('Keep this evidence.');
assert(!api.applyEdits(1, [replace(ids[0], 'First rough prompt. A finished answer.')], false, options(snapshot)).conflict,
  'Adding a local comment does not invalidate an unchanged target');
assert(A.getState().comments.some(c => c.body === 'Keep this evidence.'), 'Applying the result preserves the local comment');

api.load(''); snapshot = api.getBlocks(); caret(doc); type('My new draft.'); before = api.html();
unchangedAfterConflict(api.applyEdits(1, [{op: 'insertAfter', blockId: '^', html: '<p>Outdated first draft.</p>'}], true,
  options(snapshot)), before, 'First drafts retain protection when the formerly blank document changes');
assert(!api.applyEdits(2, [], false, options(snapshot)).conflict, 'A response without edits is safe after document changes');

snapshot = setup(); ids = snapshot.blocks.map(b => b.id);
caret(doc.lastElementChild); type(' Legacy caller.'); before = api.html();
unchangedAfterConflict(api.applyEdits(1, [replace(ids[0], 'Legacy stale result.')], false, {expectedRevision: snapshot.revision}), before,
  'Callers without block snapshots retain strict revision protection');
return {passed: passed.length, checks: passed};
