#!/usr/bin/env node
// Independent range-engine checks; no browser, network, or provider dependency.
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const {performance} = require('node:perf_hooks');
const context = vm.createContext({Date, Map, Set});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Sources/Margins/Resources/Editor/annotations.js'), 'utf8'), context);
const align = context.MarginsAnnotationAlignment;
let checks = 0;
function verify(a, b) {
  const result = align(a, b);
  let endA = 0, endB = 0, preserved = 0;
  for (const match of result.matches) {
    assert.ok(Number.isInteger(match.a) && Number.isInteger(match.b) && Number.isInteger(match.length));
    assert.ok(match.length > 0 && match.a >= endA && match.b >= endB, 'matches are monotonic and disjoint');
    assert.ok(match.a + match.length <= a.length && match.b + match.length <= b.length, 'matches are in UTF-16 bounds');
    assert.equal(a.slice(match.a, match.a + match.length), b.slice(match.b, match.b + match.length), 'only exactly unchanged text is preserved');
    endA = match.a + match.length; endB = match.b + match.length; preserved += match.length;
  }
  checks++; return {result, preserved};
}
function lcs(a, b) {
  let previous = new Uint16Array(b.length + 1);
  for (let i = 0; i < a.length; i++) {
    const next = new Uint16Array(b.length + 1);
    for (let j = 0; j < b.length; j++) next[j + 1] = a[i] === b[j] ? previous[j] + 1 : Math.max(previous[j + 1], next[j]);
    previous = next;
  }
  return previous[b.length];
}
let seed = 0xA771B;
const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 0x100000000; };
for (let sample = 0; sample < 2500; sample++) {
  let a = '', b = '';
  const size = 6 + Math.floor(random() * 22);
  for (let i = 0; i < size; i++) { if (random() < .8) a += 'abc xyz'[Math.floor(random() * 7)]; if (random() < .8) b += 'abc xyz'[Math.floor(random() * 7)]; }
  const value = verify(a, b);
  assert.equal(value.preserved, lcs(a, b), 'small alignments retain the maximal unchanged subsequence');
}
assert.equal(verify('The old draft stays here.', 'The useful draft stays here.').preserved, lcs('The old draft stays here.', 'The useful draft stays here.'));
assert.equal(verify('alpha beta', 'alpha\nbeta').preserved, 'alpha'.length + 'beta'.length, 'paragraph split keeps text on both sides');
assert.equal(verify('one\ntwo\nthree', 'one\nthree').preserved, 'one\nthree'.length, 'deleting a block retains its neighbors');
assert.equal(verify('A 🧭 route', 'A 🧭 better route').preserved, 'A 🧭 route'.length, 'unchanged astral characters use two UTF-16 units');
const replacedEmoji = verify('A 😊 route', 'A 😂 route');
assert.ok(!replacedEmoji.result.matches.some(match => match.a <= 2 && match.a + match.length > 2), 'changing an emoji does not preserve an isolated surrogate');
const huge = Array.from({length: 10000}, (_, i) => `Paragraph ${i}: the author can continue this draft.\n`).join('');
let started = performance.now();
assert.equal(verify(huge, huge).preserved, huge.length);
assert.ok(performance.now() - started < 1500, 'large no-op alignment stays linear');
const manyEdits = huge.replace(/Paragraph (\d*[02468]):/g, 'Passage $1:');
started = performance.now(); const bounded = verify(huge, manyEdits);
assert.ok(performance.now() - started < 3000, 'many distributed edits have a bounded fallback');
assert.ok(bounded.preserved > huge.length * .5, 'fallback retains substantial confidently unchanged text');
started = performance.now(); verify('a'.repeat(200000), 'b'.repeat(200000));
assert.ok(performance.now() - started < 1500, 'unrelated large inputs do not trigger quadratic work');
console.log(`PASS ${checks} attribution alignment cases (randomized LCS, Unicode, split/delete, and large-document bounds).`);
