# Native library audit

The original `scripts/test-library-ui.py` creates and removes a fresh iPhone simulator.
For an existing dedicated Audit simulator, use:

```sh
uv run --with pyyaml python scripts/library-ui/run.py --udid <AUDIT_UDID> --orientation landscape --only testAllLibraryTabsOpen --result /tmp/mango-library-audit.xcresult
```

`--only` can be repeated; omit it to run all library journeys. Use portrait for iPhone/iPad
mini. The runner checks the simulator identity, holds a per-device lock, builds a temporary
project with cached per-device DerivedData, and leaves logs and screenshots for inspection.
Wait for its authoritative exit before starting another test or manual UI session on that device.

It installs `com.vanities.mangolibraryaudit`, removes App Group/other entitlements, and seeds only
the invented `demo-library` into that QA app. It refuses unmarked, nonempty Documents and leaves
the normal Mango app, real sources and stored credentials alone. The production app entry point,
RootView, library and readers run normally. `MANGO_QA_BUNDLE` selects this QA app in FlowTests;
the original runner still uses its previous `com.vanities.mangoqa` default.

Navigation checks handle both native tab buttons and the iPad sidebar cells, assert selection
and the destination navigation bar, and record native window geometry. Screenshots include
Sources' Files tips. Reader actions wake the auto-hiding controls before interacting; they do
not disable that product behavior. The novel journey selects/bookmarks a chapter, presses Home,
terminates and relaunches, and verifies the actual reader resumes that chapter/bookmark.
It checks the requested window orientation after relaunch and again in the resumed reader;
reader evidence uses the native main-screen capture, avoiding malformed app-only iPad captures.

No phone release, physical NAS behavior, actual App Group widget update, or native Face ID
authentication is established by these separate-app journeys.
