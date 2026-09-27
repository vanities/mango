# Mango

An open-source manga, comic and light novel reader for iPhone and iPad.

**[Join the TestFlight beta →](https://testflight.apple.com/join/nEjBWtgp)**

It reads the manga, comics and light novels you already have — in the Files app, in a folder you
picked, or straight off your NAS — and it never copies, moves, or renames a single one of them
unless you ask it to.
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
- **Find Cover and Look Up Series**, when you ask. Find Cover shows each volume's real cover from
  MangaDex, AniList and Apple Books (or use your own image); Look Up Series finds a messy shelf
  ("Part 5 - Vento Aureo") on AniList and, once you pick the match, puts the proper name and author
  on every volume. Only the series name — and the volume number — is sent, and only then.
- **Stacks what belongs together.** JoJo's parts sit under one *JoJo's Bizarre Adventure* stack in
  part order — even the ones named only "Part 2 - Battle Tendency" — and novels that share a name
  before " - " (Mushoku Tensei's *Jobless* and *Redundant Reincarnation*) stack too. Group With… /
  Remove From… on any series when you know better.
- **Remembers where you were**, per volume, and knows which volume comes next in a run.
- Pinch zoom, double-tap zoom, tap-to-turn, keep-screen-awake, a page grid to jump anywhere,
  **crop margins** (cuts plain scan borders, never art), **sepia / dim / night** page tints, and
  iPad keyboard turns — the arrows follow the reading direction.

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
- **No online catalog.** Mango reads files. It won't fetch chapters from anywhere — the only
  things it ever looks up online are the covers and series names you ask it to.
- **No accounts, no sync service, no analytics.** Reading position syncs through your own iCloud.

## Downloading from (and to) your NAS

**Keep one on the phone while you read, give the space back when you're done.** The ⬇︎ in the
reader's top bar downloads the volume you're reading while you keep reading; the end-of-volume
card offers "Remove download", or turn on Settings → Downloads → Remove when finished. A removed
download goes back to being read from the NAS with your place, bookmarks and rating intact.
Settings → Downloads shows what's on the device and removes the finished ones, or all of them.
Only ever a copy that's still on the NAS: nothing in a folder you picked yourself is touched.

**Open a source in Sources to manage it a series at a time.** Each series is one row with a ring
showing how much of it is on the phone; tap the ring to download the rest or remove it. Open a
series for its volumes as numbered tiles — filled is on the phone, outlined is only on the NAS —
and **Select** picks any mix of series and volumes to download or remove at once. On the phone's
own folder the ring points up instead: how much is safe on the NAS, with Upload in its menu.

Pull a single volume local from its context menu, or **Download everything** from a share.
Transfers run one at a time, survive the app being killed, and resume a half-finished file
rather than starting a 300 MB volume over. Uploads go the other way and skip anything already
on the share.

**Move into Mango** gathers a folder you added (Files › Downloads, say) into Mango's own: each
comic is copied, checked, and only then removed from where it was, keeping your place — from a
comic's menu, or a series or a selection in that folder's Sources page.

**Find Duplicates** (Sources › Tools) compares what's on the device by content, not name, so
the same volume added twice or copied in Files is caught; delete a copy and the one that stays
keeps your place. Nothing on the NAS is read or touched.

A downloaded volume replaces its copy on the share in the library rather than appearing twice,
and it takes your reading position with it — download something you're halfway through and
you're still halfway through it.

## Library tools and reading additions

Library's menu and Settings both offer:

- **Prepare for a trip:** select books, reading lists, Continue Reading or the next three
  volumes in each active series. Review size, download together, then verify after transfers
  finish. Files managed by another app may still need Keep Downloaded in Files.
- **Smart lists:** save rules for downloaded unfinished books, books untouched for 30 days,
  or books with under two hours remaining. Time estimates use your measured comic reading
  pace; novels and books without a known page count are excluded from the time rule.
- **New arrivals:** see books found after a source's initial scan, select downloads, and
  mark arrivals seen. Downloaded copies of existing books don't count as new arrivals.
- **Backup and restore:** export progress, bookmarks/highlights, notes, lists, corrections
  and chosen cover images. Restore previews matching files by path and size, keeps current
  values on conflicts and skips unmatched books. Configure media sources first on a new
  device. Media, folder permissions and NAS passwords are not restored.
- **Reconnect a folder:** preview known filenames and sizes in a new folder before keeping
  the source's identity, progress and notes. Every known item must match. A NAS source
  reconnected through Files becomes a Files-managed folder; no content hashes are compared.
  Native NAS reconnect also changes the host, share or root folder with the saved login,
  previews remote directory listings, and preserves SMB streaming and downloads.

In the **novel reader**, Chapters and Reading Settings includes Find in This Chapter.
Select a passage to save a highlight and optional note. Highlights use text anchors that
survive typography changes; open them from the chapter list or library bookmark search.
Notes can be edited from bookmark search. Whole-book text indexing is not required to open
or search the current chapter.

In the **comic reader**, Reader Settings → Select Text on This Page opens an explicit Live
Text mode. Copy text or use the system's offered text actions. Pages with no recognized text,
and devices without Live Text support, show an explanation.

Series pages flag **possible missing volumes** between known whole-numbered volumes.
Chapters, fractional specials and ambiguous collected editions do not generate guesses.
Dismiss intentional gaps; Library Tools can show dismissed gaps again. No catalog lookup
or automatic download happens in the background.

## Building

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
make gen        # generate Mango.xcodeproj from project.yml
make run        # build and launch on the simulator
make test       # unit tests
```

`python3 scripts/test-library-ui.py` checks backup export/import and novel chapter search
in a fresh simulator with an isolated app identity. Generate `demo-library` first with
`python3 scripts/make-demo-library.py`. Logs and screenshots remain in the printed temporary
directory; `--keep-simulator` keeps the test simulator for investigating a failure.

Want something to look at? `make fixtures && make install-fixtures` generates a sample library —
a couple of multi-volume series, a standalone, a PDF, an unzipped folder of pages, and a
double-page spread — and drops it into the simulator's "On My iPhone › Mango".

To run on a device, copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig` and put
your Apple Developer team in it.

## Adding your library

**From the Files app:** anything you put in "On My iPhone › Mango" is picked up on launch. Or add
any other folder — iCloud Drive, an external drive, another app's folder — in Sources.

**From a NAS:** Sources → Add NAS Share…. You need the host, the share name, and optionally a
folder inside it to treat as the top of the library:

```
Host    nas.local
Share   media
Folder  comics
```

Credentials go in the Keychain, never in the library file. Test the connection before saving.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
