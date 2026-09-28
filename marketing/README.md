# Mango App Store presentation

The en-US listing copy lives in `scripts/appstore.py` (`COPY`). The screenshots
follow SwiftBible's large feature headlines, rich gradients and rounded real app
captures, using coral over deep teal for Mango.

Each seven-frame iPhone and iPad set shows comic and EPUB reading, library and
series organization, page navigation, reading settings and chapters. All content is an invented demo library;
Sources and personal libraries were never photographed. The listing clearly says
that Mango includes no reading catalog.

## Captures and build accuracy

App Review is attached to 1.0 build 73. The screenshots were captured from the
build-59 implementation. Xcode Cloud's build-59 record identifies
source commit `28228c525ce0545e6b9528c2cd4e7eab7a5c32f9`. Captures were taken from a
separate simulator build of `cf46bba`; its app, shared code, project and dependencies
are identical to that commit (only listing documentation/scripts changed).
The screenshots focus on the core reading and organization features.

Two isolated iOS 26.5 simulators were used, with demo mode enabled. The novels use the reader's saved font scale: 220% on iPhone and 180% on iPad. The CBZs and EPUB were built from invented
Lantern Hollow and The Tin Sparrow art, with original demo prose from
`scripts/make-demo-library.py`. The demo pages are fixtures, not bundled content.

Regenerate the finished frames on macOS:

```sh
uv run --script scripts/render-store-screenshots.py
```

`screenshots.json` defines text, colors and order. `raw/` contains unretouched
simulator captures. The renderer adapts SwiftBible's layout primitives, checks text
widths and emits opaque RGB PNGs: 1320 x 2868 for iPhone and 2064 x 2752 for iPad.

## Original artwork

The following assets were generated with the built-in image generation tool.

`assets/lantern-hollow-cover.png`:

> Create an original portrait comic book cover illustration. A quiet lantern-lit harbor village at twilight, wooden bridges and cozy rooftops, distant mountains, a crescent moon. Ink and gouache editorial illustration with deep teal, midnight navy and warm amber. Beautiful detailed environment, no people. Elegant large readable title at top: LANTERN HOLLOW. Small subtitle: VOLUME 1. This is a flat full-bleed finished book cover, not a physical book mockup. No logos, no device, no app interface.

`assets/lantern-hollow-page.png`:

> An original wordless comic page, portrait format, with five clearly separated panels and cream gutters. Scene: quiet lantern-lit harbor village at twilight. Top wide panel: a harbor of cozy rooftops, distant mountains and crescent moon. Two middle panels: an open hand-drawn map on a wooden table; a glowing lantern reflected in water. Two bottom panels: a wooden bridge between houses; welcoming golden light from a small tea shop door. No people. Detailed ink and gouache illustration, deep teal, midnight navy and amber palette, rich atmosphere, polished graphic novel page. No lettering, no page numbers, no title, no logos, no app UI.

`assets/tin-sparrow-cover.png`:

> Original portrait comic book cover with the exact large readable title THE TIN SPARROW and small subtitle VOLUME 1. A beautiful brass mechanical sparrow perched on an old clock overlooking a city of copper rooftops at sunrise. No people. Rich warm coral, copper and pale gold, sophisticated ink and gouache illustration, atmospheric handcrafted detail, strong graphic composition. Flat full-bleed finished cover, no physical mockup, no app UI, no logos.

## Listing verification

The subtitle, promotional text, description and keywords were read back from ASC.
All fit Apple's limits. The marketing, support and privacy pages returned HTTP 200,
and support contact information is present. Screenshot uploads are checked for
COMPLETE delivery and correct order before resubmission. The selected build is recorded below; automatic
release after approval is preserved. See `asc-verification.json` for final state;
Waiting for Review does not mean approved or publicly available.

## Expanded feature tour

Both iPhone and iPad now have seven frames: comic reader, library, series,
page grid, reading settings, EPUB reader and EPUB chapters. The expanded demo
library includes three Lantern Hollow comic volumes, The Tin Sparrow,
Rooftop Garden and a Lantern Hollow EPUB. New captures use four-page demo CBZs;
the opening reader captures retain the earlier fourteen-page demo edition.
All are fixtures made for this presentation, not a bundled catalog.

Additional original artwork generated with the built-in image generation tool:

`assets/harbor-page-2.png`:

> Original wordless comic page in portrait format with four clearly separated panels and cream gutters. A quiet harbor adventure: top wide panel an antique sailboat leaving a lantern lit village at dawn; middle left panel closeup of a brass compass on a hand drawn sea map; middle right a seabird soaring over teal waves; bottom wide panel mysterious green island cliffs emerging from mist. No people. Sophisticated ink and gouache, deep teal and warm coral gold, polished narrative illustration. No lettering, no titles, no logos, no interface.

`assets/harbor-page-3.png`:

> Original wordless comic page in portrait format with five separated panels and cream gutters. An atmospheric exploration of a hidden island garden: wide top panel a stone archway covered with flowers and vines; two middle panels a small waterfall into a teal pool and an old brass key resting on moss; two bottom panels a winding stone stair and glowing lantern beside an open weathered wooden door. No people. Sophisticated ink and gouache, teal, jade, amber and coral colors, polished detailed graphic novel illustration. No text, logos or interface.

`assets/rooftop-cover.png`:

> Original portrait comic book cover titled ROOFTOP GARDEN in large elegant readable lettering. A lush garden of flowers and vegetables atop a red brick city building, a tiny greenhouse glowing at sunrise, copper city rooftops and distant hills. No people. Sophisticated ink and gouache illustration with coral, sage green and golden cream, beautifully detailed, inviting composition. Flat full bleed book cover, no logos, no app interface, no physical mockup.

Preview the complete sequence: [iPhone](previews/iphone.jpg) · [iPad](previews/ipad.jpg).
