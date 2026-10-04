# Quicky — design

Date: 2026-10-04

## Purpose

A lightweight macOS screen recorder for quick demos. QuickTime is slow to load, produces large files, and needs a trim/re-save step before anything can be sent. Quicky records a region for a preset time and leaves the result on the clipboard, ready to paste.

Single user, personal Mac (macOS 15, Apple silicon). Not distributed.

## Success criteria

- Hotkey to finished, pasteable capture with no export or trim step.
- A 10 second region capture is roughly 1–3 MB as video and 2–6 MB as GIF.
- Idle app is a menu bar item only: no Dock icon, no window.

## Approach

Native Swift menu bar app (AppKit + SwiftUI), built with Swift Package Manager and the Command Line Tools; no Xcode project. A build script assembles and signs `Quicky.app`.

- Capture: ScreenCaptureKit (`SCStream`), cropped to the selected region via `sourceRect`.
- Video: `AVAssetWriter`, H.264 in an `.mp4` container (plays everywhere), 30 fps, no audio.
- GIF: ImageIO (`CGImageDestination`), 15 fps, output width capped at 800 px.
- Hotkey: Carbon `RegisterEventHotKey` (no Accessibility permission needed).

## User flow

1. Global hotkey (default `⌥⇧R`) or menu bar item "Record".
2. Full-screen dimmed overlay with crosshair; drag a region. `Esc` cancels. If "Reuse last region" is on and a region is stored, this step is skipped.
3. 3-2-1 countdown, then recording. A thin border marks the region (outside the captured area); the menu bar item shows seconds remaining.
4. Stops at the duration limit, or earlier on hotkey / menu "Stop".
5. Output is encoded, saved to `~/Movies/Quicky/`, copied to the clipboard, and the results window appears.

## Settings

Stored in `UserDefaults`, changed from the menu bar menu.

| Setting | Values | Default |
|---|---|---|
| Format | GIF, Video | GIF |
| Duration | 5 s, 10 s, 30 s, until stopped | 10 s |
| Region | Draw new, Reuse last | Draw new |

"Until stopped" has a hard cap of 60 s for GIF to bound memory and file size.

## Results window

Small floating panel listing recent captures, newest first: thumbnail, format, duration, file size. Per row: drag out as a file, Copy, Reveal in Finder, Delete (moves to Trash). The list is the contents of `~/Movies/Quicky/`; there is no separate database.

## Clipboard

The pasteboard gets the file URL, plus raw GIF data (`com.compuserve.gif`) for GIFs, so pasting works in apps that accept files and apps that accept image data.

## Components

| Unit | Responsibility |
|---|---|
| `Settings` | Typed access to the persisted format, duration, region mode, last region |
| `HotKey` | Register the global hotkey, call back on press |
| `RegionSelector` | Overlay window; returns a screen rect and display, or nil on cancel |
| `Recorder` | Run an `SCStream` for a region; deliver frames to an encoder; stop on timer or request |
| `VideoEncoder` | Frames → H.264 `.mp4` |
| `GIFEncoder` | Frames → downscaled, frame-rate-limited `.gif` |
| `CaptureStore` | Output folder, file naming, listing, deleting |
| `Clipboard` | Put a capture on the pasteboard |
| `ResultsWindow` | The recent-captures panel |
| `AppDelegate` / `StatusMenu` | Menu bar item, state machine (idle → selecting → countdown → recording → encoding → idle) |

Both encoders implement one `FrameEncoder` protocol (`append(frame, time)`, `finish() -> URL`), so `Recorder` does not know the format.

## Errors

- Screen Recording permission missing: show an alert with a button that opens the System Settings pane; do not start.
- Region smaller than 16×16 pt: treat as cancel.
- Encoding or write failure: alert with the error; partial file removed.
- Hotkey pressed while encoding: ignored.

## Signing

Without a stable signature, macOS forgets the Screen Recording grant on each rebuild. The build script signs with a local self-signed code-signing certificate named `Quicky Dev` if present, otherwise ad-hoc, and prints how to create the certificate.

## Testing

- Unit tests (Swift Testing / XCTest, whichever the Command Line Tools support): `Settings` round-trip, `CaptureStore` naming/listing/deleting in a temp directory, `GIFEncoder` and `VideoEncoder` on synthetic frames (output exists, expected dimensions, frame count, duration).
- Manual: record a region in each format, paste into another app, drag from the results window.

## Added after v1 (2026-10-05)

- Window snap: in the region overlay, hovering highlights the window under the cursor and a click selects its frame. The region is the window's frame at that moment; it does not follow the window.
- Keep Captures: Forever (default), 30 Days, 7 Days. Older captures are moved to the Trash at launch, after each recording, and when the setting changes.
- Launch at Login (`SMAppService.mainApp`), and `./build.sh install` to copy the app to `/Applications`.
- Quality: Low, Medium (default), High.
  - GIF: 480 px / 10 fps, 800 px / 15 fps, 1200 px / 15 fps. "Until stopped" caps at 60 s, or 30 s at High.
  - MP4: Low records at 1x instead of Retina resolution; bit rate doubles at each step.
- Double-clicking a row in the captures window opens the file.

## Out of scope

Shareable links (planned phase 2), following a moving window, audio, trimming/editing, multi-display region spanning, configurable hotkey UI (the default is a constant in code).
