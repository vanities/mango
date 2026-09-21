#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests"]
# ///
"""Download Pepper&Carrot and build real .cbz files to test and demo Mango with.

Pepper&Carrot is David Revoy's libre webcomic, published under CC-BY 4.0 — genuinely free
to redistribute, unlike almost everything else in this format. Each episode becomes one
.cbz named the way a scanlation release would be, so the library looks like a real one.

    uv run --script scripts/fetch-free-comics.py --out fixtures-real --episodes 8
    uv run --script scripts/fetch-free-comics.py --list
"""

from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

import requests

BASE = "https://www.peppercarrot.com"
INDEX = f"{BASE}/en/files/episodes.html"
SERIES = "Pepper and Carrot"
ATTRIBUTION = """Pepper&Carrot by David Revoy — https://www.peppercarrot.com
Licensed CC-BY 4.0 (https://creativecommons.org/licenses/by/4.0/).
Packaged into .cbz by Mango's scripts/fetch-free-comics.py for testing.
"""


def episodes() -> list[tuple[int, str, str]]:
    """(number, slug, title) for every published episode."""
    html = requests.get(INDEX, timeout=60).text
    found: dict[int, tuple[int, str, str]] = {}
    for slug in re.findall(r"webcomic-sources/(ep(\d+)_[A-Za-z0-9\-']+)__files\.html", html):
        full, number = slug[0], int(slug[1])
        # Slugs lose apostrophes: "Pepper-s-Birthday-Party" is "Pepper's Birthday Party".
        title = full.split("_", 1)[1].replace("-s-", "'s-").replace("-", " ").strip()
        found[number] = (number, full, title)
    return [found[k] for k in sorted(found)]


def page_urls(number: int, slug: str, limit: int = 60) -> list[str]:
    """Pages are numbered until one 404s."""
    urls = []
    for page in range(1, limit + 1):
        url = f"{BASE}/0_sources/{slug}/hi-res/en_Pepper-and-Carrot_by-David-Revoy_E{number:02d}P{page:02d}.jpg"
        head = requests.head(url, timeout=30, allow_redirects=True)
        if head.status_code != 200:
            break
        urls.append(url)
    return urls


def build(number: int, slug: str, title: str, out_dir: Path) -> Path | None:
    urls = page_urls(number, slug)
    if not urls:
        print(f"  ep{number:02d}: no pages found, skipping")
        return None
    # Named like a real release so NameParser has something honest to chew on.
    safe_title = title.replace("/", "-")
    destination = out_dir / SERIES / f"{SERIES} - c{number:03d} - {safe_title} (Digital) (CC-BY).cbz"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_STORED) as archive:
        for index, url in enumerate(urls, start=1):
            data = requests.get(url, timeout=120).content
            archive.writestr(f"{index:03d}.jpg", data)
        archive.writestr("ATTRIBUTION.txt", ATTRIBUTION)
    size = destination.stat().st_size
    print(f"  ep{number:02d}: {len(urls)} pages → {destination.name} ({size // 1024} KB)")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="fixtures-real", type=Path)
    parser.add_argument("--episodes", type=int, default=8, help="how many episodes to fetch")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    found = episodes()
    if not found:
        sys.exit("couldn't read the episode index")
    if args.list:
        for number, slug, title in found:
            print(f"ep{number:02d}  {title}")
        return

    print(f"Pepper&Carrot by David Revoy (CC-BY 4.0) — {len(found)} episodes published")
    args.out.mkdir(parents=True, exist_ok=True)
    for number, slug, title in found[: args.episodes]:
        build(number, slug, title, args.out)
    print(f"\nDone. {args.out}/{SERIES}/")


if __name__ == "__main__":
    main()
