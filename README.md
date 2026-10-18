# Cocut

A native macOS app for building athlete highlight reels: record plays from YouTube or Hudl by selecting the video area on screen, collect them as clips, add a player intro card, and export one finished video.

**Status: v0.2.** Region recording, the clip library, menu bar controls, and in-app updates work. Player Card and Export come next.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install.sh | bash
```

This installs the latest release into `/Applications`. After that, Cocut updates itself: choose **Cocut › Check for Updates…**, or wait for its daily check.

### "Apple could not verify Cocut…"

CI builds aren't notarized, which requires a paid Apple Developer account. The install script and the in-app updater both avoid this warning. If you download a zip by hand, clear the warning one of two ways:

- Run `xattr -dr com.apple.quarantine /Applications/Cocut.app`.
- Or open **System Settings › Privacy & Security** and click **Open Anyway**.

## Recording

1. Open the game film in your browser.
2. Choose **Record Region…** from the menu bar icon or the **Record** button, or press **⇧⌘R** in Cocut.
3. Drag over the video. Pick 16:9, 4:3, or Free, then adjust with the corner handles or by dragging the middle.
4. Press **Return** or click **Record**, then play the video. A red outline marks the captured area, and the menu bar icon shows the running time.
5. Stop with **⌥⌘R** from any app, or choose **Stop and Save** from the menu bar. **Discard Recording** throws the take away.
6. For the next play, scrub to it and press **⌥⌘R** again. It records the same region without re-selecting.

Clips are saved to `~/Movies/Cocut/Clips` as 60 fps H.264 `.mov` files at full Retina resolution.

**Clip library:**
- Double-click a clip, or select it and press Space, to preview it.
- Right-click to rename, show in Finder, or move to the Trash.

**If something goes wrong,** Cocut shows an alert with a **Show Log** button. The log lives at `~/Library/Logs/Cocut/Cocut.log`. You can also open it from **Help › Show Log**.

## Releases and updates

```bash
git tag v0.2.1 && git push origin v0.2.1
```

Every push to `main` is built on GitHub's macOS runners. Each build is downloadable as an artifact from the **Actions** tab.

A `v*` tag publishes a GitHub release with `Cocut.zip`. The tag sets the app's version, so it must be higher than the last release for the updater to offer it.

The updater reads GitHub's latest release, downloads `Cocut.zip`, checks the bundle ID, swaps the app in place, and relaunches.

### Keep Screen Recording permission across updates (one-time)

macOS ties Screen Recording permission to the app's code signature. Ad-hoc CI builds get a new signature every time, so macOS would ask again after each update. Give CI a stable signing identity by running this once on your Mac:

```bash
brew install gh && gh auth login   # if you don't have the GitHub CLI yet
./scripts/setup-signing.sh
```

This creates a self-signed "Cocut Self-Signed" certificate and stores it as the `COCUT_CERT_P12` and `COCUT_CERT_PASSWORD` repository secrets. Builds after that are all signed with it. You grant permission one last time, and it then sticks.

## Build from source

Requirements: macOS 26+, Xcode 26+, and XcodeGen (`brew install xcodegen`).

```bash
git clone https://github.com/mjcocat/cocut && cd cocut
make open      # generate the project and open it in Xcode
make run       # build Release from the command line and launch it
make install   # build and copy into /Applications
```

In Xcode, under **Signing & Capabilities**, set **Team** to your Personal Team.

## Project layout

```
Cocut/
├── App/
│   ├── CocutApp.swift        App entry, menus, menu bar extra
│   ├── AppModel.swift        Recording flow, permission, errors
│   ├── MenuBar.swift         Menu bar icon + menu
│   ├── GlobalHotKey.swift    ⌥⌘R system-wide shortcut
│   └── Log.swift             Unified log + ~/Library/Logs/Cocut
├── Capture/
│   ├── CaptureRegion.swift   Region model + coordinate helpers
│   ├── RegionSelector.swift  Full-screen drag-to-select overlay
│   ├── RegionRecorder.swift  ScreenCaptureKit → AVAssetWriter
│   └── RecordingBorder.swift Red outline around the captured area
├── Library/                  Clip model, JSON index, thumbnails
├── Updates/                  GitHub Releases updater + sheet
└── Views/                    Main window, clip grid, preview
```

## Roadmap

1. **Clip editing.** Trim in/out points, drag to reorder, import existing video files.
2. **Player card.** Headshot, name, grad year, position, height, club, and jersey number, rendered as a 4–5 second intro.
3. **Export.** Stitch the intro and clips into a 1080p MP4 with progress.
4. **Polish.** A spotlight ring on the athlete, transitions, music, and an app icon.
