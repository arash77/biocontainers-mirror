#!/usr/bin/env bash
# sync-repos.sh — Copy new tags from quay.io/biocontainers to GHCR
# Reads work-manifest.json, performs incremental tag-level sync,
# respects time guard, checkpoints every 10 repos.

set -euo pipefail

WORK_MANIFEST="${WORK_MANIFEST:-work-manifest.json}"
SYNCED_FILE="${SYNCED_FILE:-synced-repos.json}"
FAILED_FILE="${FAILED_FILE:-failed-repos.json}"
METADATA_FILE="${METADATA_FILE:-run-metadata.json}"
GHCR_OWNER="${GHCR_OWNER:-}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-330}"

# How many minutes before timeout to stop processing new repos
MARGIN_MINUTES=20

START_TIME=$(date +%s)
DEADLINE=$(( START_TIME + (TIMEOUT_MINUTES - MARGIN_MINUTES) * 60 ))

echo "==> Sync started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    Will stop at $(date -u -d "@${DEADLINE}" +%Y-%m-%dT%H:%M:%SZ) (${MARGIN_MINUTES}min margin)"

if [[ -z "$GHCR_OWNER" ]]; then
  echo "ERROR: GHCR_OWNER must be set" >&2
  exit 1
fi

if [[ ! -f "$WORK_MANIFEST" ]]; then
  echo "ERROR: Work manifest not found: $WORK_MANIFEST" >&2
  exit 1
fi

# Load existing synced/failed state or initialise
if [[ -f "$SYNCED_FILE" ]]; then
  synced_data=$(cat "$SYNCED_FILE")
else
  synced_data="[]"
fi

if [[ -f "$FAILED_FILE" ]]; then
  failed_data=$(cat "$FAILED_FILE")
else
  failed_data="[]"
fi

repos=$(jq -r '.repos[]' "$WORK_MANIFEST")
total=$(jq '.to_sync' "$WORK_MANIFEST")

echo "==> Processing ${total} repos"

synced_this_run=0
failed_this_run=0
skipped_tags=0
copied_tags=0
timed_out=false
checkpoint_counter=0

checkpoint() {
  echo "    [checkpoint] Saving state (synced=${synced_this_run}, failed=${failed_this_run})"
  echo "$synced_data" | jq '.' > "$SYNCED_FILE"
  echo "$failed_data" | jq '.' > "$FAILED_FILE"

  jq -n \
    --arg start "$(date -u -d "@${START_TIME}" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson synced "$synced_this_run" \
    --argjson failed "$failed_this_run" \
    --argjson skipped "$skipped_tags" \
    --argjson copied "$copied_tags" \
    --argjson timed_out "$( [[ "$timed_out" == "true" ]] && echo 'true' || echo 'false' )" \
    '{
      run_start: $start,
      last_updated: $updated,
      synced_this_run: $synced,
      failed_this_run: $failed,
      skipped_tags: $skipped,
      copied_tags: $copied,
      timed_out: $timed_out
    }' > "$METADATA_FILE"
}

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue

  # Time guard check
  now=$(date +%s)
  if [[ "$now" -ge "$DEADLINE" ]]; then
    echo "==> Time guard triggered — stopping before deadline"
    timed_out=true
    break
  fi

  src="quay.io/biocontainers/${repo}"
  dst="ghcr.io/${GHCR_OWNER}/${repo}"

  echo "--> Syncing ${repo}"

  # Get tags from source
  src_tags=$(skopeo list-tags "docker://${src}" 2>/dev/null | jq -r '.Tags[]' | sort || true)
  if [[ -z "$src_tags" ]]; then
    echo "    WARNING: No tags found for ${src}, skipping"
    failed_data=$(echo "$failed_data" | jq \
      --arg name "$repo" \
      --arg reason "no_tags" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + [{"name": $name, "reason": $reason, "timestamp": $ts}]')
    failed_this_run=$((failed_this_run + 1))
    continue
  fi

  # Get tags already at destination (best-effort — empty if repo doesn't exist yet)
  dst_tags=$(skopeo list-tags "docker://${dst}" 2>/dev/null | jq -r '.Tags[]' | sort || echo "")

  # Compute missing tags
  missing_tags=$(comm -23 \
    <(echo "$src_tags") \
    <(echo "$dst_tags"))

  tag_count=$(echo "$src_tags" | wc -l)
  missing_count=$(echo "$missing_tags" | grep -c . || echo 0)

  if [[ "$missing_count" -eq 0 ]]; then
    echo "    All ${tag_count} tags already present, skipping"
    skipped_tags=$((skipped_tags + tag_count))
    # Still mark as synced if not already recorded
    synced_data=$(echo "$synced_data" | jq \
      --arg name "$repo" \
      --argjson tags "$tag_count" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'map(select(.name != $name)) + [{"name": $name, "tags": $tags, "synced_at": $ts}]')
    synced_this_run=$((synced_this_run + 1))
    continue
  fi

  echo "    ${missing_count}/${tag_count} tags to copy"
  repo_failed=false

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue

    # Per-tag time guard
    now=$(date +%s)
    if [[ "$now" -ge "$DEADLINE" ]]; then
      echo "    Time guard triggered mid-repo at tag ${tag}"
      timed_out=true
      break 2
    fi

    echo "    Copying tag: ${tag}"
    if skopeo copy \
      --retry-times 3 \
      "docker://${src}:${tag}" \
      "docker://${dst}:${tag}" \
      2>&1 | sed 's/^/      /'; then
      copied_tags=$((copied_tags + 1))
    else
      echo "    ERROR: Failed to copy ${src}:${tag}"
      repo_failed=true
    fi

    # Rate limiting
    sleep 0.2
  done <<< "$missing_tags"

  if [[ "$repo_failed" == "true" ]]; then
    failed_data=$(echo "$failed_data" | jq \
      --arg name "$repo" \
      --arg reason "copy_error" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'map(select(.name != $name)) + [{"name": $name, "reason": $reason, "timestamp": $ts}]')
    failed_this_run=$((failed_this_run + 1))
  else
    synced_data=$(echo "$synced_data" | jq \
      --arg name "$repo" \
      --argjson tags "$tag_count" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'map(select(.name != $name)) + [{"name": $name, "tags": $tags, "synced_at": $ts}]')
    synced_this_run=$((synced_this_run + 1))
  fi

  # Checkpoint every 10 repos
  checkpoint_counter=$((checkpoint_counter + 1))
  if [[ $((checkpoint_counter % 10)) -eq 0 ]]; then
    checkpoint
  fi

done <<< "$repos"

# Final checkpoint
checkpoint

echo ""
echo "==> Sync complete"
echo "    Synced this run : ${synced_this_run}"
echo "    Failed this run : ${failed_this_run}"
echo "    Tags copied     : ${copied_tags}"
echo "    Tags skipped    : ${skipped_tags}"
echo "    Timed out       : ${timed_out}"
