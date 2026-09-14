# Fork Branch and Sync Policy

This repository (`MEK-Org/kurrier`) is a refinement fork of [`kurrier-org/kurrier`](https://github.com/kurrier-org/kurrier).

## Branch Layout

- **`main`**: Pure upstream mirror of `kurrier-org/kurrier:main`.
  - Never commit directly to `main`.
  - Changes are synced strictly from upstream via clean fast-forward only.
  - If `main` diverges from upstream, automated sync halts and alerts rather than force-updating.
- **`mek`**: Dedicated refinement branch for MEK-Org customizations, policies, and ongoing work.
  - All MEK-specific features, configurations, and fixes target `mek`.
  - Refinement updates from `main` into `mek` are reviewed and merged intentionally.
- **Feature / Topic Branches**: Namespaced branches (e.g. `rusa/<short-id>/<topic>` or `<author>/<topic>`).
  - PRs are opened against `mek` (never directly against `main`).

## Upstream Synchronization Mechanism

The sync mechanism is implemented in `scripts/sync-upstream.sh`:
- **Safety**: Checks ancestor relationships between `origin/main` and `upstream/main` before applying updates.
- **Native GitHub API Integration**: Uses GitHub's native `POST /repos/MEK-Org/kurrier/merge-upstream` endpoint (or git fast-forward ref push) to keep `main` synchronized with `upstream/main` without polluting `main`.
- **Visibility**: If `origin/main` has local commits or has diverged from `upstream/main`, the script fails visibly with exit code 1 and lists the exact divergent commits.
- **Protection**: Silent overwrites and forced pushes are strictly prohibited.
- **Refinement Tracking**: Reports the ahead/behind commit status of `mek` relative to `main` so refinement PRs can be scheduled when upstream introduces changes.
- **GitHub Actions Workflow**: A workflow definition is provided at `scripts/workflows/sync-upstream.yml` for scheduled or on-demand execution.
