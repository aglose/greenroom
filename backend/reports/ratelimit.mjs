import crypto from "node:crypto";

// Ephemeral in-memory rate limiter. Client keys are HMAC-hashed with a per-process random salt
// so raw IP addresses are never retained in memory, logged, or persisted.
export function createRateLimiter({ max = 120, windowMs = 60_000, maxKeys = 10_000 } = {}) {
  const salt = crypto.randomBytes(32);
  const buckets = new Map();

  function hashKey(raw) {
    return crypto.createHmac("sha256", salt).update(String(raw)).digest("base64url");
  }

  function prune(nowMs) {
    for (const [k, entry] of buckets) {
      if (nowMs >= entry.resetAt) buckets.delete(k);
    }
    // If still at capacity under high-cardinality traffic, drop oldest entries.
    while (buckets.size >= maxKeys) {
      const oldest = buckets.keys().next().value;
      if (oldest === undefined) break;
      buckets.delete(oldest);
    }
  }

  return function allow(rawKey, nowMs = Date.now()) {
    const key = hashKey(rawKey);
    const existing = buckets.get(key);
    if (!existing || nowMs >= existing.resetAt) {
      if (buckets.size >= maxKeys) prune(nowMs);
      buckets.set(key, { count: 1, resetAt: nowMs + windowMs });
      return true;
    }
    if (existing.count >= max) return false;
    existing.count += 1;
    return true;
  };
}
