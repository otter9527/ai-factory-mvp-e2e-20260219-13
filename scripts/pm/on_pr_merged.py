#!/usr/bin/env python3
"""Post-merge hook that closes task issues and unlocks dependents."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from common import (
    add_issue_comment,
    append_event,
    extract_issue_number_from_pr_body,
    gh_api,
    issue_body_with_meta,
    issue_labels,
    parse_frontmatter,
    replace_status_labels,
    update_issue,
)


def _normalize_dep_list(raw: Any) -> list[str]:
    if isinstance(raw, list):
        return [str(x).strip() for x in raw if str(x).strip()]
    if isinstance(raw, str) and raw.strip():
        return [raw.strip()]
    return []


def _load_task_issues(repo: str) -> list[dict[str, Any]]:
    data = gh_api(f"repos/{repo}/issues?state=all&labels=type/task&per_page=100")
    if not isinstance(data, list):
        raise RuntimeError("task issue list must be a JSON array")
    return [x for x in data if isinstance(x, dict) and "pull_request" not in x]


def _task_done(issue: dict[str, Any], meta: dict[str, Any]) -> bool:
    labels = issue_labels(issue)
    return str(issue.get("state")) == "closed" or str(meta.get("status") or "") == "done" or "status/done" in labels


def _unlock_ready_tasks(repo: str, run_id: str, root: Path) -> list[int]:
    all_issues = _load_task_issues(repo)
    task_map: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
    for issue in all_issues:
        meta, _ = parse_frontmatter(str(issue.get("body") or ""))
        tid = str(meta.get("task_id") or "").strip()
        if tid:
            task_map[tid] = (issue, meta)

    unlocked: list[int] = []
    for issue in all_issues:
        if str(issue.get("state")) != "open":
            continue
        meta, _ = parse_frontmatter(str(issue.get("body") or ""))
        status = str(meta.get("status") or "")
        if status in {"in_progress", "done"}:
            continue

        deps = _normalize_dep_list(meta.get("depends_on"))
        if not deps:
            continue

        all_done = True
        for dep in deps:
            dep_entry = task_map.get(dep)
            if not dep_entry:
                all_done = False
                break
            dep_issue, dep_meta = dep_entry
            if not _task_done(dep_issue, dep_meta):
                all_done = False
                break

        if not all_done:
            continue

        meta["status"] = "ready"
        labels = replace_status_labels(issue_labels(issue), "ready")
        body = issue_body_with_meta(issue, meta)
        updated = update_issue(
            repo,
            int(issue["number"]),
            title=str(issue.get("title") or "Task"),
            body=body,
            labels=labels,
        )
        num = int(updated["number"])
        unlocked.append(num)
        add_issue_comment(repo, num, f"Dependencies resolved. Marked as `ready` by run `{run_id}`.")
        append_event(
            root,
            run_id,
            {
                "type": "unlock",
                "repo": repo,
                "entity": "issue",
                "id": num,
                "action": "ready",
                "result": "ok",
            },
        )

    return unlocked


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    pr = gh_api(f"repos/{args.repo}/pulls/{args.pr}")
    if not isinstance(pr, dict):
        print(json.dumps({"ok": False, "error": "invalid_pr"}))
        return 1

    if not pr.get("merged"):
        print(json.dumps({"ok": True, "skipped": "not_merged", "pr": args.pr}))
        return 0

    issue_number = extract_issue_number_from_pr_body(str(pr.get("body") or ""))
    if issue_number is None:
        print(json.dumps({"ok": False, "error": "missing_closes_link", "pr": args.pr}))
        return 1

    issue = gh_api(f"repos/{args.repo}/issues/{issue_number}")
    if not isinstance(issue, dict):
        print(json.dumps({"ok": False, "error": "missing_issue", "issue": issue_number}))
        return 1

    meta, _ = parse_frontmatter(str(issue.get("body") or ""))
    meta["status"] = "done"
    labels = replace_status_labels(issue_labels(issue), "done")
    body = issue_body_with_meta(issue, meta)

    update_issue(
        args.repo,
        issue_number,
        title=str(issue.get("title") or "Task"),
        body=body,
        labels=labels,
        state="closed",
    )
    add_issue_comment(args.repo, issue_number, f"Closed automatically after merge of PR #{args.pr}.")
    append_event(
        root,
        args.run_id,
        {
            "type": "pr_merged",
            "repo": args.repo,
            "entity": "pull_request",
            "id": args.pr,
            "action": "close_task",
            "result": "ok",
            "details": {"issue": issue_number},
        },
    )

    unlocked = _unlock_ready_tasks(args.repo, args.run_id, root)

    dispatch_script = Path(__file__).resolve().parent / "dispatch_tasks.py"
    proc = subprocess.run(
        [sys.executable, str(dispatch_script), "--repo", args.repo, "--run-id", args.run_id],
        check=False,
        capture_output=True,
        text=True,
    )

    print(
        json.dumps(
            {
                "ok": proc.returncode == 0,
                "repo": args.repo,
                "pr": args.pr,
                "closed_issue": issue_number,
                "unlocked": unlocked,
                "dispatch_stdout": proc.stdout.strip(),
                "dispatch_stderr": proc.stderr.strip(),
            },
            ensure_ascii=False,
        )
    )
    return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
