#!/usr/bin/env bash
# Sync MEK-Org/kurrier main from upstream kurrier-org/kurrier main safely.
# Ensures main remains an exact upstream-only mirror without polluting main,
# surfaces any conflicts/divergence visibly, and refuses to silently overwrite.

set -euo pipefail

REPO="MEK-Org/kurrier"
UPSTREAM_URL="https://github.com/kurrier-org/kurrier.git"
DRY_RUN="${DRY_RUN:-false}"

echo "=== Upstream Sync Check for $REPO ==="

# 1. Fetch latest refs from both origin and upstream
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch upstream main --quiet
git fetch origin main --quiet
git fetch origin mek --quiet 2>/dev/null || true

ORIGIN_MAIN=$(git rev-parse origin/main)
UPSTREAM_MAIN=$(git rev-parse upstream/main)

echo "Origin main SHA:   $ORIGIN_MAIN"
echo "Upstream main SHA: $UPSTREAM_MAIN"

# 2. Check equality
if [ "$ORIGIN_MAIN" = "$UPSTREAM_MAIN" ]; then
  echo "Status: IN SYNC. MEK-Org/kurrier main matches upstream/main."
else
  # 3. Check divergence
  if git merge-base --is-ancestor "$ORIGIN_MAIN" "$UPSTREAM_MAIN"; then
    BEHIND_COUNT=$(git rev-list --count "$ORIGIN_MAIN".."$UPSTREAM_MAIN")
    echo "Status: BEHIND upstream by $BEHIND_COUNT commit(s). Clean fast-forward possible."

    if [ "$DRY_RUN" = "true" ]; then
      echo "DRY_RUN=true: skipping update."
    else
      echo "Applying sync via GitHub merge-upstream API..."
      if command -v gh >/dev/null 2>&1; then
        SYNC_RESULT=$(gh api --method POST "/repos/$REPO/merge-upstream" -f branch=main 2>&1) || {
          echo "GitHub merge-upstream API returned non-zero:"
          echo "$SYNC_RESULT"
          exit 1
        }
        echo "API Response: $SYNC_RESULT"
      else
        echo "gh CLI not found; pushing fast-forward ref via git..."
        git push origin "$UPSTREAM_MAIN":refs/heads/main
      fi

      git fetch origin main --quiet
      UPDATED_MAIN=$(git rev-parse origin/main)
      echo "Updated Origin main SHA: $UPDATED_MAIN"
      if [ "$UPDATED_MAIN" != "$UPSTREAM_MAIN" ]; then
        echo "ERROR: Updated main SHA ($UPDATED_MAIN) does not match upstream ($UPSTREAM_MAIN)!"
        exit 1
      fi
      echo "Successfully synced origin/main with upstream/main."
    fi
  elif git merge-base --is-ancestor "$UPSTREAM_MAIN" "$ORIGIN_MAIN"; then
    AHEAD_COUNT=$(git rev-list --count "$UPSTREAM_MAIN".."$ORIGIN_MAIN")
    echo "ERROR: Local divergence detected! origin/main has $AHEAD_COUNT commit(s) not in upstream/main."
    echo "Main is intended as a pure upstream mirror. Refusing to overwrite."
    echo "Local commits on origin/main:"
    git log --oneline "$UPSTREAM_MAIN".."$ORIGIN_MAIN"
    exit 1
  else
    AHEAD_COUNT=$(git rev-list --count "$UPSTREAM_MAIN".."$ORIGIN_MAIN")
    BEHIND_COUNT=$(git rev-list --count "$ORIGIN_MAIN".."$UPSTREAM_MAIN")
    echo "ERROR: Branches have diverged! origin/main is $AHEAD_COUNT ahead, $BEHIND_COUNT behind upstream/main."
    echo "Merge conflict or history rewrite detected. Manual inspection required; refusing silent overwrite."
    exit 1
  fi
fi

# 4. Report status of refinement branch 'mek' relative to 'main'
if git rev-parse --verify origin/mek >/dev/null 2>&1; then
  MEK_SHA=$(git rev-parse origin/mek)
  MAIN_SHA=$(git rev-parse origin/main)
  MEK_AHEAD=$(git rev-list --count "$MAIN_SHA".."$MEK_SHA")
  MEK_BEHIND=$(git rev-list --count "$MEK_SHA".."$MAIN_SHA")

  echo ""
  echo "=== Refinement Branch (mek) Status ==="
  echo "Origin mek SHA:  $MEK_SHA"
  echo "Origin main SHA: $MAIN_SHA"
  echo "mek is $MEK_AHEAD commit(s) ahead of main."
  echo "mek is $MEK_BEHIND commit(s) behind main."

  if [ "$MEK_BEHIND" -gt 0 ]; then
    echo "Notice: mek is behind main by $MEK_BEHIND commit(s). Plan a refinement PR into mek."
  else
    echo "mek includes all commits currently on main."
  fi
fi
