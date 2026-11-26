#!/usr/bin/env node
// Unit checks for heading/formatting shortcuts and Markdown heading triggers.
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');

const context = vm.createContext({});
vm.runInContext(
  fs.readFileSync(path.join(__dirname, '../Sources/Margins/Resources/Editor/formatting.js'), 'utf8'),
  context
);
const {resolveShortcut, markdownHeadingCommand} = context.MarginsFormatting;

// Heading and body keyboard shortcuts (including macOS Option dead-key behavior via e.code).
assert.equal(resolveShortcut({metaKey: true, altKey: true, key: '¡', code: 'Digit1'}), 'h1');
assert.equal(resolveShortcut({metaKey: true, altKey: true, key: '™', code: 'Digit2'}), 'h2');
assert.equal(resolveShortcut({metaKey: true, altKey: true, key: '£', code: 'Digit3'}), 'h3');
assert.equal(resolveShortcut({metaKey: true, altKey: true, key: 'º', code: 'Digit0'}), 'removeFormat');
assert.equal(resolveShortcut({metaKey: true, shiftKey: true, key: ')', code: 'Digit0'}), 'paragraph');
assert.equal(resolveShortcut({metaKey: true, shiftKey: true, key: '0', code: 'Digit0'}), 'paragraph');
assert.equal(resolveShortcut({metaKey: true, altKey: true, shiftKey: true, key: '1', code: 'Digit1'}), null);

// Existing inline and list shortcuts remain intact.
assert.equal(resolveShortcut({metaKey: true, key: 'b'}), 'bold');
assert.equal(resolveShortcut({metaKey: true, key: 'i'}), 'italic');
assert.equal(resolveShortcut({metaKey: true, key: 'u'}), 'underline');
assert.equal(resolveShortcut({metaKey: true, shiftKey: true, key: '7'}), 'numbers');
assert.equal(resolveShortcut({metaKey: true, shiftKey: true, key: '*'}), 'bullets');
assert.equal(resolveShortcut({metaKey: true, shiftKey: true, key: '('}), 'checklist');
assert.equal(resolveShortcut({metaKey: true, shiftKey: true, key: 'X'}), 'toggleCheck');
assert.equal(resolveShortcut({metaKey: false, ctrlKey: false, key: 'b'}), null);

// Markdown heading typing prefixes before Space.
assert.equal(markdownHeadingCommand('#'), 'h1');
assert.equal(markdownHeadingCommand('##'), 'h2');
assert.equal(markdownHeadingCommand('###'), 'h3');
assert.equal(markdownHeadingCommand('####'), null);
assert.equal(markdownHeadingCommand('# '), null);
assert.equal(markdownHeadingCommand('text#'), null);
assert.equal(markdownHeadingCommand(''), null);

console.log('formatting checks passed');
