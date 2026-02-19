#!/usr/bin/env python3
"""Lightweight state sync event emitter for orchestrator."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import append_event, now_iso


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--event", default="sync")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    payload = {
        "type": "sync_state",
        "repo": args.repo,
        "run_id": args.run_id,
        "event": args.event,
        "result": "ok",
    }
    append_event(root, args.run_id, payload)
    print(json.dumps({"ok": True, "timestamp": now_iso(), **payload}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
