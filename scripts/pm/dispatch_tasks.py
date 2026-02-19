#!/usr/bin/env python3
"""Dispatch ready tasks to logical workers."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from common import (
    add_issue_comment,
    append_event,
    current_login,
    gh_api,
    issue_body_with_meta,
    issue_labels,
    load_workers,
    parse_frontmatter,
    replace_status_labels,
    replace_worker_labels,
    stable_dispatch_id,
    update_issue,
)


def _normalize_dep_list(raw: Any) -> list[str]:
    if isinstance(raw, list):
        out = [str(x).strip() for x in raw if str(x).strip()]
        return out
    if isinstance(raw, str) and raw.strip():
        return [raw.strip()]
    return []


def _load_task_issues(repo: str) -> list[dict[str, Any]]:
    data = gh_api(f"repos/{repo}/issues?state=all&labels=type/task&per_page=100")
    if not isinstance(data, list):
        raise RuntimeError("task issue list must be a JSON array")
    return [x for x in data if isinstance(x, dict) and "pull_request" not in x]


def _task_map(issues: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for issue in issues:
        meta, _ = parse_frontmatter(str(issue.get("body") or ""))
        task_id = str(meta.get("task_id") or "").strip()
        if task_id:
            out[task_id] = {"issue": issue, "meta": meta}
    return out


def _is_done(entry: dict[str, Any]) -> bool:
    issue = entry["issue"]
    meta = entry["meta"]
    labels = issue_labels(issue)
    if str(issue.get("state")) == "closed":
        return True
    if str(meta.get("status") or "").lower() == "done":
        return True
    return "status/done" in labels


def _deps_done(depends_on: list[str], lookup: dict[str, dict[str, Any]]) -> bool:
    for dep in depends_on:
        dep_entry = lookup.get(dep)
        if not dep_entry or not _is_done(dep_entry):
            return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    workers = load_workers(root)
    all_issues = _load_task_issues(args.repo)
    lookup = _task_map(all_issues)
    login = current_login()
    assignees: list[str] | None = None
    if login and not login.endswith("[bot]"):
        assignees = [login]

    in_progress_count: dict[str, int] = {name: 0 for name in workers.keys()}
    for entry in lookup.values():
        issue = entry["issue"]
        meta = entry["meta"]
        if str(meta.get("status") or "") != "in_progress":
            continue
        owner = str(meta.get("owner_worker") or "")
        if owner in in_progress_count:
            in_progress_count[owner] += 1

    dispatched: list[dict[str, Any]] = []

    for issue in all_issues:
        if str(issue.get("state")) != "open":
            continue
        meta, _ = parse_frontmatter(str(issue.get("body") or ""))
        if str(meta.get("status") or "") != "ready":
            continue

        task_type = str(meta.get("task_type") or "")
        task_id = str(meta.get("task_id") or "")
        issue_number = int(issue["number"])
        deps = _normalize_dep_list(meta.get("depends_on"))
        if deps and not _deps_done(deps, lookup):
            continue

        candidates: list[str] = []
        for worker_name, conf in workers.items():
            types = conf.get("task_types") or []
            if task_type in types:
                candidates.append(worker_name)
        if not candidates:
            continue

        worker_name = sorted(candidates, key=lambda x: (in_progress_count.get(x, 0), x))[0]
        worker_label = str(workers[worker_name].get("label") or f"worker/{worker_name}")
        dispatch_id = stable_dispatch_id(issue_number, str(issue.get("updated_at") or ""), args.run_id)

        comments = gh_api(f"repos/{args.repo}/issues/{issue_number}/comments?per_page=100")
        if not isinstance(comments, list):
            comments = []
        if any(dispatch_id in str(c.get("body") or "") for c in comments if isinstance(c, dict)):
            continue

        meta["status"] = "in_progress"
        meta["owner_worker"] = worker_name

        labels = issue_labels(issue)
        labels = replace_status_labels(labels, "in_progress")
        labels = replace_worker_labels(labels, worker_label)
        if "type/task" not in labels:
            labels.append("type/task")

        body = issue_body_with_meta(issue, meta)
        update_issue(
            args.repo,
            issue_number,
            title=str(issue.get("title") or f"Task {task_id}"),
            body=body,
            labels=labels,
            assignees=assignees,
        )

        payload = {
            "dispatch_id": dispatch_id,
            "run_id": args.run_id,
            "worker": worker_name,
            "task_id": task_id,
            "task_type": task_type,
        }
        add_issue_comment(args.repo, issue_number, f"dispatch\n```json\n{json.dumps(payload, ensure_ascii=False, indent=2)}\n```")
        append_event(
            root,
            args.run_id,
            {
                "type": "dispatch",
                "repo": args.repo,
                "entity": "issue",
                "id": issue_number,
                "action": "assigned",
                "result": "ok",
                "details": payload,
            },
        )

        in_progress_count[worker_name] = in_progress_count.get(worker_name, 0) + 1
        dispatched.append({"issue": issue_number, "worker": worker_name, "task_id": task_id})

    print(json.dumps({"ok": True, "repo": args.repo, "run_id": args.run_id, "dispatched": dispatched}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
