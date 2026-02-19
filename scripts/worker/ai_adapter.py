#!/usr/bin/env python3
"""AI adapter with mock and optional real API mode."""

from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.request
from typing import Any


def _extract_output_text(resp: dict[str, Any]) -> str:
    if isinstance(resp.get("output_text"), str) and resp["output_text"].strip():
        return str(resp["output_text"]).strip()
    output = resp.get("output")
    if isinstance(output, list):
        chunks: list[str] = []
        for item in output:
            if not isinstance(item, dict):
                continue
            content = item.get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if isinstance(c, dict) and isinstance(c.get("text"), str):
                    chunks.append(c["text"])
        if chunks:
            return "\n".join(chunks).strip()
    return ""


def _mock_note(task_id: str, task_type: str) -> str:
    return f"Mock planner executed for {task_id} ({task_type}). Apply deterministic implementation." 


def _real_note(task_id: str, task_type: str) -> tuple[str, bool, str]:
    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if not api_key:
        return (
            "OPENAI_API_KEY missing; fallback to deterministic local plan.",
            True,
            "no_api_key",
        )

    base_url = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")
    endpoint = f"{base_url}/responses"

    payload = {
        "model": model,
        "input": (
            "You are helping with CI-safe coding task generation. "
            f"Task: {task_id} ({task_type}). "
            "Return one concise implementation hint in <= 30 words."
        ),
    }

    req = urllib.request.Request(
        endpoint,
        method="POST",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            body = res.read().decode("utf-8")
        parsed = json.loads(body)
        note = _extract_output_text(parsed)
        if note:
            return note, False, "ok"
        return "Real API call returned empty content; fallback deterministic.", True, "empty_output"
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
        return f"Real API call failed: {exc}; fallback deterministic.", True, "api_error"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["mock", "real"], required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--task-type", required=True)
    parser.add_argument("--issue", required=True)
    parser.add_argument("--summary", default="")
    args = parser.parse_args()

    if args.mode == "mock":
        payload = {
            "ok": True,
            "mode": "mock",
            "task_id": args.task_id,
            "task_type": args.task_type,
            "issue": args.issue,
            "used_fallback": False,
            "reason": "mock",
            "note": _mock_note(args.task_id, args.task_type),
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    note, used_fallback, reason = _real_note(args.task_id, args.task_type)
    payload = {
        "ok": True,
        "mode": "real",
        "task_id": args.task_id,
        "task_type": args.task_type,
        "issue": args.issue,
        "used_fallback": used_fallback,
        "reason": reason,
        "note": note,
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
