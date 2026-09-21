#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "pillow"]
# ///
"""Generate Mango's app icon with OpenAI's image API.

Family style is set by Earmark (../earmark): one bold flat charcoal glyph on a warm
gradient, soft drop shadow, no text. Mango's glyph is a mango whose cut face opens like a
two-page spread — the fruit and the book in one shape.

Auth: OPENAI_OAUTH_TOKEN is tried first, then OPENAI_API_KEY. Both are read from the
environment, then from `.env` next to this repo, then from ../game/.env (where the existing
art pipeline keeps them). Nothing is ever printed.

    uv run --script scripts/generate-icon.py
    uv run --script scripts/generate-icon.py --model gpt-image-2.5-flare --quality high
    uv run --script scripts/generate-icon.py --dry-run
"""

from __future__ import annotations

import argparse
import base64
import io
import os
import sys
from pathlib import Path

import requests
from PIL import Image, ImageEnhance

REPO = Path(__file__).resolve().parent.parent
ICONSET = REPO / "Mango/Resources/Assets.xcassets/AppIcon.appiconset"
API_URL = "https://api.openai.com/v1/images/generations"

# gpt-image-2.5, released 2026-09-08. "flare" is the fast high-quality generation variant;
# "sunburst" is tuned for multi-turn editing, which an icon generated from a prompt doesn't need.
DEFAULT_MODEL = "gpt-image-2.5-flare"

BASE = (
    "App icon for iOS, square, 1024x1024, no text, no letters, no words anywhere. "
    "A single bold flat vector glyph centred in the frame, filling about 68% of it, with a "
    "soft subtle drop shadow beneath it. Flat modern iconography, generous even margins, "
    "crisp clean edges, perfectly centred, no gloss, no 3D render, no photorealism, no "
    "rounded-rectangle frame or border drawn inside the image. The background is a smooth "
    "two-colour diagonal gradient, completely plain with no pattern or texture."
)

# Different ideas, not different colours. Adam picks one, then it gets the full light/dark set.
CONCEPTS = {
    # The fruit, confidently drawn and nothing else. Hardest to get wrong at 60px.
    "fruit": (
        "The glyph is a single ripe mango seen from the side: the classic lopsided teardrop "
        "silhouette, fuller and rounder at the bottom, tapering to a soft point, with a short "
        "stem and one simple leaf at the top. One clean solid silhouette, no interior detail, "
        "no cutouts."
    ),
    # A bookmark ribbon trailing out of the fruit — the reading cue without cutting the shape up.
    "ribbon": (
        "The glyph is a single ripe mango seen from the side, a clean lopsided teardrop "
        "silhouette with a short stem at the top, and a flat ribbon bookmark emerging from "
        "behind the top of the mango and hanging down across its face, ending in a notched "
        "V-cut tail like a bookmark ribbon in a book. The ribbon is a clearly separate solid "
        "shape in a contrasting colour, laid over the fruit."
    ),
    # The inverse of the current one: the book is the subject, the mango is the read.
    "book": (
        "The glyph is an open book seen straight on, two pages fanning up and outward from a "
        "central spine, drawn as one bold symmetrical shape, and resting in the cradle of the "
        "open pages is a small simple mango with a short stem and one leaf. Book and fruit are "
        "clearly separate solid shapes."
    ),
    # A cut mango where the flesh reads as stacked pages seen edge-on.
    "slice": (
        "The glyph is a mango cut cleanly in half and seen face on: the outer skin as a bold "
        "solid teardrop outline, and inside it the flesh drawn as a neat stack of horizontal "
        "lines like the page edges of a closed book seen from the side, with a simple oval pit "
        "at the centre. Geometric and graphic, not botanical."
    ),
}


def prompt(concept: str, glyph_colour: str, background: str) -> str:
    return f"{BASE} {CONCEPTS[concept]} The glyph is {glyph_colour}. The background gradient runs from {background}."


