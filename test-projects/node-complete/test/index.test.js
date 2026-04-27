const { add, multiply } = require('../src/index');

describe('add', () => {
  test('add(1, 2) returns 3', () => {
    expect(add(1, 2)).toBe(3);
  });

  test('add(0, 0) returns 0', () => {
    expect(add(0, 0)).toBe(0);
  });

  test('add(-1, 1) returns 0', () => {
    expect(add(-1, 1)).toBe(0);
  });
});

describe('multiply', () => {
  test('multiply(2, 3) returns 6', () => {
    expect(multiply(2, 3)).toBe(6);
  });

  test('multiply(0, 5) returns 0', () => {
    expect(multiply(0, 5)).toBe(0);
  });
});
