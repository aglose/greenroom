import crypto from "node:crypto";

const METADATA_TOKEN_URL =
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

export function createBigQuerySink({ projectId, datasetId, tableId, fetchImpl = fetch }) {
  if (!projectId || !datasetId || !tableId) {
    throw new Error("BQ_PROJECT, BQ_DATASET, and BQ_TABLE are required");
  }

  let cachedToken = null;
  let tokenExpiresAt = 0;

  async function getAccessToken() {
    if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN) {
      return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
    }
    const now = Date.now();
    if (cachedToken && now < tokenExpiresAt) {
      return cachedToken;
    }
    const res = await fetchImpl(METADATA_TOKEN_URL, {
      headers: { "Metadata-Flavor": "Google" },
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      throw new Error(`metadata token request failed: HTTP ${res.status}`);
    }
    const data = await res.json();
    cachedToken = data.access_token;
    const ttlSeconds = Math.max(60, Number(data.expires_in || 300) - 60);
    tokenExpiresAt = now + ttlSeconds * 1000;
    return cachedToken;
  }

  const insertUrl =
    `https://bigquery.googleapis.com/bigquery/v2/projects/${encodeURIComponent(projectId)}` +
    `/datasets/${encodeURIComponent(datasetId)}` +
    `/tables/${encodeURIComponent(tableId)}/insertAll`;

  return async function insertRow(row) {
    const token = await getAccessToken();
    const res = await fetchImpl(insertUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        rows: [{ insertId: crypto.randomUUID(), json: row }],
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`BigQuery HTTP ${res.status}: ${text.slice(0, 200)}`);
    }
    const payload = await res.json();
    if (Array.isArray(payload.insertErrors) && payload.insertErrors.length > 0) {
      const reasons = payload.insertErrors
        .flatMap((e) => (e.errors || []).map((err) => `${err.reason}:${err.location || ""}`))
        .join(",");
      throw new Error(`BigQuery insertErrors: ${reasons}`);
    }
  };
}
