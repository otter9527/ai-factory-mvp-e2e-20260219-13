#!/usr/bin/env bash
set -euo pipefail

REPO=""
ISSUE=""
WORKER=""
AI_MODE="mock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --worker) WORKER="$2"; shift 2 ;;
    --ai-mode) AI_MODE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" || -z "$ISSUE" || -z "$WORKER" ]]; then
  echo "Usage: run_task.sh --repo <owner/name> --issue <num> --worker <worker-a|worker-b> [--ai-mode mock|real]" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "Must run inside a git repo" >&2
  exit 1
fi
cd "$ROOT"

ISSUE_JSON="$(gh api "repos/${REPO}/issues/${ISSUE}")"
export ISSUE_JSON
TASK_META_JSON="$(python3 - <<'PY'
import json, os, re, sys
import yaml

issue = json.loads(os.environ["ISSUE_JSON"])
body = issue.get("body") or ""
lines = body.splitlines()
meta = {}
if len(lines) >= 3 and lines[0].strip() == "---":
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is not None:
        raw = "\n".join(lines[1:end])
        val = yaml.safe_load(raw) or {}
        if isinstance(val, dict):
            meta = val

task_id = str(meta.get("task_id") or "").strip()
task_type = str(meta.get("task_type") or "").strip()
status = str(meta.get("status") or "").strip()
if not task_id:
    raise SystemExit("task_id missing")
m = re.search(r"(\d+)", task_id)
if not m:
    raise SystemExit(f"invalid task_id: {task_id}")
marker = f"task_{int(m.group(1)):03d}"
print(json.dumps({"task_id": task_id, "task_type": task_type, "status": status, "marker": marker, "title": issue.get("title", "")}))
PY
)"

export TASK_META_JSON
TASK_ID="$(python3 - <<'PY'
import json, os
print(json.loads(os.environ["TASK_META_JSON"])["task_id"])
PY
)"
TASK_TYPE="$(python3 - <<'PY'
import json, os
print(json.loads(os.environ["TASK_META_JSON"])["task_type"])
PY
)"
MARKER="$(python3 - <<'PY'
import json, os
print(json.loads(os.environ["TASK_META_JSON"])["marker"])
PY
)"
ISSUE_TITLE="$(python3 - <<'PY'
import json, os
print(json.loads(os.environ["TASK_META_JSON"])["title"])
PY
)"

BRANCH_SUFFIX="$(echo "$TASK_ID" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
BRANCH="worker/${WORKER}/task-${BRANCH_SUFFIX}"

git fetch origin main
git checkout main
git pull --ff-only origin main
git checkout -B "$BRANCH"

AI_RESULT="$(python3 scripts/worker/ai_adapter.py --mode "$AI_MODE" --task-id "$TASK_ID" --task-type "$TASK_TYPE" --issue "$ISSUE" --summary "$ISSUE_TITLE")"
export AI_RESULT TASK_ID WORKER
python3 - <<'PY'
import datetime as dt
import json
import os
from pathlib import Path

root = Path(".")
task_id = os.environ["TASK_ID"]
ai_result = json.loads(os.environ["AI_RESULT"])

if task_id == "TASK-001":
    content = '''"""Small module used by the MVP worker flow."""


def add(a, b):
    return a + b


def multiply(a, b):
    raise NotImplementedError("TASK-002 pending")


def safe_divide(a, b):
    raise NotImplementedError("TASK-003 pending")
'''
elif task_id == "TASK-002":
    content = '''"""Small module used by the MVP worker flow."""


def add(a, b):
    return a + b


def multiply(a, b):
    return a * b


def safe_divide(a, b):
    raise NotImplementedError("TASK-003 pending")
'''
elif task_id == "TASK-003":
    content = '''"""Small module used by the MVP worker flow."""


def add(a, b):
    return a + b


def multiply(a, b):
    return a * b


def safe_divide(a, b):
    if b == 0:
        raise ValueError("division by zero")
    return a / b
'''
else:
    content = '''"""Small module used by the MVP worker flow."""


def add(a, b):
    return a + b


def multiply(a, b):
    return a * b


def safe_divide(a, b):
    if b == 0:
        raise ValueError("division by zero")
    return a / b
'''

(root / "src/mvp_app/math_ops.py").write_text(content, encoding="utf-8")

status_path = root / "docs/STATUS.md"
status_path.write_text(
    "\n".join(
        [
            "# STATUS",
            "",
            f"- phase: IMPLEMENT_TEST",
            f"- task_id: {task_id}",
            f"- worker: {os.environ.get('WORKER', '')}",
            f"- ai_mode: {ai_result.get('mode')}",
            f"- ai_note: {ai_result.get('note')}",
            f"- updated_at: {dt.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}",
            "",
        ]
    ),
    encoding="utf-8",
)
PY

python3 -m pip install -q -r requirements.txt

python3 -m pytest tests/unit -v
python3 -m pytest tests/acceptance -m "$MARKER" -v

git config user.name "$WORKER"
git config user.email "${WORKER}@local.invalid"
git add src/mvp_app/math_ops.py docs/STATUS.md
if git diff --cached --quiet; then
  echo "No changes to commit for ${TASK_ID}" >&2
  exit 1
fi

git commit -m "feat(${TASK_ID}): implement by ${WORKER} [${AI_MODE}]"
git push -u origin "$BRANCH" --force

PR_NUMBER="$(gh pr list --repo "$REPO" --head "$BRANCH" --json number -q '.[0].number // empty')"
PR_BODY=$(cat <<PRBODY
## Summary
- Worker ${WORKER} implemented ${TASK_ID} (${TASK_TYPE})

## Task Link
Closes #${ISSUE}

## Tests
- [x] pytest tests/unit -v
- [x] pytest tests/acceptance -m ${MARKER} -v

## AI
- mode: ${AI_MODE}
- payload: ${AI_RESULT}
PRBODY
)

if [[ -z "$PR_NUMBER" ]]; then
  gh pr create --repo "$REPO" --head "$BRANCH" --base main --title "feat: ${TASK_ID} by ${WORKER}" --body "$PR_BODY" >/dev/null
  PR_NUMBER="$(gh pr list --repo "$REPO" --head "$BRANCH" --json number -q '.[0].number // empty')"
  if [[ -z "$PR_NUMBER" ]]; then
    echo "Failed to resolve PR number after creation for branch ${BRANCH}" >&2
    exit 1
  fi
  PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
else
  gh pr edit "$PR_NUMBER" --repo "$REPO" --title "feat: ${TASK_ID} by ${WORKER}" --body "$PR_BODY" >/dev/null
  PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
fi

python3 - <<PY
import json
print(json.dumps({"ok": True, "repo": "${REPO}", "issue": ${ISSUE}, "task_id": "${TASK_ID}", "worker": "${WORKER}", "ai_mode": "${AI_MODE}", "marker": "${MARKER}", "branch": "${BRANCH}", "pr_number": int("${PR_NUMBER}"), "pr_url": "${PR_URL}"}, ensure_ascii=False))
PY
