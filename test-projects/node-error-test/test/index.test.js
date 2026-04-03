const { add } = require('../src/index');
const assert = require('assert');

console.log('Running tests...');

// This test intentionally fails
assert.strictEqual(add(1, 2), 999, 'Intentional failure for E2E error testing');
