# Mango

An open-source manga, comic and light novel reader for iPhone and iPad.

**[Join the TestFlight beta →](https://testflight.apple.com/join/nEjBWtgp)**

It reads the manga, comics and light novels you already have — in the Files app, in a folder you
picked, or straight off your NAS — and it never copies, moves, or renames a single one of them.
No account, no catalog, no tracking, no tip jar.

## Why

Most comic readers want to own your library: import it, duplicate it into their sandbox, then
ask you for money to see it in two columns. Mango points at your files and reads them where they
sit. If you delete the app, your library is exactly where you left it.

The NAS part is the interesting bit. A `.cbz` is a zip, and a zip keeps its index at the *end* of
the file, so with ranged reads you can open a 330 MB volume by fetching about four kilobytes and
then pull one page at a time as you read. Mango does that over SMB. Reading off the NAS is not a
download queue with a progress bar in front of it — it just opens.

## What it does

- **Reads `.cbz`, `.pdf`, `.epub`, and folders of loose page images.** Series, volumes and chapters are
  worked out from the filenames scanlation groups and digital releases actually use.
- **Reads off a NAS over SMB**, page by page, without downloading the volume first.
- **Right-to-left by default**, because it's a manga reader — per-comic and per-series overrides
  for the western trades in the same library.
- **Two-page spreads in landscape**, paired like a printed book, with real double-page art given
  the whole screen instead of being sliced down the middle.
- **Webtoons and long strips just work.** A book whose pages are tall strips opens straight into
  vertical scroll, full width and sharp, without you choosing anything — and your own layout
  choice for a book always wins. Scroll past the last page to finish the chapter.
- **Remembers where you were**, per volume, and knows which volume comes next in a run.
- Pinch zoom, double-tap zoom, tap-to-turn, keep-screen-awake.

## Light novels too

An EPUB is a zip with an index, same as a `.cbz`, so the same machinery reads it: point Mango
at a folder of `.epub` files and they appear under a **Novels** tab, with chapter navigation,
text size, and a position that survives changing either. Chapters and their images are pulled
out of the archive one at a time, so a light novel streams off the NAS exactly like a comic
does rather than downloading the whole book first.

Manga and light novels stay on separate shelves even when they're the same series — reading
the Mushoku Tensei manga and reading the Mushoku Tensei novels are different activities.

## What it doesn't do

- **No `.cbr`, `.cb7` or `.7z`.** RAR's only decoder is non-free and can't ship in a GPL-3 app,
  and 7z isn't supported either. Mango tells you when a source has some ("68 files in RAR or 7z
  can't be opened"), and `scripts/convert-to-cbz.sh <folder>` turns them into `.cbz` next to the
  originals — point it at the share mounted in Finder. It needs `brew install sevenzip` (or
  `unar`). Most releases ship as `.cbz` now anyway.
- **No online catalog.** Mango reads files. It won't fetch chapters from anywhere.
- **No accounts, no sync service, no analytics.** Reading position syncs through your own iCloud.

## Downloading from (and to) your NAS

Pull a volume local from the context menu, or **Download everything** from a share in Sources.
Transfers run one at a time, survive the app being killed, and resume a half-finished file
rather than starting a 300 MB volume over. Uploads go the other way and skip anything already
on the share.

A downloaded volume replaces its copy on the share in the library rather than appearing twice,
and it takes your reading position with it — download something you're halfway through and
you're still halfway through it.

## Building

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
make gen        # generate Mango.xcodeproj from project.yml
make run        # build and launch on the simulator
make test       # unit tests
```

Want something to look at? `make fixtures && make install-fixtures` generates a sample library —
a couple of multi-volume series, a standalone, a PDF, an unzipped folder of pages, and a
double-page spread — and drops it into the simulator's "On My iPhone › Mango".

To run on a device, copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig` and put
your Apple Developer team in it.

## Adding your library

**From the Files app:** anything you put in "On My iPhone › Mango" is picked up on launch. Or add
any other folder — iCloud Drive, an external drive, another app's folder — in Sources.

**From a NAS:** Sources → Add a NAS share. You need the host, the share name, and optionally a
folder inside it to treat as the top of the library:

```
Host    nas.local
Share   media
Folder  comics
```

Credentials go in the Keychain, never in the library file. Test the connection before saving.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
