// Turns "what the phone's text field said before" and "what it says now" into the
// keystrokes needed to make the Mac's field match.
//
// The phone's field is a local mirror, not the source of truth. That is deliberate: iOS
// autocorrect and predictive text replace whole words at once rather than appending
// characters, so typing straight into a perpetually-cleared field would send garbage the
// moment autocorrect fired. Diffing against the previous contents handles insertions,
// backspaces, mid-word edits and whole-word replacements with the same code path.
//
// Pure and dependency-free so it can be tested without a browser.

'use strict';

/**
 * @param {string} previous  what the mirror held last time
 * @param {string} next      what it holds now
 * @returns {{backspaces: number, insert: string}}
 */
export function computeTypingDelta(previous, next) {
  if (previous === next) return { backspaces: 0, insert: '' };

  // Compare by code point, not by UTF-16 unit: splitting a surrogate pair would send half
  // an emoji and leave the two sides permanently out of step.
  const before = Array.from(previous);
  const after = Array.from(next);

  let common = 0;
  while (common < before.length && common < after.length && before[common] === after[common]) {
    common += 1;
  }

  return {
    backspaces: before.length - common,
    insert: after.slice(common).join(''),
  };
}

/**
 * Splits a backspace count into protocol-legal key_press repeats.
 * The wire protocol caps `repeat` at 10, so a long deletion becomes several messages.
 */
export function backspaceBatches(count, maxRepeat = 10) {
  const batches = [];
  let remaining = Math.max(0, count);
  while (remaining > 0) {
    const batch = Math.min(remaining, maxRepeat);
    batches.push(batch);
    remaining -= batch;
  }
  return batches;
}
