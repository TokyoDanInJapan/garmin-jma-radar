import { test } from "node:test";
import assert from "node:assert/strict";
import { baseTileURL } from "../src/basemap.js";

test("baseTileURL builds the GSI-mirror path and defaults to the english style", () => {
  assert.equal(
    baseTileURL({ z: 10, x: 909, y: 403 }),
    "https://www.jma.go.jp/tile/gsi/english/10/909/403.png"
  );
});

test("baseTileURL honours an explicit style", () => {
  assert.equal(
    baseTileURL({ z: 8, x: 1, y: 2, style: "pale" }),
    "https://www.jma.go.jp/tile/gsi/pale/8/1/2.png"
  );
});
