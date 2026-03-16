# BioContainers Mirror

Automatically mirrors all Docker images from [`quay.io/biocontainers`](https://quay.io/organization/biocontainers) to the GitHub Container Registry (`ghcr.io/{owner}/{image}`).

## How it works

A GitHub Actions workflow runs daily at 02:00 UTC and:

1. **Discovers** repos from the Quay.io API (cursor-based pagination, 10,000+ repos).
2. **Syncs** only missing tags using `skopeo` — already-present images are skipped.
3. **Reports** a summary in the Actions step summary.

State is stored as workflow artifacts (`sync-state`) so each run resumes where the previous one left off. No commits are written to the repository.

## Setup

### 1. Fork or create this repository

```bash
gh repo create my-org/biocontainers-mirror --public --clone
cd biocontainers-mirror
# copy these files in, then push
git push
```

### 2. Create a Personal Access Token (PAT)

Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens** and create a token with:

- **Repository**: this repository (or all repositories under your org)
- **Permissions**: `write:packages` (Packages — Read and Write)

Or use a classic PAT with the `write:packages` scope.

### 3. Add the secret to your repository

```
GitHub repo → Settings → Secrets and variables → Actions → New repository secret

Name:  GHCR_PAT
Value: <your PAT>
```

### 4. Run the workflow

Go to **Actions → Mirror BioContainers to GHCR → Run workflow** and choose your parameters.

## Workflow inputs

| Input | Default | Description |
|-------|---------|-------------|
| `max_repos` | `50` | Max number of repos to process per run. `0` = unlimited (time-guarded). |
| `resume` | `true` | Skip repos already present in the `sync-state` artifact. |
| `dry_run` | `false` | Discover repos only — no images are copied. |

## Scaling plan

| Phase | `max_repos` | Purpose |
|-------|-------------|---------|
| Test | `5` | Verify auth, skopeo, and artifact upload |
| Validate | `50` | Confirm incremental sync and resume |
| Scale | `500` | Sustained daily mirroring |
| Full | `0` | Complete mirror — time guard handles the cutoff |

## Verification

```bash
# 1. Dry run: verify discovery
gh workflow run mirror.yml -f max_repos=5 -f dry_run=true

# 2. Real sync: verify images appear
gh workflow run mirror.yml -f max_repos=5 -f dry_run=false

# 3. Check a mirrored image
docker pull ghcr.io/<your-org>/samtools:latest

# 4. Re-run: verify incremental skip
gh workflow run mirror.yml -f max_repos=5 -f dry_run=false
```

## Mirrored images

Images are available at:

```
ghcr.io/<your-org>/<biocontainers-repo>:<tag>
```

For example:
- `ghcr.io/<your-org>/samtools:1.19--h50ea8bc_1`
- `ghcr.io/<your-org>/bwa:0.7.17--h5bf99c6_8`

## Artifacts

| Artifact | Contents |
|----------|----------|
| `sync-state` | `synced-repos.json`, `failed-repos.json`, `run-metadata.json` — retained 90 days |
| `work-manifest` | `work-manifest.json` — retained 1 day |

## License

MIT
