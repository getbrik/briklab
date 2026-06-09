const { add } = require('../src/index');
const assert = require('assert');

let passed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  PASS: ${name}`);
    passed++;
  } catch (e) {
    console.error(`  FAIL: ${name} - ${e.message}`);
    process.exit(1);
  }
}

console.log('Running tests...\n');
test('add(1, 2) should return 3', () => assert.strictEqual(add(1, 2), 3));
console.log(`\nResults: ${passed} passed`);
