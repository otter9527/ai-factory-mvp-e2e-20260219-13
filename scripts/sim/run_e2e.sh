#!/usr/bin/env bash
set -euo pipefail

REPO=""
REAL_MODE="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --real-mode) REAL_MODE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: run_e2e.sh --repo <owner/name> [--real-mode true|false]" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "Run inside the mvp repository" >&2
  exit 1
fi
cd "$ROOT"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
REPORT="${ROOT}/reports/e2e-report.md"
mkdir -p "${ROOT}/reports"

wait_for_merge() {
  local pr="$1"
  local tries=80
  while [[ $tries -gt 0 ]]; do
    state=$(gh pr view "$pr" --repo "$REPO" --json state,mergedAt -q '.state')
    merged_at=$(gh pr view "$pr" --repo "$REPO" --json mergedAt -q '.mergedAt // ""')
    if [[ "$state" == "MERGED" || -n "$merged_at" ]]; then
      return 0
    fi
    sleep 10
    tries=$((tries - 1))
  done
  return 1
}

create_task_issue() {
  local task_id="$1"
  local task_type="$2"
  local status="$3"
  local depends_json="$4"
  local title="$5"
  local acceptance="$6"
  local body
  body=$(cat <<BODY
---
task_id: ${task_id}
task_type: ${task_type}
status: ${status}
depends_on: ${depends_json}
owner_worker: ""
acceptance:
  - "${acceptance}"
---

${title}
BODY
)
  gh issue create --repo "$REPO" --title "$title" --label "type/task" --label "status/${status}" --body "$body" >/tmp/e2e_issue_url.txt
  local url
  url="$(cat /tmp/e2e_issue_url.txt)"
  echo "$url" | sed -n 's#.*/issues/\([0-9]\+\).*#\1#p'
}

TASK1_ISSUE=$(create_task_issue "TASK-001" "IMPL" "ready" "[]" "Task 001: Implement add" "add returns correct result")
TASK2_ISSUE=$(create_task_issue "TASK-002" "IMPL" "ready" "[\"TASK-001\"]" "Task 002: Implement multiply" "multiply returns correct result")

python3 scripts/pm/sync_state.py --repo "$REPO" --run-id "$RUN_ID" --event "phase_mock_start"
python3 scripts/pm/dispatch_tasks.py --repo "$REPO" --run-id "$RUN_ID"

OUT1=$(scripts/worker/run_task.sh --repo "$REPO" --issue "$TASK1_ISSUE" --worker worker-a --ai-mode mock)
PR1=$(echo "$OUT1" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pr_number"])')
gh pr merge "$PR1" --repo "$REPO" --squash --delete-branch --auto
wait_for_merge "$PR1"

# wait for orchestrator to unlock TASK-002
for _ in {1..30}; do
  BODY2=$(gh issue view "$TASK2_ISSUE" --repo "$REPO" --json body -q '.body')
  export BODY2
  STATUS2=$(python3 - <<'PY'
import os
import re

text = (os.environ.get("BODY2") or "").splitlines()
status = ""
if len(text) >= 3 and text[0].strip() == "---":
    for line in text:
        m = re.match(r"^status:\s*(\S+)", line.strip())
        if m:
            status = m.group(1)
            break
print(status)
PY
)
  if [[ "$STATUS2" == "ready" || "$STATUS2" == "in_progress" ]]; then
    break
  fi
  sleep 8
done

python3 scripts/pm/dispatch_tasks.py --repo "$REPO" --run-id "$RUN_ID"
OUT2=$(scripts/worker/run_task.sh --repo "$REPO" --issue "$TASK2_ISSUE" --worker worker-b --ai-mode mock)
PR2=$(echo "$OUT2" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pr_number"])')
gh pr merge "$PR2" --repo "$REPO" --squash --delete-branch --auto
wait_for_merge "$PR2"

TASK3_ISSUE=""
PR3=""
REAL_NOTE="skipped"
if [[ "$REAL_MODE" == "true" ]]; then
  TASK3_ISSUE=$(create_task_issue "TASK-003" "IMPL" "ready" "[\"TASK-002\"]" "Task 003: Implement safe_divide" "safe_divide returns quotient and handles zero")
  python3 scripts/pm/dispatch_tasks.py --repo "$REPO" --run-id "$RUN_ID"
  OUT3=$(scripts/worker/run_task.sh --repo "$REPO" --issue "$TASK3_ISSUE" --worker worker-a --ai-mode real)
  PR3=$(echo "$OUT3" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pr_number"])')
  REAL_TASK_MODE=$(echo "$OUT3" | python3 -c 'import json,sys; print(str(json.loads(sys.stdin.read()).get("ai_mode","")))')
  gh pr merge "$PR3" --repo "$REPO" --squash --delete-branch --auto
  wait_for_merge "$PR3"
  REAL_NOTE="completed(ai_mode=${REAL_TASK_MODE})"
fi

ISSUE1_STATE=$(gh issue view "$TASK1_ISSUE" --repo "$REPO" --json state -q '.state')
ISSUE2_STATE=$(gh issue view "$TASK2_ISSUE" --repo "$REPO" --json state -q '.state')
ISSUE3_STATE="N/A"
if [[ -n "$TASK3_ISSUE" ]]; then
  ISSUE3_STATE=$(gh issue view "$TASK3_ISSUE" --repo "$REPO" --json state -q '.state')
fi

cat > "$REPORT" <<MD
# MVP E2E Report

- run_id: ${RUN_ID}
- repo: https://github.com/${REPO}
- mock_phase: completed
- real_phase: ${REAL_NOTE}

## Issues
- TASK-001 issue: #${TASK1_ISSUE} state=${ISSUE1_STATE}
- TASK-002 issue: #${TASK2_ISSUE} state=${ISSUE2_STATE}
- TASK-003 issue: ${TASK3_ISSUE:-N/A} state=${ISSUE3_STATE}

## Pull Requests
- PR1: https://github.com/${REPO}/pull/${PR1}
- PR2: https://github.com/${REPO}/pull/${PR2}
- PR3: ${PR3:+https://github.com/${REPO}/pull/${PR3}}

## Checks
- required: policy-check, unit-tests, acceptance-tests, lint-format
- expected: all merged PRs passed required checks before merge

## Conclusion
- end-to-end task dispatch and post-merge progression executed.
- refer to workflow history and issue comments for dispatch/unlock evidence.
MD

python3 - <<PY
import json
print(json.dumps({"ok": True, "repo": "${REPO}", "report": "${REPORT}", "run_id": "${RUN_ID}", "task1": ${TASK1_ISSUE}, "task2": ${TASK2_ISSUE}, "task3": "${TASK3_ISSUE}", "pr1": ${PR1}, "pr2": ${PR2}, "pr3": "${PR3}"}, ensure_ascii=False))
PY
