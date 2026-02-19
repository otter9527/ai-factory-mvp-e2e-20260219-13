#!/usr/bin/env python3
"""Policy checks for pull requests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import extract_issue_number_from_pr_body, gh_api, marker_from_task_id, parse_frontmatter


def fail(msg: str) -> int:
    print(msg)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    pr = gh_api(f"repos/{args.repo}/pulls/{args.pr}")
    if not isinstance(pr, dict):
        return fail("invalid pr payload")

    issue_number = extract_issue_number_from_pr_body(str(pr.get("body") or ""))
    if issue_number is None:
        return fail("PR body must contain 'Closes #<issue_number>'")

    issue = gh_api(f"repos/{args.repo}/issues/{issue_number}")
    if not isinstance(issue, dict):
        return fail(f"Unable to read issue #{issue_number}")

    labels = []
    for item in issue.get("labels", []):
        if isinstance(item, dict):
            name = item.get("name")
            if isinstance(name, str):
                labels.append(name)

    if "type/task" not in labels:
        return fail(f"Issue #{issue_number} is missing label 'type/task'")

    meta, _ = parse_frontmatter(str(issue.get("body") or ""))
    task_id = str(meta.get("task_id") or "").strip()
    if not task_id:
        return fail(f"Issue #{issue_number} frontmatter missing task_id")

    marker = marker_from_task_id(task_id)
    if not marker:
        return fail(f"Issue #{issue_number} task_id is invalid: {task_id}")

    payload = {
        "ok": True,
        "repo": args.repo,
        "pr": args.pr,
        "issue_number": issue_number,
        "task_id": task_id,
        "marker": marker,
    }

    if args.output:
        out_path = Path(args.output)
        out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
