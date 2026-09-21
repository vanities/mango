# Mango — agent guide

> `CLAUDE.md` is a symlink to this file.

Mango is an open-source iOS/iPadOS manga, comic and light novel reader (SwiftUI, iOS 26; the only dependency
is AMSMB2 for SMB). Its whole reason to exist: read the manga, comics and light novels you
already have, where they are — including straight off a NAS, without downloading a 300 MB volume to see page one.

It is Earmark's sibling (`../earmark`, the audiobook player) and deliberately shares its
architecture: derived library, JSON state keyed by stable ids, SMB via AMSMB2, xcodegen.

## Non-negotiables

- **Never copy, move, or rename the user's comics.** Sources are security-scoped bookmarks
  (`BookmarkStore`) or the app's own Documents folder. The only things Mango writes are cover
  thumbnails in Caches (`CoverStore`), covers the user picked in Application Support, and JSON
  in Application Support.
- **Nothing leaves the device unless the user asks.** The one exception to "talks only to your
  NAS" is Find Cover / Look Up Series, which send the series name (and volume number) to
  MangaDex, AniList and Apple's iTunes Search API when tapped — never in the background. The
  privacy page (am2.biz/mango/privacy) says exactly this; change both together.
- **No donation / tip / rating prompts. Ever.**
- **Never read a whole archive to show one page.** `ZipReader` works over `RandomAccessReader`,
  so opening a `.cbz` costs a ~4 KB tail read plus the central directory whatever the file
  weighs, and each page after that is one ranged read. This is the property that makes reading
  off a NAS usable; `ZipReaderTests.testOpeningReadsOnlyTheTailNotTheWholeFile` guards it.
- **No `.cbr`.** RAR's only decoder is non-free and can't ship in a GPL-3 app. `ImageFileTypes`
  leaves it out on purpose and `LibraryScannerTests` pins that. Convert to `.cbz` NAS-side.
- Library contents are *derived* by scanning; user state (progress, overrides, chosen covers)
  lives in `LibraryState` keyed by the stable `Comic.id` and must survive rescans.

## Layout

```
Mango/
  App/            MangoApp (SwiftUI @main), AppEnvironment (composition root)
  Models/         Comic, Series, ReadingProgress, ReaderOptions (direction/mode/fit/spread),
                  LibrarySource, NASServer, LibraryState, ComicOverride, AppSettings
  Services/
    Archive/      RandomAccessReader (Local / Remote / Data) — the seam that makes local and
                  SMB identical; ZipReader (central directory + deflate over ranged reads),
                  ComicArchive protocol + Zip/PDF/Folder implementations, ArchiveOpener,
                  ImageDecoder (downsample on decode), ImageFileTypes
    Library/      BookmarkStore, LibraryStore (JSON, salvages a moved-aside library),
                  NameParser (real-world comic filename patterns), SeriesGrouper (pure logic),
                  LibraryScanner (local + SMB walks), CoverStore, LibraryModel (@MainActor
                  @Observable source of truth) + LibraryModel+Queries
    Network/      NASClient (AMSMB2 wrapper; bounded range reads only), KeychainStore
    Reader/       PageLoader (decode, LRU cache, prefetch), SpreadLayout (pure), ReaderEngine
  Views/          Root (TabView), Library (grid/list, series detail, edit), Reader (paged,
                  continuous, controls, zoom), Sources (folders + NAS setup), Settings
MangoTests/       XCTest: name parsing, grouping, zip reading, spreads, scanning, state compat
scripts/          make-fixtures.sh + render-pages.swift (sample comics), install-fixtures.sh,
                  generate-icon.py (gpt-image-2.5-flare; OAuth token first, then API key),
                  render-icon.swift (offline CoreGraphics fallback icon)
```

## Build / run / test

The project file is generated: edit `project.yml`, then `xcodegen generate` (`make gen`).

```bash
make run          # build + launch on the iPhone simulator (xcodebuildmcp)
make run-ipad     # same on iPad — spreads only show up on a wide screen
make test         # unit tests
make lint         # SwiftLint
make fixtures && make install-fixtures   # sample comics into "On My iPhone > Mango"
```

The fixtures cover every naming pattern `NameParser` knows plus all three archive kinds: a
multi-volume series, a series whose volumes are named only `v01.cbz` (series comes from the
folder), a standalone, scanlation bracket-tag naming, an unzipped folder of loose pages, a PDF,
and a double-page spread at page 5 of Berserk v1.

