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

SHARED = (
    "App icon for iOS, square, 1024x1024, no text, no letters, no words anywhere. "
    "A single bold flat vector glyph centred in the frame, filling about 70% of it, "
    "with a soft subtle drop shadow beneath it. The glyph is a ripe mango seen from the "
    "side — the classic lopsided teardrop silhouette with a short stem and one small leaf "
    "at the top — and the mango has been cut open down the middle so its face reads "
    "unmistakably as an open book: two curved pages meeting at a centre gutter, the page "
    "edges fanning slightly. Fruit and open book resolve as one clean shape. "
    "Flat modern iconography, generous even margins, crisp edges, perfectly centred, no "
    "outline stroke, no gloss, no 3D render, no photorealism, no rounded-rectangle frame "
    "or border drawn inside the image. The background is a smooth two-colour diagonal "
    "gradient, completely plain with no pattern or texture."
)

VARIANTS = {
    "AppIcon.png": SHARED + (
        " The glyph is very dark charcoal, almost black. The background gradient runs from "
        "warm golden mango yellow in the top-left to deep ripe mango red-orange in the "
        "bottom-right."
    ),
    "AppIcon-Dark.png": SHARED + (
        " The glyph is warm golden mango yellow fading to mango orange. The background "
        "gradient runs from very dark warm brown-black in the top-left to near-black in the "
        "bottom-right."
    ),
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
    parser.add_argument("--dry-run", action="store_true", help="print the prompts and stop")
    args = parser.parse_args()

    if args.dry_run:
        for name, prompt in VARIANTS.items():
            print(f"--- {name} ---\n{prompt}\n")
        return

    token, source = bearer_token()
    print(f"Using {source} · model {args.model} · quality {args.quality}")
    ICONSET.mkdir(parents=True, exist_ok=True)

    dark_png = b""
    for name, prompt in VARIANTS.items():
        print(f"Generating {name}…", flush=True)
        data = generate(prompt, token, args.model, args.quality, args.size)
        (ICONSET / name).write_bytes(data)
        print(f"  wrote {name} ({len(data) // 1024} KB)")
        if name == "AppIcon-Dark.png":
            dark_png = data

    if dark_png:
        tinted = derive_tinted(dark_png)
        (ICONSET / "AppIcon-Tinted.png").write_bytes(tinted)
        print(f"  wrote AppIcon-Tinted.png ({len(tinted) // 1024} KB, derived greyscale)")


if __name__ == "__main__":
    main()
