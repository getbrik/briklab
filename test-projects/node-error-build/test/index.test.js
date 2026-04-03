const { add } = require('../src/index');
const assert = require('assert');
console.log('Running tests...');
assert.strictEqual(add(1, 2), 3);
console.log('  PASS: add(1, 2) should return 3');
