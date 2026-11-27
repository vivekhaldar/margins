#!/usr/bin/env node
// Unit checks for Zen Mode's pure helpers (word counting). DOM behavior is covered by
// scripts/test-editor-zen.swift on macOS.
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');

const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Sources/Margins/Resources/Editor/zen.js'), 'utf8'), context);
const {countWords, formatWords} = context.MarginsZen;

assert.equal(countWords(''), 0);
assert.equal(countWords('   \n\t '), 0);
assert.equal(countWords('Hello world'), 2);
assert.equal(countWords('One — two – three'), 3, 'dashes are not words');
assert.equal(countWords('It\u2019s 2026, café déjà-vu!'), 4, 'Unicode letters, digits, and punctuation');
assert.equal(countWords('日本語 テキスト'), 2);
assert.equal(countWords(' • ✓ ☐ '), 0, 'list glyphs are not words');
assert.equal(formatWords(1), '1 word');
assert.equal(formatWords(1482), '1,482 words');

console.log('zen checks passed');
