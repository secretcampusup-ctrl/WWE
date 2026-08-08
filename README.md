# Video Player

An iOS app that plays online video links, with free zoom and pan.

## Features

- **Play from URL** — paste a direct video link (mp4 / m3u8 / mov / …)
- **Pinch zoom** — from 1× to 8×
- **Free pan** — drag left / right / up / down while zoomed
- **Double-tap** — quick zoom or reset
- **WebDAV** (optional) — browse and play from a NAS server
- Playback speed 0.5× … 2×, skip ±15 seconds

## How to use

1. Open the app
2. Paste a link in **Online video link**
3. Tap **Play Link**
4. On the video:
   - Pinch = zoom in/out
   - Drag (after zoom) = move around
   - Double-tap = zoom or reset
   - Single tap = show/hide controls

> Note: the link must be a **direct video file**, not a YouTube page.  
> Good examples end in `.mp4` or are HLS streams (`.m3u8`).

## Files

| File | Role |
|------|------|
| `VideoPlayerApp.swift` | App entry point |
| `ContentView.swift` | Home screen + paste URL |
| `VideoPlayerView.swift` | Player + zoom/pan |
| `AppViewModel.swift` | State + URL / WebDAV playback |
| `WebDAVClient.swift` | WebDAV connection |
| `Info.plist` | Network permissions (HTTP allowed) |

## Build

You are on **Windows** — Xcode does not run locally. Options:

1. **Mac + Xcode** — create a new SwiftUI App project and add these `.swift` files + `Info.plist`
2. **Codemagic** — use `codemagic.yaml` to build an IPA in the cloud
3. **Sideloadly** — install the IPA on your iPhone

### Quick setup on Mac

1. Xcode → New Project → App → SwiftUI
2. Copy all `.swift` files into the target
3. Set Bundle ID and Signing
4. Enable App Transport Security / Arbitrary Loads if needed (see `Info.plist`)
5. Run on a device or Simulator

## Quick test

Sample public video URL:

```
https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4
```
