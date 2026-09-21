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
  thumbnails in Caches (`CoverStore`) and JSON in Application Support.
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
- `PageLoader` caps how many decoded pages it holds (`prefetch * 2 + 3`) and drops the ones
  behind you first. A 2000×3000 page is 24 MB decoded — holding a dozen gets the app killed.
- Memory warnings purge everything but the visible page.

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

**Never put the Sources screen in a store screenshot** — it prints the NAS host address.
