// Runs inside the actual editor WKWebView. This fixture never calls an AI service.
return await (async () => {
  const api = window.margins, A = window.MarginsAnnotations, doc = document.querySelector('#doc');
  const passed = [];
  const asyncErrors = []; window.addEventListener("error",event=>asyncErrors.push(event.message));
  window.addEventListener("unhandledrejection",event=>asyncErrors.push(String(event.reason)));
  const assert = (value, message, details) => { if (!value) throw new Error(message + (details ? ': ' + JSON.stringify(details()) : '')); passed.push(message); };
  const settle = async () => {
    await new Promise(resolve => setTimeout(resolve,80));
    await new Promise((resolve,reject) => {
      const timeout = setTimeout(() => reject(new Error('WebKit did not render two animation frames within two seconds')),2000);
      requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(timeout); resolve(); }));
    });
  };
  const clone = value => JSON.parse(JSON.stringify(value));
  const select = (element, start = 0, end = element.textContent.length) => {
    doc.focus();
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    const locate = offset => { for (const node of nodes) { if (offset <= node.length) return [node, offset]; offset -= node.length; } return [element, element.childNodes.length]; };
    const r = document.createRange(); r.setStart(...locate(start)); r.setEnd(...locate(end));
    const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    document.dispatchEvent(new Event('selectionchange'));
    return A.getSelection();
  };
  const type = value => { doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,cancelable:true,inputType:'insertText',data:value})); document.execCommand('insertText',false,value); };
  const selectedOrigin = origin => {
    const s = A.getSelection();
    return A.getState().spans.some(p => p.origin === origin && p.start < s.end && p.end > s.start);
  };
  const apply = (step, edits, direct, runId) => api.applyEdits(step, edits, direct, {runId, expectedRevision:api.getBlocks().revision});
  const run1 = '11111111-1111-4111-8111-111111111111', run2 = '22222222-2222-4222-8222-222222222222', run3 = '33333333-3333-4333-8333-333333333333';
  const runs = [
    {id:run1,intentId:run1,step:1,instruction:'Explain how Margins helps me continue a draft.',provider:'Verification fixture',model:'deterministic fixture',createdAt:'2026-10-17T12:00:00Z',summary:'Drafted a passage about continuing the work.',notes:['Local test fixture; no provider request.'],status:'done',steps:[{id:'read',kind:'read',title:'Read the draft',detail:'Read the current document context.',status:'done'}],files:['docs/07-annotations.md']},
    {id:run2,intentId:run2,step:2,instruction:'Make the passage more specific.',provider:'Verification fixture',model:'deterministic fixture',createdAt:'2026-10-17T12:01:00Z',summary:'Made the description more specific.',notes:[],status:'done',steps:[]},
    {id:run3,intentId:run2,step:2,instruction:'Make the passage more specific.',refinement:'Use simpler words.',parentRunId:run2,provider:'Verification fixture',model:'deterministic fixture',createdAt:'2026-10-17T12:02:00Z',summary:'Simplified the proposal.',notes:[],status:'done',steps:[]}
  ];
  assert(!!A && !!api.snapshot, 'Annotation engine and atomic snapshot API load in WebKit');
  api.load('<p>Legacy text without metadata.</p>');
  assert(A.getState().spans.every(s => s.origin === 'unattributed'), 'Legacy text starts unattributed');
  api.load(''); api.setAnnotationRuns(runs);
  apply(1,[{op:'insertAfter',blockId:'^',html:'<h1>A place to continue</h1><p>Agents can make a draft easier to continue.</p>'}],true,run1);
  await settle();
  assert(!document.querySelector('#annotation-toggle').checked, 'New document starts with overlay off');
  assert(A.getState().spans.some(s => s.origin === 'agent' && s.runId === run1), 'Direct first draft captures provenance while overlay is off');
  const first = clone(api.snapshot());
  let p = doc.querySelector('p');
  select(p,p.textContent.indexOf('draft'),p.textContent.indexOf('draft')+5); A.addComment('Can we make this more concrete?');
  let comment = A.getState().comments.at(-1);
  assert(comment && !comment.detached, 'Selected text anchors a local comment');
  const commentID = comment.id;
  A.replyComment(commentID,'Keep the author in control.');
  A.updateComment(commentID,'Give one concrete example.');
  A.resolveComment(commentID,true);
  assert(A.getState().comments.find(c=>c.id===commentID).resolved, 'Comments support editing, replies and resolve');
  A.resolveComment(commentID,false);
  assert(!A.getState().comments.find(c=>c.id===commentID).resolved, 'Resolved comments can reopen');
  select(p,p.textContent.indexOf('draft'),p.textContent.indexOf('draft')+5); type('useful draft'); await settle();
  p = doc.querySelector('p'); select(p,p.textContent.indexOf('useful'),p.textContent.indexOf('useful')+6);
  assert(selectedOrigin('author'), 'Manual insertion changes only its range to author-origin');
  select(p,0,6);
  assert(selectedOrigin('agent'), 'Untouched text retains its agent origin');
  const mixed = clone(api.snapshot());
  select(p); api.format('bold'); await settle();
  select(doc.querySelector('p'),0,6);
  assert(selectedOrigin('agent'), 'Formatting preserves attribution');
  const formatted = clone(api.snapshot());
  api.load(formatted.html,formatted.annotations); api.setAnnotationRuns(runs); await settle();
  assert(A.getState().comments.some(c=>c.id===commentID), 'Save and reopen preserve local comment threads');
  select(doc.querySelector('p'),18,24);
  assert(selectedOrigin('author'), 'Save and reopen preserve mixed attribution');
  const blockId = api.getBlocks().blocks.find(b=>b.html.includes('Agents')).id;
  apply(2,[{op:'replace',blockId,html:'<p>Agents can make a useful draft easier to continue with care.</p>'}],false,run2);
  assert(A.getState().spans.some(s=>s.origin==='agent'&&s.runId===run2), 'Tracked replacement records provisional new-run attribution');
  const pending = clone(api.snapshot());
  api.load(pending.html,pending.annotations); api.setAnnotationRuns(runs);
  api.reject({all:true}); api.flushForSave(); await settle();
  select(doc.querySelector('p'),18,24);
  assert(selectedOrigin('author'), 'Reject after reopen restores the original mixed attribution');
  apply(2,[{op:'replace',blockId,html:'<p>Agents can make a useful draft easier to continue with care.</p>'}],false,run2);
  const cid = doc.querySelector('.chg').dataset.cid;
  const ctx = api.refineContext(cid);
  api.applyRefinement(cid,'<p>Agents can make a useful draft easier to continue with a clear next step.</p>',1,{runId:run3,expectedRevision:ctx.revision});
  assert(A.getState().spans.some(s=>s.runId===run3), 'Refinement creates attribution linked to its own run');
  api.accept({all:true}); api.flushForSave(); await settle();
  assert(A.getState().spans.some(s=>s.runId===run3), 'Accept preserves agent attribution');
  const current = clone(api.snapshot());
  api.preview(first.html,first.annotations); await settle();
  assert(doc.contentEditable==='false' && !A.getState().comments.length, 'History preview shows its historical annotation state read-only');
  api.endPreview(); await settle();
  assert(A.getState().comments.length===current.annotations.comments.length, 'Returning from preview restores current comments');
  const revision = api.getBlocks().revision;
  select(doc.querySelector('p'),0,0); type('Now '); await settle();
  const beforeStale = api.html();
  let stale; try { stale=api.applyEdits(9,[{op:'replace',blockId,html:'<p>Wrong stale response</p>'}],false,{runId:run2,expectedRevision:revision}); } catch(error) { stale={conflict:true}; }
  assert((stale.conflict||stale.error==='revision-conflict')&&api.html()===beforeStale, 'Stale agent response is refused without overwriting manual edits');
  const formattingRevision = api.getBlocks().revision;
  select(doc.querySelector('p'),0,3); api.format('bold');
  const beforeStaleFormatting = api.html();
  const staleFormatting = api.applyEdits(9,[{op:'replace',blockId,html:'<p>Wrong stale formatting response</p>'}],false,{runId:run2,expectedRevision:formattingRevision});
  assert(staleFormatting.conflict&&api.html()===beforeStaleFormatting, 'Stale agent response is refused after a formatting-only author edit');
  const imageRevision = api.getBlocks().revision;
  const image = document.createElement('img'); image.src='data:image/png;base64,iVBORw0KGgo='; doc.querySelector('p').append(image);
  const beforeStaleImage = api.html();
  const staleImage = api.applyEdits(9,[{op:'replace',blockId,html:'<p>Wrong stale image response</p>'}],false,{runId:run2,expectedRevision:imageRevision});
  assert(staleImage.conflict&&api.html()===beforeStaleImage, 'Stale agent response is refused after an image-only author edit');
  // Comment deletion and explicit reattachment.
  select(doc.querySelector('p'),0,3); A.addComment('This opening needs work.');
  const removedID=A.getState().comments.at(-1).id;
  select(doc.querySelector('p')); type('Replacement with no matching quotation.'); await settle();
  assert(A.getState().comments.find(c=>c.id===removedID).detached, 'Deleting an anchored passage detaches and retains the comment');
  select(doc.querySelector('p'),0,11); A.reattachComment(removedID);
  assert(!A.getState().comments.find(c=>c.id===removedID).detached, 'Detached comment can be reattached to a fresh selection');
  A.deleteComment(removedID);
  assert(!A.getState().comments.some(c=>c.id===removedID), 'Explicit deletion removes the local comment');
  // Unicode and multi-block anchors use the same UTF-16 representation on both sides of save/reopen.
  api.load('<p>🧭 alpha</p><ul><li>beta</li><li>gamma</li></ul><table><tbody><tr><td>delta</td><td>epsilon</td></tr></tbody></table>');
  const r=document.createRange();r.setStart(doc.querySelector('p').firstChild,0);r.setEnd(doc.querySelector('td').firstChild,3);getSelection().removeAllRanges();getSelection().addRange(r);
  A.addComment('A note spanning emoji, a list and a table.');
  const multi=clone(api.snapshot()); api.load(multi.html,multi.annotations);
  assert(A.getState().comments.length===1&&!A.getState().comments[0].detached, 'Multi-block comment across emoji, list and table survives reopening');
  assert(!api.getBlocks().blocks.some(b=>b.html.includes('A note spanning')), 'Local comments remain outside the prompt HTML');
  assert(!api.html().includes('annotation-highlight')&&!api.html().includes('A note spanning'), 'Overlay and comments never pollute saved prose');
  assert((window.__marginsLog||[]).every(m=>m.type!=='ask'), 'All local comment actions make no agent request');

  // Repeated text is not permission to steal an anchor from a removed paragraph.
  api.load('<p>Repeated quotation.</p><p>Repeated quotation.</p>');
  select(doc.querySelector('p')); A.addComment('Only the first quotation.');
  const repeatID=A.getState().comments[0].id;
  const repeatBID=api.getBlocks().blocks[0].id;
  apply(4,[{op:'delete',blockId:repeatBID,html:''}],false,run2);
  api.reject({all:true}); api.flushForSave();
  assert(!A.getState().comments[0].detached,'Rejecting deletion preserves the original comment anchor');
  apply(4,[{op:'delete',blockId:repeatBID,html:''}],false,run2);
  api.accept({all:true}); api.flushForSave();
  assert(A.getState().comments[0].detached,'Deleting one repeated quotation never attaches its comment to another');
  // Native typing, identical replacement, and undo/redo.
  api.load(first.html,first.annotations); api.setAnnotationRuns(runs);
  p=doc.querySelector('p'); select(p); type(p.textContent); await settle();
  assert(A.getState().spans.filter(s=>s.blockId===p.dataset.bid).every(s=>s.origin==='author'),'Typing an identical replacement is still author-origin');
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'historyUndo'})); document.execCommand('undo'); await settle();
  select(doc.querySelector('p'));
  assert(selectedOrigin('agent'),'Undo restores the earlier agent attribution');
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'historyRedo'})); document.execCommand('redo'); await settle();
  select(doc.querySelector('p'));
  assert(selectedOrigin('author'),'Redo restores the manual replacement attribution');
  // Both public clipboard forms stay clean. Internal transfer carries structured provenance.
  api.load(first.html,first.annotations); api.setAnnotationRuns(runs);
  select(doc.querySelector('p'));
  const clipboard=new DataTransfer();doc.dispatchEvent(new ClipboardEvent('copy',{bubbles:true,cancelable:true,clipboardData:clipboard}));
  assert(!!clipboard.getData('application/x-margins-attribution+json')&&!clipboard.getData('text/html').includes('data-bid'),'Internal copy carries provenance separately from clean HTML');
  select(doc.querySelector('p'));
  doc.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:clipboard}));
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertFromPaste'}));document.execCommand('insertHTML',false,clipboard.getData('text/html'));await settle();
  select(doc.querySelector('p'));
  assert(selectedOrigin('agent'),'Internal paste preserves originating run attribution');
  const external=new DataTransfer();external.setData('text/plain',doc.querySelector('p').textContent);
  select(doc.querySelector('p'));doc.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:external}));
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertFromPaste'}));document.execCommand('insertText',false,external.getData('text/plain'));await settle();
  select(doc.querySelector('p'));
  const pasteSelection=A.getSelection();
  assert(A.getState().spans.filter(s=>s.start<pasteSelection.end&&s.end>pasteSelection.start).every(s=>s.origin==='pasted'),'External paste of identical prose has unknown pasted origin');
  // Splitting and merging preserve the provenance of the surviving text.
  api.load(first.html,first.annotations);api.setAnnotationRuns(runs);p=doc.querySelector('p');select(p,17,17);
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertParagraph'}));document.execCommand('insertParagraph');await settle();
  assert(doc.querySelectorAll('p').length===2&&A.getState().spans.filter(s=>A.getState().text.slice(s.start,s.end).trim()).every(s=>s.origin==='agent'),'Splitting a paragraph preserves its surviving text attribution');
  const split=clone(api.snapshot());api.load(split.html,split.annotations);select(doc.querySelectorAll('p')[1],0,0);
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'deleteContentBackward'}));document.execCommand('delete');await settle();
  assert(A.getState().spans.filter(s=>A.getState().text.slice(s.start,s.end).trim()).every(s=>s.origin==='agent'),'Merging paragraphs preserves surviving attribution');
  api.load('');api.setAnnotationRuns(runs);apply(1,[{op:'insertAfter',blockId:'^',html:'<p>abc abc</p>'}],true,run1);
  p=doc.querySelector('p');select(p,4,7);type('abc');await settle();select(p,0,4);
  doc.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'deleteContentForward'}));document.execCommand('delete');await settle();
  assert(doc.querySelector('p').textContent==='abc'&&A.getState().spans.every(s=>s.origin==='author'),'Deleting repeated text preserves the surviving occurrence origin');
  api.load(first.html,first.annotations);api.setAnnotationRuns(runs);
  const reviewBID=api.getBlocks().blocks.find(b=>b.html.includes('Agents')).id;
  apply(5,[{op:'replace',blockId:reviewBID,html:'<p>An accepted live passage.</p>'}],false,run2);api.accept({all:true});
  api.preview(first.html,first.annotations);await new Promise(resolve=>setTimeout(resolve,750));
  const review=(window.__marginsLog||[]).filter(m=>m.type==='reviewed').at(-1);
  assert(review.html.includes('An accepted live passage.')&&api.snapshot().html.includes('An accepted live passage.'),'Immediate history preview never saves historical HTML as the live review');
  api.endPreview();
  api.load(first.html,first.annotations);A.history=[];A.future=[];
  doc.querySelector('p').textContent='Older restored text outside the retained metadata history.';A.sync({history:'undo',silent:true});
  assert(A.getState().spans.some(s=>s.origin==='uncertain')&&!A.getState().spans.some(s=>s.origin==='author'),'Undo beyond retained metadata marks unknown restored text uncertain');
  // Actual UI controls, independent from the text range engine.
  api.load(mixed.html,mixed.annotations);api.setAnnotationRuns(runs);await settle();
  const toggle=document.querySelector('#annotation-toggle'),ui=window.MarginsAnnotationUI;
  if(!toggle.checked)toggle.click();await settle();
  assert(document.querySelectorAll('.annotation-highlight').length>0&&document.querySelectorAll('.annotation-marker').length>0,'Enabled overlay paints text highlights and labeled margin markers', () => ({enabled:ui.isEnabled(), checked:toggle.checked, spans:A.getState().spans, scroll:document.querySelector('#scroll').getBoundingClientRect().toJSON(), doc:doc.getBoundingClientRect().toJSON(), rangeRects:A.getRects(0,5), errors:asyncErrors}));
  const cleanHTML=api.html();toggle.click();await settle();
  assert(document.querySelector('#annotation-layer').hidden&&document.querySelector('#annotation-card').hidden&&api.html()===cleanHTML,'Hiding the overlay hides cards and markers without changing prose');
  select(doc.querySelector('p'),0,6);document.querySelector('#commentchip').click();await settle();
  assert(toggle.checked&&!document.querySelector('#annotation-card').hidden,'Selection Comment action opens local composer and reveals overlay');
  const composer=document.querySelector('#annotation-composer');composer.value='A comment saved using the actual toolbar.';
  document.querySelector('#annotation-save').click();await settle();
  assert(A.getState().comments.some(c=>c.body==='A comment saved using the actual toolbar.'),'Comment composer saves a local thread');
  ui.showRun(run2);await settle();
  assert(document.querySelector('#annotation-card-content').textContent.includes('No tool activity was recorded'),'Unavailable activity is reported honestly');
  ui.showRun(run1);await settle();
  Array.from(document.querySelectorAll('#annotation-card button')).find(b=>b.textContent==='Show in instructions').click();
  assert((window.__marginsLog||[]).some(m=>m.type==='showIntent'&&m.step===1),'Provenance card reveals the matching native instruction');
  ui.showList();await settle();const filter=document.querySelector('#annotation-filter');filter.value='resolved';filter.dispatchEvent(new Event('change'));
  assert(document.querySelector('#annotation-items').textContent.includes('No annotations'),'Annotation browser filters resolved threads');
  const historic=clone(api.snapshot());api.preview(historic.html,historic.annotations);await settle();
  ui.showComment(commentID);await settle();
  assert(document.querySelector('#annotation-card-content').textContent.includes('read only')&&!document.querySelector('#annotation-composer'),'Historical comments can be inspected without mutation controls');
  assert(document.querySelectorAll('.annotation-highlight').length>0,'Historical overlay displays the version attribution');
  api.endPreview();ui.close();await settle();
  assert(!asyncErrors.length,'Overlay callbacks complete without asynchronous JavaScript errors');

  const started=performance.now();
  api.load('');api.setAnnotationRuns(runs);
  apply(1,[{op:'insertAfter',blockId:'^',html:Array.from({length:240},(_,i)=>'<p>Passage '+i+': a draft with sources and room for careful revision.</p>').join('')}],true,run1);
  for(let i=0;i<40;i++){select(doc.querySelectorAll('p')[i*6],0,9);A.addComment('Long-document note '+i);}
  ui.setEnabled(true);document.querySelector('#scroll').scrollTop=0;await settle();
  assert(A.getState().comments.length===40&&document.querySelectorAll('.annotation-marker').length>0,'Long document renders visible attribution and forty local comment anchors');
  document.querySelector('#scroll').scrollTop=document.querySelector('#scroll').scrollHeight;await settle();
  assert(document.querySelectorAll('.annotation-marker').length>0&&performance.now()-started<12000,'Overlay follows long-document scrolling within the bounded verification budget');
  assert(!asyncErrors.length,'Long-document overlay has no asynchronous JavaScript errors');

  window.annotationDemo = async view => {
    api.load(mixed.html,mixed.annotations); api.setAnnotationRuns(runs);
    api.setOutline(false);document.querySelector('#scroll').scrollTop=0;
    const toggle=document.querySelector('#annotation-toggle');
    if(!toggle.checked)toggle.click();
    await settle();
    if(view==='provenance')window.MarginsAnnotationUI.showRun(run1);
    if(view==='comment')window.MarginsAnnotationUI.showComment(commentID);
    if(view==='mixed')window.MarginsAnnotationUI.close();
    if(view==='history'){api.preview(mixed.html,mixed.annotations);window.MarginsAnnotationUI.showComment(commentID);}
    await settle();
    return true;
  };
  return {demo:{html:mixed.html,annotations:mixed.annotations,runs},passed:passed.length,checks:passed,fixture:'Deterministic editor fixture; no network provider request'};
})();
