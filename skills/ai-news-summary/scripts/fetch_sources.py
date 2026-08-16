#!/usr/bin/env python3
"""Fetch AI-news candidate items from curated sources, emit a JSON object.

Stdout: {"edition", "date", "count", "items": [{source,title,url,score,published,summary}]}
Stderr: human-readable progress/warnings.

Each source is fetched independently; a failing source logs a warning and
contributes nothing rather than aborting the run (egress to un-allow-listed
hosts will fail in-cluster — that is expected and non-fatal). Stdlib only.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET

UA = "ai-news-summary/1.0 (+https://github.com/Thurbeen/ai-news)"
TIMEOUT = 20


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:  # noqa: S310 (trusted, curated)
        return resp.read()


def get_hackernews(min_points: int) -> list[dict]:
    url = "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=50"
    try:
        data = json.loads(fetch(url))
    except Exception as exc:  # noqa: BLE001
        log(f"WARN: hackernews fetch failed: {exc}")
        return []
    items = []
    for hit in data.get("hits", []):
        points = hit.get("points") or 0
        if points < min_points:
            continue
        url_ = hit.get("url") or f"https://news.ycombinator.com/item?id={hit.get('objectID')}"
        items.append(
            {
                "source": "hackernews",
                "title": hit.get("title") or "",
                "url": url_,
                "score": points,
                "published": hit.get("created_at") or "",
                "summary": "",
            }
        )
    log(f"hackernews: {len(items)} items (min {min_points} pts)")
    return items


_ATOM = "{http://www.w3.org/2005/Atom}"


def get_arxiv(categories: list[str], max_results: int) -> list[dict]:
    items: list[dict] = []
    for cat in categories:
        url = (
            "https://export.arxiv.org/api/query?"
            f"search_query=cat:{cat}&sortBy=submittedDate&sortOrder=descending"
            f"&max_results={max_results}"
        )
        try:
            root = ET.fromstring(fetch(url))
        except Exception as exc:  # noqa: BLE001
            log(f"WARN: arxiv {cat} fetch failed: {exc}")
            continue
        n = 0
        for entry in root.findall(f"{_ATOM}entry"):
            title = (entry.findtext(f"{_ATOM}title") or "").strip().replace("\n", " ")
            link = entry.findtext(f"{_ATOM}id") or ""
            published = entry.findtext(f"{_ATOM}published") or ""
            summary = (entry.findtext(f"{_ATOM}summary") or "").strip().replace("\n", " ")
            items.append(
                {
                    "source": f"arxiv:{cat}",
                    "title": title,
                    "url": link,
                    "score": None,
                    "published": published,
                    "summary": summary[:500],
                }
            )
            n += 1
        log(f"arxiv {cat}: {n} items")
    return items


def get_rss(feeds: list[str], max_per_feed: int) -> list[dict]:
    items: list[dict] = []
    for feed in feeds:
        feed = feed.strip()
        if not feed:
            continue
        try:
            root = ET.fromstring(fetch(feed))
        except Exception as exc:  # noqa: BLE001
            log(f"WARN: rss {feed} fetch failed: {exc}")
            continue
        host = feed.split("/")[2] if "//" in feed else feed
        n = 0
        # RSS 2.0: channel/item ; Atom: entry. Feeds are typically newest-first,
        # so the first max_per_feed entries are the most recent.
        for item in root.iter():
            if n >= max_per_feed:
                break
            tag = item.tag.split("}")[-1]
            if tag not in ("item", "entry"):
                continue
            title = ""
            link = ""
            published = ""
            summary = ""
            for child in item:
                ctag = child.tag.split("}")[-1]
                if ctag == "title":
                    title = (child.text or "").strip()
                elif ctag == "link":
                    link = (child.get("href") or child.text or "").strip()
                elif ctag in ("pubDate", "published", "updated"):
                    published = published or (child.text or "").strip()
                elif ctag in ("description", "summary"):
                    summary = summary or (child.text or "").strip()
            if not title:
                continue
            items.append(
                {
                    "source": f"rss:{host}",
                    "title": title,
                    "url": link,
                    "score": None,
                    "published": published,
                    "summary": summary[:500],
                }
            )
            n += 1
        log(f"rss {host}: {n} items")
    return items


def main() -> None:
    min_points = int(os.environ.get("HN_MIN_POINTS", "100") or "100")
    arxiv_cats = (os.environ.get("ARXIV_CATEGORIES", "cs.AI cs.LG cs.CL") or "").split()
    arxiv_max = int(os.environ.get("ARXIV_MAX", "15") or "15")
    rss_feeds = [f for f in (os.environ.get("RSS_FEEDS", "") or "").split(",") if f.strip()]
    rss_max = int(os.environ.get("RSS_MAX_PER_FEED", "20") or "20")

    items: list[dict] = []
    items += get_hackernews(min_points)
    items += get_arxiv(arxiv_cats, arxiv_max)
    items += get_rss(rss_feeds, rss_max)

    out = {
        "edition": os.environ.get("EDITION", ""),
        "date": os.environ.get("NEWS_DATE", ""),
        "count": len(items),
        "items": items,
    }
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    log(f"total candidate items: {len(items)}")


if __name__ == "__main__":
    main()
