# Highlight Creator

A native macOS app for building athlete highlight reels: record plays from YouTube or Hudl by selecting the video area on screen, collect them as clips, add a player intro card, and export one finished video.

**Status: v0.1, the capture build.** Region recording and the clip library work. Player Card and Export are placeholders for the next builds.

## Install a prebuilt app

Every push to `main` is built on GitHub's macOS runners. Pushing a tag like `v0.1.0` also publishes a release. To install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install.sh | bash
```

To try a build that isn't a release yet, open the repo's **Actions** tab, pick a run, and download the **HighlightCreator** artifact.

Downloaded builds are ad-hoc signed, not notarized. The install script clears the quarantine flag for you. If you download a build by hand, right-click the app and choose **Open** the first time. Because ad-hoc builds change signature, macOS may ask for Screen Recording permission again after each update. For day-to-day use, build locally with your own signing team.

## Build from source

Requirements: macOS 26+, Xcode 26+, and XcodeGen (`brew install xcodegen`).

```bash
git clone https://github.com/mjcocat/cocut && cd cocut
make open      # generate the project and open it in Xcode
make run       # build Release from the command line and launch it
make install   # build and copy into /Applications
```

In Xcode, under **Signing & Capabilities**, set **Team** to your Personal Team. macOS ties the Screen Recording permission to the app's signature, and a stable team signature keeps that permission across rebuilds.

## Cutting a release

```bash
git tag v0.1.0 && git push origin v0.1.0
```

CI builds a universal (Apple silicon + Intel) app and attaches `HighlightCreator.zip` to a new GitHub release.

## First run

1. Click **Record Region**. macOS asks for Screen Recording permission. Turn on Highlight Creator in **System Settings › Privacy & Security › Screen & System Audio Recording**, then quit and reopen the app.
2. Open the game film in your browser.
3. Press **⇧⌘R** (or click **Record Region**). Drag over the video. Pick 16:9, 4:3, or Free, then adjust the region with the corner handles or by dragging the middle.
4. Press **Return** or click **Record**, then play the video. A red outline marks the area being captured.
5. Click **Stop** in the floating pill to save the clip, or click the trash icon to throw it away.
6. For the next play, scrub the video and press **⇧⌘L** to record the **same region** again. No re-selecting needed.

Clips are saved to `~/Movies/Highlight Creator/Clips` as 60 fps H.264 `.mov` files at full Retina resolution.

## Clip library

| Action | How |
|---|---|
| Preview | Double-click a clip, or select it and press Space |
| Rename | Right-click › Rename… |
| Delete | Select it and press ⌫, or right-click › Move to Trash… (deleted clips go to the Trash, so you can recover them) |
| Show in Finder | Right-click › Show in Finder |

## Project layout

```
HighlightCreator/
├── App/
│   ├── HighlightCreatorApp.swift   App entry, Record menu & shortcuts
│   └── AppModel.swift              Recording flow, permission, window hiding
├── Capture/
│   ├── CaptureRegion.swift         Region model + coordinate helpers
│   ├── RegionSelector.swift        Full-screen drag-to-select overlay
│   ├── RegionRecorder.swift        ScreenCaptureKit → AVAssetWriter
│   └── RecordingHUD.swift          Floating timer/Stop pill + red outline
├── Library/
│   ├── ClipLibrary.swift           Clip model, JSON index, file management
│   └── ThumbnailLoader.swift       Cached poster frames
└── Views/
    ├── ContentView.swift           Sidebar + toolbar
    ├── ClipsView.swift             Clip grid, cards, banners
    └── ClipPreviewView.swift       Playback sheet
```

## How capture works

- **Exclusions.** `SCContentFilter` excludes this app's own windows, so the selection overlay, the HUD, and the red outline never appear in your clips.
- **Region coordinates.** The region is stored as display-local points with a top-left origin, which is what `SCStreamConfiguration.sourceRect` expects. Output size is the region size times the display's pixel scale, rounded to even numbers for H.264.
- **Frame handling.** Only frames with status `.complete` are written. ScreenCaptureKit skips frames when nothing on screen changes, so on Stop the session end time is extended to the moment you pressed Stop. A clip that ends on a paused frame keeps its full length.

## Things to verify on your machine

- **DRM.** Record a few seconds from **Hudl** and from **YouTube** and play the clips back. If Hudl content comes out black, it's DRM-protected in that browser. Try another browser, or use Hudl's own download/export option and import the file (file import is on the roadmap anyway).
- **Multiple displays.** If you have a second monitor, try selecting on it.

## Roadmap

1. **Clip editing.** Trim in/out points, drag to reorder, import existing video files.
2. **Player card.** Headshot, name, grad year, position, height, club, and jersey number, rendered as a 4–5 second intro.
3. **Export.** Stitch the intro and clips into a 1080p MP4 with AVFoundation, with a progress display.
4. **Polish.**
   - A spotlight ring or arrow to mark the athlete before each play
   - Transitions and background music
   - A global hotkey to stop recording without clicking
   - An app icon
