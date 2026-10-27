# Native chapter recovery audit

Start the generated, loopback-only controller from `scripts/nas-audit` first:

```sh
uv run --with impacket python scripts/nas-audit/service_control.py
uv run --with pyyaml python scripts/nas-reader-ui/run.py --udid <DEDICATED_AUDIT_SIMULATOR> --result /tmp/reader-recovery.xcresult
```

Use `--orientation landscape` for iPad Pro and `--only <testMethod>` to select a journey.
The runner verifies an Audit simulator, uses a separate `com.vanities.mangonasreaderqa`
bundle, removes App Group entitlements, and substitutes a fixture bootstrap for `MangoApp`.
It runs the production `NovelReaderView`, engine, EPUB scheme handler and SMB client against
`Audit Novel v01.epub` only. No original books, normal-app library or stored NAS credentials
are used. It does not test Sources setup or ordinary Library navigation.

`testNextChapterAfterTheConnectionWasResetKeepsReading` also needs `scripts/nas-audit/reset_proxy.py`
running with the same `--root`; the app connects through it (`QA_SMB_PORT=1448`), the proxy resets
the reader's connection, and Next chapter must load. Without `BrokenPipes.ignore()` the app exits
with SIGPIPE at that tap, as it did on the phone on 2026-10-26.

XCUITest uses the actual Next, Retry and Undo controls, presses Home, and terminates/relaunches
the QA app. Cases cover paged and scrolling chapter failures, retry before/after service
recovery, navigating away from a failed chapter, Undo and saved target restoration. Window
geometry is checked after each launch, and screenshots remain in the result bundle. Xcode
also retains recordings for some failed runs; passing video capture is not requested here.
Inspect the retained artifacts before claiming rendered UI coverage.

Only one UI run may own a simulator at a time. The host runner restores its nonce-matched
fixture service after success or failure; this avoids asynchronous XCTest teardown during a
main-actor assertion interruption. Wait for the runner to exit before starting another run.
Do not overlap these tests with either app's network audit against the same fixture share.
Ctrl-C the separately owned controller when all network checks finish. A loopback service
outage does not prove behavior on a physical NAS/VPN or diagnose an unrecorded phone crash.
