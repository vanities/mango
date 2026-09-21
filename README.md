# Mango

An open-source manga and comic reader for iPhone and iPad.

It reads the comics you already have — in the Files app, in a folder you picked, or straight off
your NAS — and it never copies, moves, or renames a single one of them. No account, no catalog,
no tracking, no tip jar.

## Why

Most comic readers want to own your library: import it, duplicate it into their sandbox, then
ask you for money to see it in two columns. Mango points at your files and reads them where they
sit. If you delete the app, your library is exactly where you left it.

The NAS part is the interesting bit. A `.cbz` is a zip, and a zip keeps its index at the *end* of
the file, so with ranged reads you can open a 330 MB volume by fetching about four kilobytes and
then pull one page at a time as you read. Mango does that over SMB. Reading off the NAS is not a
download queue with a progress bar in front of it — it just opens.

## What it does

- **Reads `.cbz`, `.pdf`, and folders of loose page images.** Series, volumes and chapters are
  worked out from the filenames scanlation groups and digital releases actually use.
- **Reads off a NAS over SMB**, page by page, without downloading the volume first.
- **Right-to-left by default**, because it's a manga reader — per-comic and per-series overrides
  for the western trades in the same library.
- **Two-page spreads in landscape**, paired like a printed book, with real double-page art given
  the whole screen instead of being sliced down the middle.
- **Continuous scroll** for webtoons and long-strip scanlations.
- **Remembers where you were**, per volume, and knows which volume comes next in a run.
- Pinch zoom, double-tap zoom, tap-to-turn, keep-screen-awake.

## What it doesn't do

- **No `.cbr`.** RAR's only decoder is non-free and can't ship in a GPL-3 app. Convert them:
  `for f in *.cbr; do ...` — or grab releases as `.cbz`, which most of them are now.
- **No online catalog.** Mango reads files. It won't fetch chapters from anywhere.
- **No accounts, no sync service, no analytics.** Reading position syncs through your own iCloud.

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
