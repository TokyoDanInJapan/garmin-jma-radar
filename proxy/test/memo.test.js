import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { Lru } from "../src/memo.js";

test("Lru drops the least recently used entry when full", () => {
  const lru = new Lru(2);
  lru.set("a", 1);
  lru.set("b", 2);
  assert.equal(lru.get("a"), 1); // a is now the most recent
  lru.set("c", 3);
  assert.equal(lru.get("b"), undefined);
  assert.equal(lru.get("a"), 1);
  assert.equal(lru.get("c"), 3);
});

test("Lru entries expire after their time to live", () => {
  let now = 1000;
  mock.method(Date, "now", () => now);
  try {
    const lru = new Lru(4, 500);
    lru.set("a", null);
    assert.equal(lru.get("a"), null); // a stored null is a hit, not a miss
    now += 501;
    assert.equal(lru.get("a"), undefined);
  } finally {
    mock.restoreAll();
  }
});
