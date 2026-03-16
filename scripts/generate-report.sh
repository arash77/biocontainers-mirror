#!/usr/bin/env bash
# generate-report.sh — Produce a markdown summary for GITHUB_STEP_SUMMARY.
# Reads synced-repos.json, failed-repos.json, run-metadata.json, work-manifest.json

set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
REPO_COUNT="${REPO_COUNT:-0}"

SYNCED_FILE="${SYNCED_FILE:-synced-repos.json}"
FAILED_FILE="${FAILED_FILE:-failed-repos.json}"
METADATA_FILE="${METADATA_FILE:-run-metadata.json}"
WORK_MANIFEST="${WORK_MANIFEST:-work-manifest.json}"

# Helpers with safe defaults
read_json() {
  local file="$1" query="$2" default="$3"
  if [[ -f "$file" ]]; then
    jq -r "$query" "$file" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

total_synced_ever=$(read_json "$SYNCED_FILE" 'length' '0')
total_failed_ever=$(read_json "$FAILED_FILE" 'length' '0')
total_available=$(read_json "$WORK_MANIFEST" '.total_available' 'N/A')
pending=$(read_json "$WORK_MANIFEST" '.pending' 'N/A')

synced_this_run=$(read_json "$METADATA_FILE" '.synced_this_run' '0')
failed_this_run=$(read_json "$METADATA_FILE" '.failed_this_run' '0')
copied_tags=$(read_json "$METADATA_FILE" '.copied_tags' '0')
skipped_tags=$(read_json "$METADATA_FILE" '.skipped_tags' '0')
timed_out=$(read_json "$METADATA_FILE" '.timed_out' 'false')
run_start=$(read_json "$METADATA_FILE" '.run_start' 'N/A')
last_updated=$(read_json "$METADATA_FILE" '.last_updated' 'N/A')

# Build progress bar (width 20)
if [[ "$total_available" =~ ^[0-9]+$ && "$total_available" -gt 0 ]]; then
  pct=$(( total_synced_ever * 100 / total_available ))
  filled=$(( pct * 20 / 100 ))
  bar=$(printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true)
  empty=$(printf '░%.0s' $(seq 1 $((20 - filled)) 2>/dev/null) || true)
  progress_bar="${bar}${empty} ${pct}%"
else
  progress_bar="N/A"
fi

cat <<EOF
## BioContainers Mirror Report

**Run started**: ${run_start}
**Last updated**: ${last_updated}
**Dry run**: ${DRY_RUN}

### This Run
| Metric | Value |
|--------|-------|
| Repos discovered | ${REPO_COUNT} |
| Repos synced | ${synced_this_run} |
| Repos failed | ${failed_this_run} |
| Tags copied | ${copied_tags} |
| Tags skipped (already present) | ${skipped_tags} |
| Timed out | ${timed_out} |

### Cumulative Progress
| Metric | Value |
|--------|-------|
| Total repos in quay.io/biocontainers | ${total_available} |
| Repos pending sync | ${pending} |
| Total synced (all runs) | ${total_synced_ever} |
| Total failed (all runs) | ${total_failed_ever} |
| Progress | \`${progress_bar}\` |

EOF

if [[ "$total_failed_ever" -gt 0 ]]; then
  echo "### Failed Repos (last ${total_failed_ever})"
  echo ""
  echo "| Repo | Reason | Timestamp |"
  echo "|------|--------|-----------|"
  if [[ -f "$FAILED_FILE" ]]; then
    jq -r '.[] | "| \(.name) | \(.reason) | \(.timestamp) |"' "$FAILED_FILE" | head -20
    if [[ "$total_failed_ever" -gt 20 ]]; then
      echo "| ... | ... | ... |"
      echo "> Showing first 20 failures. Download the \`sync-state\` artifact for the full list."
    fi
  fi
  echo ""
fi

if [[ "$timed_out" == "true" ]]; then
  echo "> **Note**: This run hit the time guard and did not complete all repos. Re-run the workflow to continue from where it left off."
fi
