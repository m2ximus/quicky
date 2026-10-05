# Quicky

A tiny menu bar screen recorder for macOS, made for quick demos.

Press a hotkey, drag over part of your screen, and a few seconds later a GIF or MP4 is on your clipboard, ready to paste into Slack, iMessage, email or a pull request. No app to wait for, no trimming, no exporting, no huge movie file left behind.

## Why

Showing someone is faster than telling them: a bug, a new feature, an animation, "click here, then here". QuickTime can do it, but it is slow to open, records far more than you need, and leaves you with a large `.mov` to trim and re-save before you can send anything.

Quicky does only the short version of that job:

- **Fast.** It lives in the menu bar and starts recording from a single hotkey.
- **Short by design.** Pick 5, 10 or 30 seconds and it stops on its own.
- **Ready to send.** The finished capture is copied to the clipboard the moment recording ends.
- **Small.** It records just the region you choose, as a compact GIF or MP4.

## How it works

1. Press `⌥⇧R` (Option-Shift-R), or click the menu bar icon and choose **Record**.
2. Drag a region, or click a window to select it. `Esc` cancels.
3. After a 3-2-1 countdown, Quicky records. The menu bar shows the time left.
4. It stops at the time limit, or when you press `⌥⇧R` again.
5. The capture is on your clipboard, and a small window lists your recent captures.

From the captures window you can drag a capture into any app, copy it again, reveal it in Finder, move it to the Trash, or double-click to open it. Files are saved to `~/Movies/Quicky/`.

## Settings

Everything is in the menu bar menu and is remembered between launches.

| Setting | Options |
|---|---|
| Format | GIF, MP4 |
| Quality | Low, Medium, High |
| Duration | 5, 10 or 30 seconds, or until you stop |
| Reuse Last Region | Skip the selection step and record the same area again |
| Keep Captures | Forever, 30 days or 7 days (older captures go to the Trash) |
| Launch at Login | Start Quicky when you log in |

GIFs play inline almost anywhere, which makes them ideal for chat and issue trackers. MP4 (H.264) is smaller and sharper, and the better choice for anything longer than a few seconds. Quicky records no audio.

## Install

Quicky is built from source. You need macOS 15 or later and the Xcode Command Line Tools (`xcode-select --install`); full Xcode is not required.

```sh
git clone https://github.com/m2ximus/quicky.git
cd quicky
./build.sh install
```

This builds `Quicky.app`, copies it to `/Applications` and launches it.

The first time you record, macOS asks for Screen Recording permission. Turn Quicky on in **System Settings › Privacy & Security › Screen & System Audio Recording**, then quit and reopen it.

Because the app is signed locally, macOS asks for that permission again after each rebuild. To avoid this, create a self-signed code-signing certificate named `Quicky Dev` in Keychain Access; `build.sh` uses it automatically.

## Development

```sh
swift test    # run the tests
./build.sh    # build build/Quicky.app without installing
```

The recording, encoding and file handling live in `Sources/QuickyCore`; the menu bar app is in `Sources/Quicky`.

## Contact

Questions or feedback: [hello@max-os.xyz](mailto:hello@max-os.xyz)
