import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createReportsServer } from "./server.mjs";
import { createRateLimiter } from "./ratelimit.mjs";
import { FEATURES, validateReport } from "./validate.mjs";

const NOW = new Date("2026-11-22T06:00:00.000Z");

const BASE = {
  day: "2026-11-21",
  app: "0.2.0",
  build: "42",
  engine: "0.54.0",
  macos: "15.3.1",
};

async function withServer(options, fn) {
  const server = createReportsServer({ now: () => NOW, logError: () => {}, ...options });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  const baseUrl = `http://127.0.0.1:${port}`;
  try {
    await fn(baseUrl);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test("validateReport accepts valid crash, engine-exit, and usage payloads", () => {
  const crash = validateReport({ ...BASE, kind: "crash", signal: 11, frames: ["0x1a2b", "0xdeadbeef"] }, NOW);
  assert.equal(crash.ok, true);
  assert.deepEqual(crash.row, {
    received_at: NOW.toISOString(),
    kind: "crash",
    ...BASE,
    signal: 11,
    frames: ["0x1a2b", "0xdeadbeef"],
    status: null,
    counts: [],
  });

  const engineExit = validateReport({ ...BASE, kind: "engine-exit", status: 134 }, NOW);
  assert.equal(engineExit.ok, true);
  assert.equal(engineExit.row.status, 134);
  assert.equal(engineExit.row.signal, null);

  const usage = validateReport(
    { ...BASE, kind: "usage", counts: { screenshot: 3, apkOpened: 1 } },
    NOW,
  );
  assert.equal(usage.ok, true);
  assert.deepEqual(usage.row.counts, [
    { feature: "apkOpened", count: 1 },
    { feature: "screenshot", count: 3 },
  ]);
});

test("validateReport rejects extra fields, unknown features, excluded statuses, and malformed inputs", () => {
  assert.equal(
    validateReport({ ...BASE, kind: "crash", signal: 11, frames: [], apk: "secret.apk" }, NOW).ok,
    false,
  );
  assert.equal(
    validateReport({ ...BASE, kind: "crash", signal: 11, frames: [], counts: { apkOpened: 1 } }, NOW).ok,
    false,
  );
  assert.equal(
    validateReport({ ...BASE, kind: "usage", counts: { notAFeature: 1 } }, NOW).ok,
    false,
  );
  assert.equal(
    validateReport({ ...BASE, kind: "usage", counts: {} }, NOW).ok,
    false,
  );
  assert.equal(
    validateReport({ ...BASE, kind: "usage", counts: { apkOpened: 0 } }, NOW).ok,
    false,
  );
  // Status 10 is the tested Android app's crash and must never be stored.
  assert.equal(validateReport({ ...BASE, kind: "engine-exit", status: 10 }, NOW).ok, false);
  assert.equal(validateReport({ ...BASE, kind: "engine-exit", status: 0 }, NOW).ok, false);
  assert.equal(validateReport({ ...BASE, kind: "crash", signal: 11, frames: ["not-hex"] }, NOW).ok, false);
  assert.equal(
    validateReport({ ...BASE, kind: "crash", signal: 11, frames: Array(65).fill("0x1") }, NOW).ok,
    false,
  );
  // Impossible calendar date and out-of-range dates.
  assert.equal(validateReport({ ...BASE, day: "2026-02-31", kind: "engine-exit", status: 134 }, NOW).ok, false);
  assert.equal(validateReport({ ...BASE, day: "2030-01-01", kind: "engine-exit", status: 134 }, NOW).ok, false);
  assert.equal(validateReport({ ...BASE, day: "2020-01-01", kind: "engine-exit", status: 134 }, NOW).ok, false);
  // Every feature in FEATURES is accepted.
  const allFeatures = Object.fromEntries([...FEATURES].map((f) => [f, 1]));
  assert.equal(validateReport({ ...BASE, kind: "usage", counts: allFeatures }, NOW).ok, true);
});

test("HTTP server ingests valid reports, rejects bad ones, and handles sink failure", async () => {
  const rows = [];
  await withServer({ sink: async (row) => rows.push(row) }, async (baseUrl) => {
    const health = await fetch(`${baseUrl}/health`);
    assert.equal(health.status, 200);

    const ok = await fetch(`${baseUrl}/report`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "User-Agent": "Greenroom" },
      body: JSON.stringify({ ...BASE, kind: "crash", signal: 6, frames: ["0x42"] }),
    });
    assert.equal(ok.status, 204);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].signal, 6);

    const badType = await fetch(`${baseUrl}/report`, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: "{}",
    });
    assert.equal(badType.status, 415);

    const badBody = await fetch(`${baseUrl}/report`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...BASE, kind: "crash", signal: 6, frames: [], extra: "nope" }),
    });
    assert.equal(badBody.status, 400);

    const tooBig = await fetch(`${baseUrl}/report`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: " ".repeat(9000),
    });
    assert.equal(tooBig.status, 413);

    const wrongPath = await fetch(`${baseUrl}/other`, { method: "POST" });
    assert.equal(wrongPath.status, 404);
  });

  await withServer(
    {
      sink: async () => {
        throw new Error("boom");
      },
    },
    async (baseUrl) => {
      const res = await fetch(`${baseUrl}/report`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...BASE, kind: "engine-exit", status: 134 }),
      });
      assert.equal(res.status, 503);
    },
  );
});

test("HTTP server enforces rate limiting", async () => {
  const allowRequest = createRateLimiter({ max: 2, windowMs: 60_000 });
  await withServer({ sink: async () => {}, allowRequest }, async (baseUrl) => {
    const send = () =>
      fetch(`${baseUrl}/report`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...BASE, kind: "engine-exit", status: 134 }),
      });
    assert.equal((await send()).status, 204);
    assert.equal((await send()).status, 204);
    assert.equal((await send()).status, 429);
  });
});

test("FEATURES matches Reports.swift enum Feature", () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const swiftPath = path.resolve(here, "../../Sources/Greenroom/Reports.swift");
  const src = fs.readFileSync(swiftPath, "utf8");
  const m = src.match(/enum Feature: String, CaseIterable \{([\s\S]*?)\}/);
  assert.ok(m, "enum Feature not found in Reports.swift");
  const swiftFeatures = new Set(
    m[1]
      .split(/\r?\n/)
      .map((line) => line.replace(/\/\/.*$/, "").trim())
      .filter((line) => line.startsWith("case "))
      .flatMap((line) =>
        line
          .slice(5)
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
      ),
  );
  assert.deepEqual(FEATURES, swiftFeatures);
});
