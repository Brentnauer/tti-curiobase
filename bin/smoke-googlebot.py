#!/usr/bin/env python3
"""Local / staging Googlebot smoke for Curiobase.

Usage:
  python3 bin/smoke-googlebot.py [base_url]
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3000"
UA = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
FAIL = 0
TMP = Path("/tmp")


def fetch(path: str) -> tuple[int, str]:
    req = urllib.request.Request(BASE + path, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, resp.read().decode("utf-8", "ignore")


def strip_to_text(html: str) -> str:
    html = re.sub(r"<script[^>]*>.*?</script>", " ", html, flags=re.I | re.S)
    html = re.sub(r"<[^>]+>", " ", html)
    return re.sub(r"\s+", " ", html)


def check_text(text: str, needle: str) -> None:
    global FAIL
    if re.search(needle, text, flags=re.I):
        print(f"  OK text: {needle}")
    else:
        print(f"  MISS text: {needle}")
        FAIL = 1


def smoke(path: str, label: str, *needles: str) -> None:
    global FAIL
    print(f"=== {label} ===")
    try:
        code, html = fetch(path)
    except Exception as e:
        print(f"  FAIL fetch: {e}")
        FAIL = 1
        print()
        return

    print(f"  url={path} status={code} bytes={len(html)}")
    if code != 200:
        print("  FAIL http status")
        FAIL = 1
        print()
        return

    text = strip_to_text(html)
    for needle in needles:
        check_text(text, needle)

    if re.search(r"curiobase-card|curiobase-tag-banner|cb-list-scores|cb-assoc", html):
        print("  OK curiobase markup")
    else:
        print("  MISS curiobase markup")
        FAIL = 1

    if "application/ld+json" in html:
        print("  OK ld+json")
    elif label in ("work", "subject"):
        print("  MISS ld+json")
        FAIL = 1
    else:
        print("  skip ld+json (tag page)")

    if re.search(r"AggregateRating", html, flags=re.I):
        print("  FAIL AggregateRating present (structured ratings should be off for launch smoke)")
        FAIL = 1
    else:
        print("  OK no AggregateRating")

    blocks = re.findall(
        r'<script[^>]*type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        html,
        flags=re.I | re.S,
    )
    print(f"  ld_blocks={len(blocks)}")
    for i, block in enumerate(blocks[:4]):
        try:
            data = json.loads(block)
        except Exception as e:
            print(f"  ld[{i}] parse_error={e}")
            continue
        items = data if isinstance(data, list) else [data]
        for d in items:
            if not isinstance(d, dict) or not d.get("@type"):
                continue
            print(
                "  ld[{}] @type={} name={!r:.60} aggregate={} sameAs={} about={}".format(
                    i,
                    d.get("@type"),
                    (d.get("name") or "")[:60],
                    bool(d.get("aggregateRating")),
                    len(d.get("sameAs") or []),
                    len(d.get("about") or []),
                )
            )
    print()


def main() -> int:
    smoke("/t/primer-2004/31", "work", "Two engineers", "garage", r"Gravity|Central|Subject", "Primer")
    smoke("/t/john-titor/28", "subject", "John Titor", r"2036|soldier|posts")
    smoke("/tag/causal-loop", "tag", "causal")
    print("==== RESULT ====")
    if FAIL == 0:
        print("PASS — Googlebot sees cards/text; AggregateRating gated off.")
        return 0
    print("FAIL — see MISS lines above.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