Device builds need a team: copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`.

## Conventions

- Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY = complete`. Observable models are
  `@MainActor`; scanning, archive reading and decoding are `Sendable` structs and actors off
  main. Fix concurrency warnings, don't silence them — the SMB chunk callback is `@Sendable`,
  so accumulate into a locked box (`ChunkSink`), not a captured `var`.
- Logging: `os.Logger` via `Logger.<category>` (`Logger+Mango.swift`), `[scope]`-prefixed
  messages, timings via `Stopwatch`. Log boundaries, decisions, and every error with its inputs.
- Persisted types (`LibraryState` and everything inside it) must keep decoding files written by
  older builds: give new fields a default *and* decode them with `decodeIfPresent`, then add a
  case to `LibraryStateCompatTests`. `LibraryStore` moves an undecodable library aside and
  merges it back once a build can read it.
- Heuristics live in `NameParser` and `SeriesGrouper` and are unit-tested. Changing a grouping
  rule means adding a case first.
- Shelf identity uses `normalizedForIdentity` (punctuation *removed*), not
  `normalizedForMatching` (punctuation becomes a word break, which is right for search and
  wrong for identity — it splits "JoJo's" from "JoJos").
- UI is native iOS 26 (Liquid Glass). `navigationDestination` must sit outside lazy containers
  or the links silently do nothing.

## The reader

- Reading order is always page order. Right-to-left is done by flipping `layoutDirection` on the
  pager, never by reversing the page array — progress, prefetch and the slider stay in one
  coordinate system.
- `SpreadLayout` pairs pages like a printed book: cover alone, then 1-2, 3-4. A page wider than
  it is tall is a real double-page spread and takes the screen to itself, which re-syncs the
  pairing after it.
- `PageLoader` caps how many decoded pages it holds (`prefetch * 2 + 3`) *and* what they weigh
  (160 MB), dropping the ones behind you first. A 2000×3000 page is 24 MB decoded and a strip page
  can be 40 — holding a dozen gets the app killed. Its cache is keyed by page *and* sizing, so a
  layout switch can never be handed a page decoded for the other layout, whatever order the
  requests arrive in.
- Memory warnings purge everything but the visible page.
- **Crop margins** (`MarginTrimmer`) only ever cuts a side whose edge is near-white or
  near-black *and* flat, and only when that band ends inside `maxCutFraction` — a flat band that
  runs further is more likely a quiet or night panel, so that side is left whole. The trim flag
  is part of `PageLoader`'s cache key, like sizing. Paged reading only.
- The page grid's thumbnails live in their own small cache in `PageLoader`, so browsing them
  never evicts the pages being read. Page tints are display-only view modifiers.

## Covers and names from online

- **Find Cover** (`CoverSearch`, `CoverPickerView`): MangaDex first — it has a cover for *each
  volume*, ranked Japanese original, then English; AniList for the series art; Apple Books for
  retail covers (filtered to comics by genre, since "Berserk" also finds paranormal romance).
  Results must contain every searched word in one of their titles (`isRelevant`) — catalogs
  answer loosely ("Power Leveling" for "Solo Leveling").
- **Look Up Series** (`SeriesLookup`, `SeriesLookupView`): AniList, retried without edition
  words ("Goodnight Punpun Omnibus" finds nothing, "Goodnight Punpun" does); the user picks the
  match; `LibraryState.renameSeries` writes an override on every volume *and* carries the shelf's
  direction and layout to the new key, and `LibraryModel.seriesRedirects` lets an open screen
  follow the shelf (its id is its name).
- **Apple Intelligence was tried and rejected** (2026-09-21, the on-device Foundation Models,
  iOS 26). On real names it called "Part 5 - Vento Aureo" *One Piece* — twice, the second time
  when told to use only what the file name says — read "Solo Leveling 180 - Epilogue 01" as
  volume 180, and "c00-02 (v01)" as chapter 2. `NameParser` gets all of those right. Don't
  add it back for naming without a grounding step that would make it redundant.
- Picked covers live in `CoverStore.customDirectory` (Application Support), told apart by a
  `custom-` id prefix; they can't be rebuilt from page one, so they must not be in Caches.
- **Cover ids must be stable across launches** — `CoverStore.stableHex` (FNV-1a), never
  `Hasher`, which is seeded per process: with it, every launch expected a different file,
  re-extracted covers on open and orphaned the old ones. A scan that reached every source
  (and isn't demo mode) sweeps unreferenced thumbnails.

### Long strips (webtoons, manhwa)

- **Detected, not configured.** On open, if the reader hasn't chosen a layout for the book,
  `PageLoader.looksLikeLongStrip(from:)` checks the page it's about to show (plus two more only
  if that one is tall — `PageShape`: height/width ≥ 2.2, most sampled pages tall). An ordinary
  book pays one page read, which is the page about to be drawn anyway: the bytes are kept and
  the first decode reuses them (`TallPageTests` pins this). A detection is saved in
  `LibraryState.longStripComicIDs` — not in `overrides`, because it isn't the user's choice, and
  the user's choice (`ReaderEngine.chooseMode`) always beats it.
