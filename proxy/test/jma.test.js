import { test } from "node:test";
import assert from "node:assert/strict";
import { parseJmaTime, formatJmaTime, radarTileURL, jstLabel } from "../src/jma.js";

test("radarTileURL builds the JMA hrpns nowcast path from z/x/y + times", () => {
  const u = radarTileURL({ z: 10, x: 909, y: 403, basetime: "20260627120000", validtime: "20260627123000" });
  assert.equal(
    u,
    "https://www.jma.go.jp/bosai/jmatile/data/nowc/20260627120000/none/20260627123000/surf/hrpns/10/909/403.png"
  );
});

test("parse/format round-trips a JMA UTC timestamp", () => {
  assert.equal(formatJmaTime(parseJmaTime("20260624131500")), "20260624131500");
});

test("jstLabel converts UTC validtime to a JST clock label", () => {
  assert.equal(jstLabel("20260618135000"), "22:50"); // 13:50 UTC + 9h
  assert.equal(jstLabel("20260618200000"), "05:00"); // wraps past midnight
  assert.equal(jstLabel("20260618000000"), "09:00");
});

test("offset arithmetic rolls across the hour and the day", () => {
  const base = parseJmaTime("20260624131500");
  // -30 min within the hour
  assert.equal(formatJmaTime(base - 30 * 60000), "20260624124500");
  // +60 min crosses the hour
  assert.equal(formatJmaTime(base + 60 * 60000), "20260624141500");
  // crossing midnight UTC
  const late = parseJmaTime("20260624234500");
  assert.equal(formatJmaTime(late + 30 * 60000), "20260625001500");
});
