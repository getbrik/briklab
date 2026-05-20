const { add } = require("../src/index");
const assert = require("assert");

assert.strictEqual(add(1, 2), 3);
console.log("PASS: add(1, 2) === 3");