- **A layout choice is series-wide**, like reading direction (`LibraryState.seriesMode`;
  precedence in `LibraryState.mode(for:defaultMode:)`: the book's own override, its series, a
  detection, the app default). Webtoon rips sliced into short pages (800×1280) never trip the
  2.2 ratio, so choosing Continuous once has to cover every chapter.
- **Decoded width-first** (`PageSizing.fitWidth`): bounding the longest edge makes an 800×12000
  strip 273 px wide. Width-first is capped by a 64 MB per-page budget, and pages taller than
  4096 px are drawn as stacked tiles (`ImageDecoder.tiles`, which share the bitmap) because GPUs
  refuse very tall textures.
- **Laid out at real heights before anything loads.** The engine sizes every page from its
  header (`ComicArchive.pageSize`: a PDF's media box, a 64 KB prefix of a zip entry — inflated
  as far as it goes if deflated — or a file header), the pages around the start before first
  layout and the rest in the background. Without it a page arriving shoves everything below it,
  and reopening at page 30 lands inside page 29 once that one fills in.
- **Position** is the page crossing a reading line near the top (`onGeometryChange`), tracked as
  a set so a page misplaced by the first layout pass can't stick. `scrollPosition(id:)` and
  `onAppear` both get this wrong. The strip's own reports go through `readingPage(_:)`; moves
  from the slider or a bookmark bump `jumpCount`, which is the only thing the strip scrolls for —
  otherwise it chases its own reports.
- A strip starts below the Dynamic Island and scrolls under it (no `ignoresSafeArea`), and
  scrolling past the end-of-chapter footer finishes the chapter, like the paged reader's empty
  trailing slot.
- Covers: a strip's cover is the top of page one cut to 2:3 (`CoverStore.coverImage`), and
  `CoverView` draws art as an overlay on a fixed 2:3 frame so no cover shape can resize a tile.

## Releasing

**Pushing to `main` is the release path.** An Xcode Cloud workflow builds it and distributes to
both the internal and external TestFlight groups automatically, so don't also upload by hand —
that just makes a duplicate build number.

Manual builds are for when Xcode Cloud isn't an option: `make archive && make upload`.

`make upload` deliberately does **not** pass the App Store Connect API key. With it, export uses
cloud signing, which that key isn't permitted for ("Cloud signing permission error / No profiles
for com.vanities.mango were found"), and there's no local Apple Distribution certificate to fall
back on — only Apple Development. Without the key, xcodebuild uses the Apple ID signed into
Xcode and uploads fine. The key is still correct for `archive` and for every `scripts/*.py` call.

`scripts/appstore.py` manages the listing (`setup`, `screenshots --replace --display-type`,
`review`, `submit`) and `scripts/testflight.py` the beta side (`status`, `beta-info`, `groups`).
Note the API rejects `APP_IPHONE_69`: a 6.9" capture (1320×2868) goes in the `APP_IPHONE_67`
slot, and 13" iPad (2752×2064) in `APP_IPAD_PRO_3GEN_129`.

### Screenshots

**Store screenshots are taken in demo mode, never from a real library** — someone else's
copyrighted covers don't belong on a store listing and neither does Adam's shelf.

```bash
make demo SIMID=<udid>    # generates ./demo-library, installs it, launches in demo mode
```

Demo mode (`-MangoDemoMode YES`, or the toggle at the bottom of Settings) makes the scan skip
every share and picked folder and read only the app's own folder. The user's sources stay
configured, just unscanned. `scripts/make-demo-library.py` generates the content: invented
series, generated pages, generated EPUBs, a long-strip series (Rooftop Garden), nothing anyone owns.

**Never put the Sources screen in a store screenshot** — it prints the NAS host address.

iPad landscape shots need two workarounds. `simctl io screenshot` captures the raw framebuffer
without applying device rotation, so a landscape app still returns portrait dimensions —
rotate the PNG afterwards with `sips -r 90`. And the simulator can't be rotated from here (no
xcodebuildmcp preset, System Events keystrokes don't land), so temporarily narrow
`UISupportedInterfaceOrientations~ipad` to landscape only, build, capture, then restore it.
