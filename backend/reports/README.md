# Greenroom Reports Backend

Zero-dependency Node.js 22 service running on Google Cloud Run (`us-central1`) that ingests opt-in crash reports, abnormal simulator engine exits, and daily feature usage counts from Greenroom (`Sources/Greenroom/Reports.swift`) into BigQuery (`greenroom_reports.reports`).

## Privacy & Validation

- Strictly allowlists the exact fields and values defined in `Sources/Greenroom/Reports.swift` and `PRIVACY.md`. Any unknown key, unknown feature name, invalid date, excluded engine status (such as `10`, an Android app crash), or payload over 8 KiB is rejected (`400` / `413`).
- Never stores or logs client IP addresses, cookies, authorization headers, or request bodies. In-memory rate limiting uses an HMAC-SHA256 of the client IP with a per-process random salt.
- BigQuery table partitions expire automatically after 365 days.
- The Cloud Run service runs as `reports-ingest@<project>.iam.gserviceaccount.com` with `roles/bigquery.dataEditor` scoped only to the `greenroom_reports` dataset.

## Endpoints

- `POST /report` — accepts a single JSON report (`Content-Type: application/json`), validates it, streams it into BigQuery, and returns `204 No Content`.
- `GET /health` — returns `200 OK` (`{"ok":true}`).

## Local Tests

```bash
cd backend/reports
node --test
```

The test suite also checks that `FEATURES` in `validate.mjs` stays in exact sync with `Reports.Feature` in `Sources/Greenroom/Reports.swift`.

## Deploy

```bash
backend/reports/deploy.sh [PROJECT_ID] [REGION]
# defaults: greenroom-reports, us-central1
```

## Querying Reports & Symbolicating Crashes

```bash
# Summary of crashes, engine exits, and feature usage (last 14 days by default)
scripts/reports-summary.sh 14

# Symbolicate crash frame offsets against a release .dSYM (or directly from a GitHub release tag)
scripts/symbolicate.sh build/Greenroom-0.1.0.dSYM.zip 0x1a2b3 0x4c5d6
scripts/symbolicate.sh --release v0.1.0 0x1a2b3 0x4c5d6
```
