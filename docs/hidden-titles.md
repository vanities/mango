# Hidden manga and novels

In Library, open the **•••** menu and choose **Hide titles…**. Check any number of
series, switch between Manga and Novels, or search to narrow the list. **Select All
Shown** adds the displayed results to the selection; switching media or searching
keeps previous selections. **Hide N** hides all selected series together.

The existing **Hide Series** menu and a volume's **Hide** action still work. Hiding
a series also hides volumes added to it later. Hiding never moves, deletes, or
changes the source files, and preserves progress, bookmarks, notes, and covers.

## Unlocking and rehiding

**Unlock Hidden** appears in Library when there are hidden titles. It temporarily
reveals them in Library, Continue Reading, search, reading lists, and the source
browser. Settings → Privacy → Hidden uses the same unlock. When App Lock is on,
unlocking requires the device's authentication; with App Lock off, it takes one tap.

Hidden selections remain saved while unlocked. **Hide Hidden Titles** relocks
immediately. Titles also hide again:

- When Mango enters the background.
- After three hours without activity, even if Mango stays open.
- On a fresh launch.
- When another title or selection is hidden.

Returning after an expired session does not reset the timer or reveal titles.
Library taps and scrolling, and reading progress, refresh a session that is still
unlocked. An inactive transition during device authentication does not relock it.

On relock, an open hidden reader closes and saves its position. An open hidden
series page conceals its contents and offers the unlock again. A separate opaque
window covers readers and sheets during inactive/background transitions so an
app-switcher snapshot does not expose a page or a hidden title.

In Settings → Privacy → Hidden, **Unhide** permanently removes a saved selection;
it differs from the temporary session unlock. To unhide one volume in a hidden
series, also unhide that series.

## State and external surfaces

- `LibraryState.hiddenSeries` and `hiddenComicIDs` are the persisted selections.
  Existing library JSON needs no schema change.
- `HiddenContentSession` is memory-only. Neither JSON nor UserDefaults stores its
  unlock or timer. `LibraryModel` owns the shared gate and expiration task.
- `visibleComics` applies the saved selections while locked and supplies the
  derived library and Continue Reading. `ReaderRouter` also checks the active
  volume, including a reader that advanced to the next volume.
- Widgets and Siri/Shortcuts use `publicComics`, `publicContinueReading`, and
  `publicLastRead`. They always exclude hidden titles, including while unlocked.
  Widget publication clears old covers when there is no eligible title or cover.
- `RootView` forwards scene phase to both the hidden gate and ShelfKit App Lock.
  `HiddenContentShield` sits below the App Lock window and covers full-screen
  presentations without becoming the key window.

## Verification

`HiddenContentSessionTests` checks initial locking, the exact three-hour boundary,
activity renewal, expiry before return activity, and explicit relocking.
`HiddenLibraryTests` checks bulk manga/novel filtering, search and Continue Reading,
unchanged progress and selections, inactive/background transitions, queued-reader
expiry, public widget/Siri candidates, fresh-launch locking, new volumes, individual
volume hiding, and hiding another title while already unlocked.

Before release, run the Mango suite and check the picker, unlock, manga and novel
readers, background/return, and App Lock authentication on a simulator or device.
Use synthetic demo titles for recordings and confirm the switcher snapshot is
opaque with a full-screen reader and with a sheet open. Follow the iPad and Duo
testing guides for device geometry and captures.
