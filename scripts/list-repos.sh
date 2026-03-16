#!/usr/bin/env bash
# list-repos.sh — Paginate Quay.io API for biocontainers repos,
# subtract already-synced repos, cap at MAX_REPOS, produce work-manifest.json

set -euo pipefail

QUAY_API="https://quay.io/api/v1/repository"
NAMESPACE="biocontainers"
MAX_REPOS="${MAX_REPOS:-50}"
DRY_RUN="${DRY_RUN:-false}"

SYNCED_FILE="synced-repos.json"
ALL_REPOS_FILE="all-repos-snapshot.json"
WORK_MANIFEST="work-manifest.json"

echo "==> Fetching repo list from quay.io/biocontainers (max_repos=${MAX_REPOS})"

# Collect all repos via cursor-based pagination
all_repos="[]"
page_url="${QUAY_API}?namespace=${NAMESPACE}&public=true&limit=100"
page=0

while [[ -n "$page_url" ]]; do
  page=$((page + 1))
  echo "    Fetching page ${page}: ${page_url}"

  response=$(curl -sf \
    -H "Accept: application/json" \
    "${page_url}" 2>/dev/null) || {
    echo "ERROR: Failed to fetch page ${page}" >&2
    break
  }

  # Extract repo names from this page
  page_repos=$(echo "$response" | jq -r '[.repositories[].name]')
  all_repos=$(echo "$all_repos $page_repos" | jq -s 'add | unique | sort')

  # Get next page cursor
  next_page=$(echo "$response" | jq -r '.next_page // empty')
  if [[ -n "$next_page" ]]; then
    page_url="${QUAY_API}?namespace=${NAMESPACE}&public=true&limit=100&next_page=${next_page}"
  else
    page_url=""
  fi

  # Safety: stop if we have way more than needed (avoid runaway pagination in dry-run)
  total_so_far=$(echo "$all_repos" | jq 'length')
  if [[ "$MAX_REPOS" -gt 0 && "$total_so_far" -ge $((MAX_REPOS * 5)) ]]; then
    echo "    Collected ${total_so_far} repos total; stopping pagination early (5x max_repos)"
    break
  fi
done

total_available=$(echo "$all_repos" | jq 'length')
echo "==> Found ${total_available} total repos in quay.io/biocontainers"

# Save snapshot
echo "$all_repos" | jq '.' > "$ALL_REPOS_FILE"

# Load already-synced repos
synced_repos="[]"
if [[ -f "$SYNCED_FILE" ]]; then
  synced_repos=$(jq '[.[].name] // []' "$SYNCED_FILE" 2>/dev/null || echo "[]")
  synced_count=$(echo "$synced_repos" | jq 'length')
  echo "==> Found ${synced_count} already-synced repos to skip"
fi

# Subtract synced repos from all repos
pending_repos=$(echo "$all_repos $synced_repos" | jq -s '.[0] - .[1]')
pending_count=$(echo "$pending_repos" | jq 'length')
echo "==> ${pending_count} repos pending sync"

# Apply MAX_REPOS cap
if [[ "$MAX_REPOS" -gt 0 && "$pending_count" -gt "$MAX_REPOS" ]]; then
  work_repos=$(echo "$pending_repos" | jq --argjson n "$MAX_REPOS" '.[:$n]')
  echo "==> Capped to ${MAX_REPOS} repos for this run"
else
  work_repos="$pending_repos"
fi

work_count=$(echo "$work_repos" | jq 'length')

# Write work manifest
jq -n \
  --argjson repos "$work_repos" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson total_available "$total_available" \
  --argjson pending_count "$pending_count" \
  '{
    generated_at: $timestamp,
    total_available: $total_available,
    pending: $pending_count,
    to_sync: ($repos | length),
    repos: $repos
  }' > "$WORK_MANIFEST"

echo "==> Work manifest written: ${work_count} repos to sync"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> DRY RUN mode — no images will be copied"
  echo "    Repos that would be synced:"
  echo "$work_repos" | jq -r '.[]' | head -20
  if [[ "$work_count" -gt 20 ]]; then
    echo "    ... and $((work_count - 20)) more"
  fi
fi

# Set output for GitHub Actions
echo "repo_count=${work_count}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "==> Done. repo_count=${work_count}"
