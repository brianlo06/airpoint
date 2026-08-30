#!/usr/bin/env node
// Checks the live-typing diff, including the cases iOS actually produces.
//
//   node tools/typing-check.mjs

import { computeTypingDelta, backspaceBatches }
  from '../Sources/RemoteServer/Resources/shared/typing.js';

let passed = 0;
let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) { passed += 1; console.log(`  ok    ${name}`); }
  else {
    failed += 1;
    console.log(`  FAIL  ${name}\n          got      ${JSON.stringify(actual)}\n          expected ${JSON.stringify(expected)}`);
  }
}

console.log('AirPoint typing diff check\n');

check('a plain keystroke', computeTypingDelta('the bea', 'the bear'),
  { backspaces: 0, insert: 'r' });
check('no change sends nothing', computeTypingDelta('hello', 'hello'),
  { backspaces: 0, insert: '' });
check('a single backspace', computeTypingDelta('hello', 'hell'),
  { backspaces: 1, insert: '' });
check('clearing the field', computeTypingDelta('hello', ''),
  { backspaces: 5, insert: '' });
check('typing into an empty field', computeTypingDelta('', 'hi'),
  { backspaces: 0, insert: 'hi' });

// The case that motivated diffing at all: autocorrect rewrites a whole word in one event.
check('autocorrect replacing a word', computeTypingDelta('teh bear', 'the bear'),
  { backspaces: 7, insert: 'he bear' });
check('predictive text completing a word', computeTypingDelta('net', 'netflix '),
  { backspaces: 0, insert: 'flix ' });
check('a mid-string edit', computeTypingDelta('season 3', 'season 4'),
  { backspaces: 1, insert: '4' });

// Emoji must not be split down the middle of a surrogate pair.
check('an emoji is inserted whole', computeTypingDelta('nice ', 'nice 👍'),
  { backspaces: 0, insert: '👍' });
check('deleting an emoji costs one backspace', computeTypingDelta('nice 👍', 'nice '),
  { backspaces: 1, insert: '' });

check('backspaces batch to the protocol limit', backspaceBatches(25), [10, 10, 5]);
check('no batches for nothing to delete', backspaceBatches(0), []);
check('a negative count is treated as zero', backspaceBatches(-3), []);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