PALETTES = {
    "orange": (
        "very dark charcoal, almost black",
        "warm golden mango yellow in the top-left to deep ripe mango red-orange in the bottom-right",
        "warm golden mango yellow fading to mango orange",
        "very dark warm brown-black in the top-left to near-black in the bottom-right",
    ),
    "green": (
        "very dark charcoal, almost black",
        "fresh unripe-mango green in the top-left to deep leaf green in the bottom-right",
        "bright fresh mango green fading to lime",
        "very dark green-black in the top-left to near-black in the bottom-right",
    ),
    "teal": (
        "very dark charcoal, almost black",
        "bright turquoise in the top-left to deep teal in the bottom-right",
        "bright turquoise fading to aqua",
        "very dark teal-black in the top-left to near-black in the bottom-right",
    ),
    "berry": (
        "very dark charcoal, almost black",
        "vivid raspberry pink in the top-left to deep plum purple in the bottom-right",
        "vivid raspberry pink fading to warm magenta",
        "very dark plum-black in the top-left to near-black in the bottom-right",
    ),
    "indigo": (
        "very dark charcoal, almost black",
        "bright periwinkle indigo in the top-left to deep navy in the bottom-right",
        "bright periwinkle indigo fading to soft violet",
        "very dark indigo-black in the top-left to near-black in the bottom-right",
    ),
}


def variants(palette: str, concept: str) -> dict[str, str]:
    light_glyph, light_bg, dark_glyph, dark_bg = PALETTES[palette]
    return {
        "AppIcon.png": prompt(concept, light_glyph, light_bg),
        "AppIcon-Dark.png": prompt(concept, dark_glyph, dark_bg),
    }


def load_env(path: Path) -> None:
    """Minimal .env reader. Sets vars that aren't already in the environment."""
    if not path.is_file():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = line.removeprefix("export ").lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), value)


def bearer_token() -> tuple[str, str]:
    """Returns (token, which) — OAuth first, then API key, per Adam's instruction."""
    for path in (REPO / ".env", REPO.parent / "game" / ".env"):
        load_env(path)
    for name in ("OPENAI_OAUTH_TOKEN", "OPENAI_API_KEY"):
        token = os.environ.get(name)
        if token:
            return token, name
    sys.exit(
        "No credential found. Set OPENAI_OAUTH_TOKEN or OPENAI_API_KEY in the environment, "
        "in ./.env, or in ../game/.env."
    )


def generate(prompt: str, token: str, model: str, quality: str, size: str) -> bytes:
    payload = {"model": model, "prompt": prompt, "n": 1, "size": size, "quality": quality}
    response = requests.post(
        API_URL,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
        timeout=900,
    )
    if not response.ok:
        raise SystemExit(f"image API error {response.status_code}: {response.text[:400]}")
    item = response.json()["data"][0]
    if "b64_json" in item:
        return base64.b64decode(item["b64_json"])
    return requests.get(item["url"], timeout=120).content


def derive_tinted(dark_png: bytes) -> bytes:
    """iOS tinted icons are greyscale masks the system colours itself, so this is derived
    from the dark variant rather than generated — a second generation would drift."""
    image = Image.open(io.BytesIO(dark_png)).convert("RGB")
    grey = image.convert("L")
    grey = ImageEnhance.Contrast(grey).enhance(1.15)
    out = io.BytesIO()
    grey.convert("RGB").save(out, format="PNG")
    return out.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--quality", default="high")
    parser.add_argument("--size", default="1024x1024")
    parser.add_argument("--palette", default="orange", choices=sorted(PALETTES))
    parser.add_argument("--concept", default="fruit", choices=sorted(CONCEPTS))
    parser.add_argument("--only-light", action="store_true", help="just the light variant, for comparing palettes")
    parser.add_argument("--out", type=Path, default=None, help="write here instead of the iconset")
    parser.add_argument("--dry-run", action="store_true", help="print the prompts and stop")
    args = parser.parse_args()

    chosen = variants(args.palette, args.concept)
    if args.only_light:
        chosen = {"AppIcon.png": chosen["AppIcon.png"]}
    destination = args.out or ICONSET

    if args.dry_run:
        for name, prompt in chosen.items():
            print(f"--- {name} ---\n{prompt}\n")
        return

    token, source = bearer_token()
    print(f"Using {source} · {args.model} · {args.quality} · {args.concept}/{args.palette}")
    destination.mkdir(parents=True, exist_ok=True)

    dark_png = b""
    for name, prompt in chosen.items():
        print(f"Generating {name}…", flush=True)
        data = generate(prompt, token, args.model, args.quality, args.size)
        (destination / name).write_bytes(data)
        print(f"  wrote {name} ({len(data) // 1024} KB)")
        if name == "AppIcon-Dark.png":
            dark_png = data

    if dark_png:
        tinted = derive_tinted(dark_png)
        (destination / "AppIcon-Tinted.png").write_bytes(tinted)
        print(f"  wrote AppIcon-Tinted.png ({len(tinted) // 1024} KB, derived greyscale)")


if __name__ == "__main__":
    main()
