#!/bin/bash
set -euo pipefail

# publish-repo.sh
# Scriptable way to publish this workspace as a new GitHub repo, or push to an existing one.
# Prefers GitHub CLI (gh). Falls back to GitHub REST API if GITHUB_TOKEN is set.
# Usage:
#   ./publish-repo.sh [repo-name] [public|private]
# Examples:
#   ./publish-repo.sh gst-spotify-extended-metadata-fix public
#   ./publish-repo.sh

REPO_NAME="${1:-gst-spotify-extended-metadata-fix}"
VISIBILITY="${2:-public}"

if [[ "$VISIBILITY" != "public" && "$VISIBILITY" != "private" ]]; then
  echo "Visibility must be 'public' or 'private'" >&2
  exit 1
fi

# Ensure git repo exists
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Initializing new git repository..."
  git init
  # Default to main branch
  git checkout -b main || git symbolic-ref HEAD refs/heads/main
fi

# Ensure git identity exists (local); allow override via env vars; auto-detect via gh
if ! git config --get user.email >/dev/null 2>&1; then
  if [ -n "${GIT_AUTHOR_EMAIL:-}" ] && [ -n "${GIT_AUTHOR_NAME:-}" ]; then
    echo "Setting local git identity from env vars..."
    git config user.email "$GIT_AUTHOR_EMAIL"
    git config user.name "$GIT_AUTHOR_NAME"
  else
    # Try to detect via GitHub CLI
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      GH_LOGIN=$(gh api user --jq .login 2>/dev/null || true)
      GH_ID=$(gh api user --jq .id 2>/dev/null || true)
      if [ -n "$GH_LOGIN" ] && [ -n "$GH_ID" ]; then
        # Prefer numeric+login no-reply format for reliable attribution
        NOREPLY_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
        NAME_FROM_GH="${GIT_AUTHOR_NAME:-$GH_LOGIN}"
        echo "Setting local git identity from GitHub account: $NAME_FROM_GH <$NOREPLY_EMAIL>"
        git config user.email "$NOREPLY_EMAIL"
        git config user.name "$NAME_FROM_GH"
      else
        echo "Failed to query GitHub user via gh."
      fi
    fi
    # If still not set, guide user
    if ! git config --get user.email >/dev/null 2>&1; then
      echo "Git author identity not set. Configure one of the following:" >&2
      echo "  Option A (local to this repo):" >&2
      echo "    git config user.email 'username@users.noreply.github.com'" >&2
      echo "    git config user.name 'YourHandle'" >&2
      echo "  Option B (environment for one-off run):" >&2
      echo "    GIT_AUTHOR_NAME='YourHandle' GIT_AUTHOR_EMAIL='username@users.noreply.github.com' ./publish-repo.sh $REPO_NAME $VISIBILITY" >&2
      echo "  Option C (global for your system):" >&2
      echo "    git config --global user.email 'username@users.noreply.github.com'" >&2
      echo "    git config --global user.name 'YourHandle'" >&2
      exit 1
    fi
  fi
fi

# Create a conservative .gitignore if missing
if [ ! -f .gitignore ]; then
  cat > .gitignore <<'EOFIGNORE'
# Build artifacts
libgstspotify.so
*.so

gst-plugins-rs-build/gst-plugins-rs/target/
# npm/cargo-style target folders just in case
**/target/

# Caches
.cache/
EOFIGNORE
  echo "Created .gitignore"
fi

# Stage and commit (robust logic)
UNTRACKED=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
echo "Untracked files detected: $UNTRACKED"

if git rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
  # Existing repo: create commit only if changes staged
  git add -A
  if ! git diff --cached --quiet; then
    echo "Creating commit for current changes..."
    git commit -m "chore: update workspace contents"
  else
    echo "No changes to commit (working tree clean)."
  fi
else
  # Fresh repo: always create initial commit
  echo "Creating initial commit..."
  git add -A
  git commit -m "Initial: build script + patch for librespot extended metadata and strip helper"
fi

# If a remote already exists, just push
if git remote get-url origin >/dev/null 2>&1; then
  echo "Remote 'origin' already set: $(git remote get-url origin)"
  echo "Pushing to origin..."
  git push -u origin main
  exit 0
fi

# Try GitHub CLI first
if command -v gh >/dev/null 2>&1; then
  echo "Creating GitHub repo via gh CLI: $REPO_NAME ($VISIBILITY)"
  # We assume we now have at least one commit; if not, abort clearly.
  if ! git rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
    echo "Error: no commits exist after staging. Aborting gh repo create." >&2
    exit 1
  fi
  gh repo create "$REPO_NAME" --$VISIBILITY --source=. --remote=origin --push
  USER_LOGIN=$(gh api user --jq .login 2>/dev/null || echo "<user>")
  echo "Done: https://github.com/${USER_LOGIN}/$REPO_NAME"
  exit 0
fi

# Fallback: GitHub REST API
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "Creating GitHub repo via REST API: $REPO_NAME ($VISIBILITY)"
  USERNAME="${GITHUB_USERNAME:-}"
  if [ -z "$USERNAME" ]; then
    # Try to infer from git config
    USERNAME=$(git config --get user.username || true)
  fi
  if [ -z "$USERNAME" ]; then
    echo "Set GITHUB_USERNAME to your GitHub handle for REST API fallback." >&2
    exit 1
  fi

  # Create repo
  VIS_PRIV=false
  if [ "$VISIBILITY" = "private" ]; then VIS_PRIV=true; fi
  API_RESP=$(curl -sS -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user/repos \
    -d "{\"name\":\"$REPO_NAME\",\"private\":$VIS_PRIV,\"auto_init\":false}")

  if echo "$API_RESP" | grep -q '"html_url"'; then
    echo "Repository created."
  else
    echo "Failed to create repository via API:" >&2
    echo "$API_RESP" >&2
    exit 1
  fi

  git remote add origin "https://github.com/$USERNAME/$REPO_NAME.git"
  git push -u origin main
  echo "Done: https://github.com/$USERNAME/$REPO_NAME"
  exit 0
fi

cat <<'EOF'
Could not find GitHub CLI (gh) and no GITHUB_TOKEN set for REST API.
Options:
  1) Install GitHub CLI and rerun:
       sudo apt-get install gh   # or see https://cli.github.com/
       gh auth login             # authenticate
       ./publish-repo.sh [name] [public|private]

  2) Use REST API with token:
       export GITHUB_TOKEN=...   # Personal Access Token with repo scope
       export GITHUB_USERNAME=your-gh-username
       ./publish-repo.sh [name] [public|private]

  3) Create remote via web UI, then:
       git remote add origin https://github.com/<you>/<repo>.git
       git push -u origin main
EOF
exit 1
