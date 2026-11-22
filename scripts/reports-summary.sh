#!/bin/bash
# Queries BigQuery for recent Greenroom opt-in crash reports, engine exits, and feature usage.
#
#   scripts/reports-summary.sh [DAYS] [PROJECT_ID]
#   (defaults: 14 days, greenroom-reports)
set -euo pipefail

DAYS=${1:-14}
PROJECT=${2:-${GCP_PROJECT:-greenroom-reports}}
DATASET=${BQ_DATASET:-greenroom_reports}
TABLE="\`${PROJECT}.${DATASET}.reports\`"

[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "usage: scripts/reports-summary.sh [DAYS] [PROJECT_ID]" >&2; exit 2; }

echo "== Greenroom crashes (last ${DAYS} days)"
bq --project_id="$PROJECT" query --use_legacy_sql=false --format=pretty "
SELECT
  app,
  build,
  signal,
  ARRAY_TO_STRING(ARRAY(SELECT f FROM UNNEST(frames) f WITH OFFSET pos WHERE pos < 5 ORDER BY pos), ' ') AS top_frames,
  COUNT(*) AS reports,
  MIN(day) AS first_day,
  MAX(day) AS last_day
FROM ${TABLE}
WHERE kind = 'crash' AND day >= DATE_SUB(CURRENT_DATE(), INTERVAL ${DAYS} DAY)
GROUP BY app, build, signal, top_frames
ORDER BY reports DESC, last_day DESC
LIMIT 25
"

echo "== Engine abnormal exits (last ${DAYS} days)"
bq --project_id="$PROJECT" query --use_legacy_sql=false --format=pretty "
SELECT
  engine,
  app,
  status,
  COUNT(*) AS reports,
  MIN(day) AS first_day,
  MAX(day) AS last_day
FROM ${TABLE}
WHERE kind = 'engine-exit' AND day >= DATE_SUB(CURRENT_DATE(), INTERVAL ${DAYS} DAY)
GROUP BY engine, app, status
ORDER BY reports DESC, last_day DESC
LIMIT 25
"

echo "== Feature usage (last ${DAYS} days)"
bq --project_id="$PROJECT" query --use_legacy_sql=false --format=pretty "
SELECT
  c.feature,
  SUM(c.count) AS total_uses,
  COUNT(*) AS user_days
FROM ${TABLE}, UNNEST(counts) AS c
WHERE kind = 'usage' AND day >= DATE_SUB(CURRENT_DATE(), INTERVAL ${DAYS} DAY)
GROUP BY c.feature
ORDER BY total_uses DESC
"
