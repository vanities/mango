# iPad layout and simulator review

Read Apple's complete [Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) guidance and [Supporting multiple windows on iPad](https://developer.apple.com/documentation/uikit/supporting-multiple-windows-on-ipad) before changing the layout. Design for the available window, size class, safe areas, and text size, rather than treating device orientation as the layout model. Check portrait, landscape, and narrow windows. These apps have not gained new multiple-window support in this pass.

## Native simulator capture

The review uses iPad mini (A17 Pro) portrait (744 x 1133 pt) and iPad Pro 13-inch (M5) landscape (1376 x 1032 pt), on iPadOS 27.0. Standard iPad uses main display 1. Verify the device with `xcrun simctl list devices` and its displays with `xcrun simctl io <UDID> enumerate`; do not reuse Duo inner display 3.

An XCTest preparation sets `XCUIDevice.shared.orientation` to `.portrait` or `.landscapeLeft`, launches the app, and waits until the actual app window has the requested aspect ratio before starting recordVideo. Then the walkthrough navigates the real app. Native screenshots must have the same requested orientation: mini portrait 1488 x 2266 pixels, Pro landscape 2752 x 2064 pixels. Do not rotate a PNG/video to claim a native orientation passed.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl io <UDID> recordVideo --codec=h264 --display=1 review.mp4
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl io <UDID> screenshot --display=1 review.png
```

Use a scoped DEVELOPER_DIR; do not change global xcode-select. Native Duo APIs require the 27.1/27.2 toolchain described in [iphone-duo-testing.md](iphone-duo-testing.md). The iPad walkthroughs may use that same built binary but run on an ordinary iPad simulator. A passing CLI orientation command alone does not prove app geometry.

Python capture/package helpers run with `uv run --with pillow python`. Run one UI walkthrough per simulator at a time. Package only actual nonempty passing test cases and passing selected suites; reject assertions, empty test restarts, missing/black screenshots, or incomplete videos. Keep original pixels for PNGs. A review MP4 can be scaled for size, without rotating, cropping, or recreating the UI. Verify videos with a full FFmpeg decode and native AVFoundation playback/frame decode.

## App behavior and validation

The comic reader uses facing pages when the available window is wide enough, preserves a cover as a single page, and avoids splitting original double-page artwork. Edge taps turn pages; a center tap reveals controls. iPad mini portrait stays single-page in automatic mode. Large iPad portrait and landscape windows use facing novel pages: CSS and JavaScript share `(min-width: 900px), (min-width: 700px) and (orientation: landscape)`.

Create reader WKWebViews with NovelWebView.chapterConfiguration(), which explicitly requests mobile content mode. WebKit's recommended mode is mobile on iPhone/iPad mini and desktop on other iPads; leaving it automatic broke measured EPUB pagination on iPad Pro. All test web views use the same factory. The real-WebKit regression covers 1024 x 1366 large portrait in addition to phone, mini, and landscape sizes. All 321 unit tests pass on iPad Pro; all 13 pagination tests pass after adding the portrait case. Build 1.1 (3) matches app and widget.

Use generated demo comics/EPUBs and demo mode, which does not scan configured NAS sources. Verify reading position changes after an edge tap and rendered text becomes visible; do not hard-code a chapter if the fixture has saved reading progress. Never show real NAS hosts in review/store screenshots.

## Review artifacts

The shared workspace review is `../iphone-duo-review/2026-10-04-current/review/`, with per-app `*-ipad-mini` and `*-ipad-pro` MP4/JSON/PNG packets. `validation.json` records passing cases and source provenance; use it to distinguish historical Duo footage from the current build. The local gallery is http://127.0.0.1:8179/ when its server is running. These artifacts do not indicate an App Store Connect or TestFlight submission.
