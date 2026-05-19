import { test } from 'node:test';
import assert from 'node:assert/strict';
import { greet } from '../src/index.js';

test('greet', () => {
  assert.equal(greet('web'), 'hello, web');
});
