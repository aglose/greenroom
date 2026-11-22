// Strict validation for opt-in Greenroom reports (Sources/Greenroom/Reports.swift, PRIVACY.md).
// Every field and value is allowlisted so nothing from an APK or unexpected client data is stored.

export const FEATURES = new Set([
  "apkOpened",
  "simulatorLaunched",
  "sideBySide",
  "mirror",
  "compare",
  "screenshot",
  "recording",
  "palette",
  "paneDevice",
  "paneNetwork",
  "paneTests",
  "paneDiagnostics",
  "paneRecordings",
  "timeline",
  "inspector",
  "log",
  "snapshots",
  "screenMap",
  "agentTool",
]);

// Must match Reports.engineEnded(status:) exclusions (including 10: tested Android app crash).
export const EXCLUDED_ENGINE_STATUSES = new Set([0, 2, 10, 130, 137, 143, 15, 9]);

const COMMON_KEYS = ["kind", "day", "app", "build", "engine", "macos"];
const ALLOWED_KEYS_BY_KIND = {
  crash: new Set([...COMMON_KEYS, "signal", "frames"]),
  "engine-exit": new Set([...COMMON_KEYS, "status"]),
  usage: new Set([...COMMON_KEYS, "counts"]),
};

const VERSION_RE = /^[0-9A-Za-z._+-]{1,32}$/;
const DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const FRAME_RE = /^0x[0-9a-f]{1,16}$/;

const MAX_FRAMES = 64;
const MAX_COUNT = 1_000_000;
const MAX_AGE_DAYS = 365;
const MAX_FUTURE_DAYS = 2;

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function parseUtcDay(dayStr, now) {
  if (typeof dayStr !== "string") return null;
  const m = DAY_RE.exec(dayStr);
  if (!m) return null;
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const ms = Date.UTC(year, month - 1, day);
  const d = new Date(ms);
  if (
    d.getUTCFullYear() !== year ||
    d.getUTCMonth() !== month - 1 ||
    d.getUTCDate() !== day
  ) {
    return null;
  }
  const todayUtc = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const diffDays = (ms - todayUtc) / 86_400_000;
  if (diffDays < -MAX_AGE_DAYS || diffDays > MAX_FUTURE_DAYS) {
    return null;
  }
  return dayStr;
}

export function validateReport(body, now = new Date()) {
  if (!isPlainObject(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }

  const kind = body.kind;
  if (typeof kind !== "string" || !Object.hasOwn(ALLOWED_KEYS_BY_KIND, kind)) {
    return { ok: false, error: "invalid kind" };
  }

  const allowedKeys = ALLOWED_KEYS_BY_KIND[kind];
  for (const key of Object.keys(body)) {
    if (!allowedKeys.has(key)) {
      return { ok: false, error: "unexpected field" };
    }
  }

  const day = parseUtcDay(body.day, now);
  if (!day) {
    return { ok: false, error: "invalid day" };
  }

  for (const field of ["app", "build", "engine", "macos"]) {
    if (typeof body[field] !== "string" || !VERSION_RE.test(body[field])) {
      return { ok: false, error: `invalid ${field}` };
    }
  }

  const row = {
    received_at: now.toISOString(),
    kind,
    day,
    app: body.app,
    build: body.build,
    engine: body.engine,
    macos: body.macos,
    signal: null,
    frames: [],
    status: null,
    counts: [],
  };

  if (kind === "crash") {
    if (!Number.isInteger(body.signal) || body.signal < 1 || body.signal > 64) {
      return { ok: false, error: "invalid signal" };
    }
    if (!Array.isArray(body.frames) || body.frames.length > MAX_FRAMES) {
      return { ok: false, error: "invalid frames" };
    }
    for (const frame of body.frames) {
      if (typeof frame !== "string" || !FRAME_RE.test(frame)) {
        return { ok: false, error: "invalid frame" };
      }
    }
    row.signal = body.signal;
    row.frames = body.frames;
  } else if (kind === "engine-exit") {
    if (
      !Number.isInteger(body.status) ||
      body.status < 1 ||
      body.status > 255 ||
      EXCLUDED_ENGINE_STATUSES.has(body.status)
    ) {
      return { ok: false, error: "invalid status" };
    }
    row.status = body.status;
  } else if (kind === "usage") {
    if (!isPlainObject(body.counts)) {
      return { ok: false, error: "invalid counts" };
    }
    const entries = Object.entries(body.counts);
    if (entries.length === 0 || entries.length > FEATURES.size) {
      return { ok: false, error: "invalid counts" };
    }
    const counts = [];
    for (const [feature, count] of entries) {
      if (!FEATURES.has(feature)) {
        return { ok: false, error: "unknown feature" };
      }
      if (!Number.isInteger(count) || count < 1 || count > MAX_COUNT) {
        return { ok: false, error: "invalid count" };
      }
      counts.push({ feature, count });
    }
    counts.sort((a, b) => a.feature.localeCompare(b.feature));
    row.counts = counts;
  }

  return { ok: true, row };
}
