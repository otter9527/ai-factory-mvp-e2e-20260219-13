#!/usr/bin/env bash
set -euo pipefail

REPO=""
VISIBILITY="private"
DEFAULT_BRANCH="main"
STRICT_MODE="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    --strict-mode) STRICT_MODE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: bootstrap_repo.sh --repo <owner/name> [--visibility private|public] [--default-branch main] [--strict-mode true|false]" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "Run inside repo root" >&2
  exit 1
fi
cd "$ROOT"

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git add .
  git commit -m "chore: initial mvp scaffold"
fi

git branch -M "$DEFAULT_BRANCH"

if gh repo view "$REPO" >/dev/null 2>&1; then
  :
else
  gh repo create "$REPO" "--${VISIBILITY}" --disable-wiki --description "AI Factory MVP E2E flow"
fi

REMOTE_URL="https://github.com/${REPO}.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

git push -u origin "$DEFAULT_BRANCH"

# labels
gh label create "type/task" --repo "$REPO" --color "0E8A16" --description "Task issues" --force
gh label create "status/ready" --repo "$REPO" --color "1D76DB" --description "Ready for dispatch" --force
gh label create "status/in_progress" --repo "$REPO" --color "FBCA04" --description "Task in progress" --force
gh label create "status/done" --repo "$REPO" --color "0E8A16" --description "Task done" --force
gh label create "status/blocked" --repo "$REPO" --color "B60205" --description "Task blocked" --force
gh label create "worker/a" --repo "$REPO" --color "5319E7" --description "Assigned to worker-a" --force
gh label create "worker/b" --repo "$REPO" --color "5319E7" --description "Assigned to worker-b" --force

if [[ "$STRICT_MODE" == "true" ]]; then
  gh api -X PUT "repos/${REPO}/branches/${DEFAULT_BRANCH}/protection" --input - <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "policy-check",
      "unit-tests",
      "acceptance-tests",
      "lint-format"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": true
}
JSON
fi

python3 - <<PY
import json
strict_mode = "${STRICT_MODE}".strip().lower() == "true"
print(json.dumps({"ok": True, "repo": "${REPO}", "default_branch": "${DEFAULT_BRANCH}", "strict_mode": strict_mode}, ensure_ascii=False))
PY
