#!/bin/bash
# Provision BigQuery storage and deploy the Greenroom opt-in reports ingest service to Google Cloud Run.
# Idempotent: safe to re-run after changing backend/reports/*.
#
#   backend/reports/deploy.sh [PROJECT_ID] [REGION]
#   (defaults: greenroom-reports, us-central1)
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT=${1:-${GCP_PROJECT:-greenroom-reports}}
REGION=${2:-${GCP_REGION:-us-central1}}
DATASET=${BQ_DATASET:-greenroom_reports}
TABLE=${BQ_TABLE:-reports}
SERVICE=${CLOUD_RUN_SERVICE:-greenroom-reports}
SA_NAME=reports-ingest
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
# 365-day partition retention (in seconds)
RETENTION_SECONDS=$((365 * 86400))

echo "== running backend tests"
(cd "$DIR" && node --test)

echo "== ensuring BigQuery dataset ${PROJECT}:${DATASET} (${REGION})"
if ! bq --project_id="$PROJECT" show "${PROJECT}:${DATASET}" >/dev/null 2>&1; then
  bq --project_id="$PROJECT" mk --dataset --location="$REGION" \
    --description="Opt-in Greenroom crash reports, engine exits, and daily feature usage counts (PRIVACY.md)" \
    "${PROJECT}:${DATASET}"
fi

echo "== ensuring BigQuery table ${PROJECT}:${DATASET}.${TABLE}"
if ! bq --project_id="$PROJECT" show "${PROJECT}:${DATASET}.${TABLE}" >/dev/null 2>&1; then
  bq --project_id="$PROJECT" mk --table \
    --time_partitioning_field=day \
    --time_partitioning_type=DAY \
    --time_partitioning_expiration="$RETENTION_SECONDS" \
    --clustering_fields=kind,app,build \
    "${PROJECT}:${DATASET}.${TABLE}" \
    "$DIR/schema.json"
fi

echo "== ensuring least-privilege service account ${SA_EMAIL}"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" --quiet >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT" \
    --display-name="Greenroom reports ingest" \
    --quiet
  # IAM propagation for newly created service accounts can take a few seconds.
  sleep 5
fi

echo "== granting dataset-scoped BigQuery dataEditor role to ${SA_EMAIL}"
# Scoped to the single dataset (not project-wide) so the service can only insert into greenroom_reports.
TMP_ACCESS=$(mktemp)
trap 'rm -f "$TMP_ACCESS"' EXIT
bq --project_id="$PROJECT" show --format=prettyjson "${PROJECT}:${DATASET}" > "$TMP_ACCESS"
python3 - "$TMP_ACCESS" "$SA_EMAIL" <<'PY'
import json, sys
path, sa = sys.argv[1], sys.argv[2]
with open(path) as f:
    ds = json.load(f)
access = ds.setdefault("access", [])
entry = {"role": "roles/bigquery.dataEditor", "userByEmail": sa}
if entry not in access:
    access.append(entry)
with open(path, "w") as f:
    json.dump(ds, f, indent=2)
PY
bq --project_id="$PROJECT" update --source "$TMP_ACCESS" "${PROJECT}:${DATASET}" >/dev/null

echo "== deploying Cloud Run service ${SERVICE} (${REGION})"
gcloud run deploy "$SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --source="$DIR" \
  --service-account="$SA_EMAIL" \
  --allow-unauthenticated \
  --min-instances=0 \
  --max-instances=5 \
  --concurrency=80 \
  --cpu=1 \
  --memory=256Mi \
  --timeout=15 \
  --set-env-vars="BQ_PROJECT=${PROJECT},BQ_DATASET=${DATASET},BQ_TABLE=${TABLE}" \
  --quiet

URL=$(gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format='value(status.url)' --quiet)
echo "== deployed: ${URL}/report"
