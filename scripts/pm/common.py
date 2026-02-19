#!/usr/bin/env python3
"""Shared helpers for MVP PM scripts."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run_cmd(argv: list[str], cwd: Path | None = None, input_text: str | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def gh_api(path: str, method: str = "GET", payload: dict[str, Any] | None = None) -> Any:
    argv = ["gh", "api", "-X", method, path]
    input_text = None
    if payload is not None:
        argv.extend(["--input", "-"])
        input_text = json.dumps(payload)
    code, out, err = run_cmd(argv, input_text=input_text)
    if code != 0:
        raise RuntimeError(f"gh api failed ({method} {path}): {err.strip() or out.strip()}")
    out = out.strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return out


def parse_frontmatter(markdown: str) -> tuple[dict[str, Any], str]:
    text = markdown or ""
    lines = text.splitlines()
    if len(lines) < 3 or lines[0].strip() != "---":
        return {}, text
    end = None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            end = idx
            break
    if end is None:
        return {}, text
    raw = "\n".join(lines[1:end]).strip()
    body = "\n".join(lines[end + 1 :]).lstrip("\n")
    data = yaml.safe_load(raw) if raw else {}
    if not isinstance(data, dict):
        data = {}
    return data, body


def render_frontmatter(meta: dict[str, Any], body: str) -> str:
    yaml_text = yaml.safe_dump(meta, sort_keys=False, allow_unicode=False).strip()
    body = (body or "").strip()
    if body:
        return f"---\n{yaml_text}\n---\n\n{body}\n"
    return f"---\n{yaml_text}\n---\n"


def marker_from_task_id(task_id: str) -> str:
    match = re.search(r"(\d+)", task_id or "")
    if not match:
        return ""
    return f"task_{int(match.group(1)):03d}"


def extract_issue_number_from_pr_body(body: str) -> int | None:
    match = re.search(r"(?i)closes\s+#(\d+)", body or "")
    if not match:
        return None
    return int(match.group(1))


def ensure_event_log(root: Path, run_id: str) -> Path:
    path = root / "state" / "runs" / run_id / "events.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text("", encoding="utf-8")
    return path


def append_event(root: Path, run_id: str, payload: dict[str, Any]) -> None:
    log_path = ensure_event_log(root, run_id)
    record = {"timestamp": now_iso(), **payload}
    with log_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def stable_dispatch_id(issue_number: int, issue_updated_at: str, run_id: str) -> str:
    raw = f"{issue_number}:{issue_updated_at}:{run_id}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:16]


def load_workers(root: Path) -> dict[str, Any]:
    path = root / "config" / "workers.yaml"
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "workers" not in data:
        raise ValueError("config/workers.yaml is invalid")
    workers = data["workers"]
    if not isinstance(workers, dict):
        raise ValueError("workers must be a map")
    return workers


def replace_status_labels(labels: list[str], new_status: str) -> list[str]:
    kept = [x for x in labels if not x.startswith("status/")]
    kept.append(f"status/{new_status}")
    return sorted(set(kept))


def replace_worker_labels(labels: list[str], worker_label: str) -> list[str]:
    kept = [x for x in labels if not x.startswith("worker/")]
    kept.append(worker_label)
    return sorted(set(kept))


def issue_labels(issue: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for item in issue.get("labels", []):
        if isinstance(item, dict):
            name = item.get("name")
            if isinstance(name, str):
                out.append(name)
        elif isinstance(item, str):
            out.append(item)
    return out


def parse_args_repo_run(parser: argparse.ArgumentParser) -> argparse.Namespace:
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--run-id", default=dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    return parser.parse_args()


def current_login() -> str:
    user = gh_api("user")
    if not isinstance(user, dict) or "login" not in user:
        raise RuntimeError("unable to resolve current gh login")
    return str(user["login"])


def issue_body_with_meta(issue: dict[str, Any], meta: dict[str, Any]) -> str:
    _, body = parse_frontmatter(issue.get("body") or "")
    return render_frontmatter(meta, body)


def update_issue(
    repo: str,
    issue_number: int,
    *,
    title: str,
    body: str,
    labels: list[str],
    state: str | None = None,
    assignees: list[str] | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "title": title,
        "body": body,
        "labels": labels,
    }
    if state is not None:
        payload["state"] = state
    if assignees is not None:
        payload["assignees"] = assignees
    data = gh_api(f"repos/{repo}/issues/{issue_number}", method="PATCH", payload=payload)
    if not isinstance(data, dict):
        raise RuntimeError("unexpected issue patch response")
    return data


def add_issue_comment(repo: str, issue_number: int, body: str) -> None:
    gh_api(
        f"repos/{repo}/issues/{issue_number}/comments",
        method="POST",
        payload={"body": body},
    )


if __name__ == "__main__":
    print("common.py is a library module", file=sys.stderr)
    sys.exit(1)
