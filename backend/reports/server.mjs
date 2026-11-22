import http from "node:http";
import { fileURLToPath } from "node:url";
import { createBigQuerySink } from "./bigquery.mjs";
import { createRateLimiter } from "./ratelimit.mjs";
import { validateReport } from "./validate.mjs";

export const MAX_BODY_BYTES = 8192;

function readJsonBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let settled = false;

    req.on("data", (chunk) => {
      if (settled) return;
      total += chunk.length;
      if (total > maxBytes) {
        settled = true;
        reject(Object.assign(new Error("payload too large"), { statusCode: 413 }));
        req.resume();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (settled) return;
      settled = true;
      try {
        const text = Buffer.concat(chunks).toString("utf8");
        resolve(JSON.parse(text));
      } catch {
        reject(Object.assign(new Error("invalid json"), { statusCode: 400 }));
      }
    });
    req.on("error", (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    });
  });
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(data),
  });
  res.end(data);
}

function clientKey(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.length > 0) {
    return forwarded.split(",")[0].trim();
  }
  return req.socket?.remoteAddress || "unknown";
}

export function createReportsServer({
  sink,
  allowRequest = createRateLimiter({
    max: Number(process.env.RATE_LIMIT_MAX || 120),
    windowMs: Number(process.env.RATE_LIMIT_WINDOW_MS || 60_000),
  }),
  now = () => new Date(),
  logError = (msg) => console.error(msg),
} = {}) {
  if (typeof sink !== "function") {
    throw new Error("sink function is required");
  }

  return http.createServer(async (req, res) => {
    const url = new URL(req.url || "/", "http://localhost");

    if (url.pathname === "/health" || url.pathname === "/healthz") {
      if (req.method !== "GET" && req.method !== "HEAD") {
        sendJson(res, 405, { error: "method not allowed" });
        return;
      }
      if (req.method === "HEAD") {
        res.writeHead(200, { "Cache-Control": "no-store" });
        res.end();
        return;
      }
      sendJson(res, 200, { ok: true });
      return;
    }

    if (url.pathname !== "/report") {
      sendJson(res, 404, { error: "not found" });
      return;
    }

    if (req.method !== "POST") {
      sendJson(res, 405, { error: "method not allowed" });
      return;
    }

    if (!allowRequest(clientKey(req))) {
      sendJson(res, 429, { error: "too many requests" });
      return;
    }

    const contentType = String(req.headers["content-type"] || "").toLowerCase();
    if (!contentType.startsWith("application/json")) {
      sendJson(res, 415, { error: "content-type must be application/json" });
      return;
    }

    let body;
    try {
      body = await readJsonBody(req, MAX_BODY_BYTES);
    } catch (err) {
      const code = err?.statusCode || 400;
      sendJson(res, code, { error: code === 413 ? "payload too large" : "invalid json" });
      return;
    }

    const result = validateReport(body, now());
    if (!result.ok) {
      sendJson(res, 400, { error: result.error });
      return;
    }

    try {
      await sink(result.row);
    } catch (err) {
      logError(`report insert failed (kind=${result.row.kind}): ${err?.message || err}`);
      sendJson(res, 503, { error: "temporarily unavailable" });
      return;
    }

    res.writeHead(204, { "Cache-Control": "no-store" });
    res.end();
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const port = Number(process.env.PORT || 8080);
  const sink = createBigQuerySink({
    projectId: process.env.BQ_PROJECT,
    datasetId: process.env.BQ_DATASET || "greenroom_reports",
    tableId: process.env.BQ_TABLE || "reports",
  });
  const server = createReportsServer({ sink });
  server.listen(port, () => {
    console.log(`greenroom-reports listening on :${port}`);
  });
}
