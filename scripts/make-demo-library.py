#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate a demo library of invented series for App Store screenshots.

Nothing here is anyone's property: the series are made up, the pages are drawn by
`render-pages.swift`, and the novel prose is generated. Screenshots of a real library put
someone else's copyrighted covers on a store listing and Adam's shelf on the internet, so the
store set is built from this instead.

    uv run --script scripts/make-demo-library.py
    make demo      # generate, install into the simulator, and launch in demo mode
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RENDER = REPO / "scripts" / "render-pages.swift"

# Invented. Any resemblance to a real series is the fault of the English language.
MANGA = [
    ("Lantern Hollow", [(1, 14, 5), (2, 12, None), (3, 12, None)]),
    ("The Tin Sparrow", [(1, 10, None), (2, 10, 4)]),
    ("Sundown Cartography", [(1, 12, None)]),
]
STANDALONE = ("Quiet Machines", 8)

NOVELS = [
    ("Ashfall Almanac", [1, 2]),
]

CHAPTER_TITLES = [
    "The Long Way Down", "Salt and Iron", "What the River Kept", "Nine Empty Rooms",
    "A Map With No Edges", "The Weight of Lanterns", "Everything That Burns", "Homeward",
]

PROSE = """The corridor had not changed in the four years since she had last walked it, which
she found more unsettling than if it had. Dust gathered in the same corners. The third lamp
from the stair still guttered when the wind came off the water, and the wind always came off
the water.

She counted doors out of habit rather than need. Seven to the archive, nine to the stair,
eleven to the room where they had told her, plainly and without unkindness, that the thing she
had spent her childhood believing was simply not true.

"You came back," said the keeper, without turning around.

"I was asked to."

"You were asked four years ago." He set down the ledger and looked at her properly for the
first time. "Coming back now is a choice, not an errand. I'd rather you were honest about
which one it is."

Outside, the harbour bell rang twice and then, oddly, a third time. Neither of them mentioned
it. In the silence that followed she understood that the corridor had not changed because
nobody had been willing to be the one to change it, and that this was the whole of the problem,
and that she had walked eleven doors to arrive at something she already knew."""


def render_pages(out_dir: Path, count: int, label: str, wide: int | None) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    args = ["swift", str(RENDER), str(out_dir), str(count), label]
    if wide:
        args += ["--wide", str(wide)]
    subprocess.run(args, check=True, capture_output=True)


def pack_cbz(pages_dir: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_STORED) as archive:
        for page in sorted(pages_dir.glob("*.jpg")):
            archive.write(page, page.name)


def build_epub(destination: Path, title: str, volume: int, cover: Path) -> None:
    """A minimal but genuinely valid EPUB 3: mimetype, container, OPF, spine, chapters."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    chapters = CHAPTER_TITLES[: 6 + volume]
    manifest, spine, docs = [], [], []

    manifest.append('<item id="cover-img" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>')
    manifest.append('<item id="css" href="style.css" media-type="text/css"/>')
    for index, chapter in enumerate(chapters, start=1):
        cid = f"ch{index:02d}"
        manifest.append(f'<item id="{cid}" href="text/{cid}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="{cid}"/>')
        body = "\n".join(f"<p>{para.strip()}</p>" for para in PROSE.split("\n\n"))
        docs.append((f"text/{cid}.xhtml", f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head>
<title>{chapter}</title><link rel="stylesheet" type="text/css" href="../style.css"/>
</head><body><h1>{chapter}</h1>
{body}
</body></html>"""))

    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:demo-{title.lower().replace(' ', '-')}-{volume}</dc:identifier>
    <dc:title>{title} Vol. {volume}</dc:title>
    <dc:creator>A. Demo</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    {chr(10).join("    " + item for item in manifest)}
  </manifest>
  <spine>
    {chr(10).join("    " + item for item in spine)}
  </spine>
</package>"""

    with zipfile.ZipFile(destination, "w") as archive:
        # The spec wants mimetype first and stored, not deflated.
        archive.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>""")
        archive.writestr("OEBPS/content.opf", opf)
        archive.writestr("OEBPS/style.css", "body{font-family:Georgia,serif;line-height:1.5}h1{font-size:1.4em;margin:2em 0 1em}")
        archive.write(cover, "OEBPS/images/cover.jpg")
        for path, content in docs:
            archive.writestr(f"OEBPS/{path}", content)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=REPO / "demo-library")
    args = parser.parse_args()

    out: Path = args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    work = out / ".work"

    print("Building a demo library of invented series…")
    for series, volumes in MANGA:
        for volume, pages, wide in volumes:
            label = f"{series} v{volume}"
            pages_dir = work / f"{series}-{volume}"
            render_pages(pages_dir, pages, label, wide)
            destination = out / series / f"{series} v{volume:02d} (2026) (Digital).cbz"
            pack_cbz(pages_dir, destination)
            print(f"  {destination.relative_to(out)} ({pages} pages)")

    title, pages = STANDALONE
    pages_dir = work / title
    render_pages(pages_dir, pages, title, None)
    pack_cbz(pages_dir, out / f"{title}.cbz")
    print(f"  {title}.cbz ({pages} pages)")

    for title, volumes in NOVELS:
        cover_dir = work / f"{title}-cover"
        render_pages(cover_dir, 1, title, None)
        cover = sorted(cover_dir.glob("*.jpg"))[0]
        for volume in volumes:
            destination = out / title / f"{title} v{volume:02d} [Demo].epub"
            build_epub(destination, title, volume, cover)
            print(f"  {destination.relative_to(out)} (epub)")

    shutil.rmtree(work, ignore_errors=True)
    total = sum(1 for _ in out.rglob("*") if _.is_file())
    print(f"\nDone. {total} files in {out}.")


if __name__ == "__main__":
    main()
