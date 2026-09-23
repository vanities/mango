# File arrivals — September 23, 2026

Continuation of Claude session `9f56bc8a-b23b-4129-ba90-48b7f0f7712c`.

Earmark's App Review rejection reported an empty shelf and no playback after adding files on
an iPad. Claude implemented the Earmark fix in `../earmark-sources`, added shared helpers in
`../shelfkit`, and stopped at the start of the Mango port. Those changes are being released together with this port.

Mango now watches Documents, refreshes local sources on returning to the foreground, handles
file URLs (including iOS's Inbox), and opens a scanned file in the active window. External
files stay in place. Single-file sources scan only their file and resolve directly to it.
Their filenames remain in their relative paths so different opened files have distinct sync
keys. Partial scans preserve other sources and progress; overlapping requests queue another
scan, and source lists are snapshotted across asynchronous work.

Validation:

- The new single-file scanner regression failed against the original code (zero comics).
- All 281 Mango tests passed on the iPad Air M3 simulator, including file opening/reopening
  and partial-refresh integration tests.
- ShelfKit: 67 tests, zero failures, one skipped.
- On the iPad simulator, copying a generated CBZ into Documents while Mango was running
  added it to the shelf automatically. Delivering its file URL opened the reader.
- SwiftLint and `git diff --check` passed.

Both apps pin ShelfKit 0.10.0 for release; local package paths were used only during development.

Earmark's review also requests a recording on a physical device demonstrating audio continuing
after navigating to the Home Screen. Simulator checks do not satisfy that request. Mango 1.0 build 59 is Waiting for Review (September 23). Earmark build 46 is selected for
resubmission; the physical-device recording remains outstanding. Reviewer notes were updated
in both listings, Mango's missing free price was configured, and Earmark's old screenshots
were replaced with three captures from the current app. Both versions retain manual release.
A silent simulator reference, sample MP3 and recording instructions are in Downloads/App Review 2026-09-23.
