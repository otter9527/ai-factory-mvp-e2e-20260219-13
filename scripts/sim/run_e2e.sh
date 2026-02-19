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

wait_for_checks() {
  local pr="$1"
  local sha
  sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q '.headRefOid')"
  local tries=60
  while [[ $tries -gt 0 ]]; do
    export CHECKS_JSON
    CHECKS_JSON="$(gh api "repos/${REPO}/commits/${sha}/check-runs" 2>/dev/null || true)"
    if [[ -z "$CHECKS_JSON" ]]; then
      sleep 10
      tries=$((tries - 1))
      continue
    fi

    read -r total pending failed <<<"$(python3 - <<'PY'
import json
import os

raw = os.environ.get("CHECKS_JSON", "")
if not raw.strip():
    print("0 0 0")
    raise SystemExit(0)
obj = json.loads(raw)
runs = obj.get("check_runs", [])
total = len(runs)
pending = 0
failed = 0
ok_conclusions = {"success", "neutral", "skipped"}
for run in runs:
    status = str(run.get("status") or "")
    conclusion = str(run.get("conclusion") or "")
    if status != "completed":
        pending += 1
    elif conclusion not in ok_conclusions:
        failed += 1
print(f"{total} {pending} {failed}")
PY
)"

    if [[ "$total" -eq 0 ]]; then
      sleep 10
      tries=$((tries - 1))
      continue
    fi
    if [[ "$pending" -gt 0 ]]; then
      sleep 10
      tries=$((tries - 1))
      continue
    fi
    if [[ "$failed" -gt 0 ]]; then
      echo "Checks failed for PR #${pr}" >&2
      gh pr checks "$pr" --repo "$REPO" || true
      return 1
    fi
    return 0
  done

  echo "Timed out waiting for checks on PR #${pr}" >&2
  gh pr checks "$pr" --repo "$REPO" || true
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
  gh api -X POST "repos/${REPO}/issues" \
    -f "title=${title}" \
    -f "body=${body}" \
    -f "labels[]=type/task" \
    -f "labels[]=status/${status}" \
    --jq '.number'
}

TASK1_ISSUE=$(create_task_issue "TASK-001" "IMPL" "ready" "[]" "Task 001: Implement add" "add returns correct result")
TASK2_ISSUE=$(create_task_issue "TASK-002" "IMPL" "ready" "[\"TASK-001\"]" "Task 002: Implement multiply" "multiply returns correct result")

sleep 3

python3 scripts/pm/sync_state.py --repo "$REPO" --run-id "$RUN_ID" --event "phase_mock_start"
python3 scripts/pm/dispatch_tasks.py --repo "$REPO" --run-id "$RUN_ID"

OUT1_RAW=$(scripts/worker/run_task.sh --repo "$REPO" --issue "$TASK1_ISSUE" --worker worker-a --ai-mode mock)
OUT1=$(echo "$OUT1_RAW" | tail -n 1)
PR1=$(echo "$OUT1" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pr_number"])')
wait_for_checks "$PR1"
gh pr merge "$PR1" --repo "$REPO" --squash --delete-branch
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
OUT2_RAW=$(scripts/worker/run_task.sh --repo "$REPO" --issue "$TASK2_ISSUE" --worker worker-b --ai-mode mock)
OUT2=$(echo "$OUT2_RAW" | tail -n 1)
PR2=$(echo "$OUT2" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pr_number"])')
wait_for_checks "$PR2"
gh pr merge "$PR2" --repo "$REPO" --squash --delete-branch
wait_for_merge "$PR2"

TASK3_ISSUE=""
PR3=""
REAL_NOTE="skipped"
if [[ "$REAL_MODE" == "true" ]]; then
  TASK3_ISSUE=$(create_task_issue "TASK-003" "IMPL" "ready" "[\"TASK-002\"]" "Task 003: Implement safe_divide" "safe_divide returns quotient and handles zero")
  python3 scripts/pm/dispatch_tasks.py --repo "$REPO" --run-id "$RUN_ID"
  OUT3_RAW=$(scripts/worker/run_task.sh --repo "$REPO" --issue "$TASK3_ISSUE" --worker worker-a --ai-mode real)
  OUT3=$(echo "$OUT3_RAW" | tail -n 1)
  PR3=$(echo "$OUT3" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pr_number"])')
  REAL_TASK_MODE=$(echo "$OUT3" | python3 -c 'import json,sys; print(str(json.loads(sys.stdin.read()).get("ai_mode","")))')
  wait_for_checks "$PR3"
  gh pr merge "$PR3" --repo "$REPO" --squash --delete-branch
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
