# Cocut

A native macOS app for building athlete highlight reels: record plays from YouTube or Hudl by selecting the video area on screen, collect them as clips, add a player intro card, and export one finished video.

**Status: v0.7.** Everything from capture to a finished reel works:
- play-to-record capture, including with the video in fullscreen
- a reorderable clip library with trimming and import
- a player card designer
- sections with optional divider cards, plus workflow tags
- a live reel preview that plays everything in order without rendering
- MP4 export with an intro card, crossfades, captions, and an end card

## Install

Cocut is signed with its own certificate rather than through the App Store, so a new Mac needs a few one-time OKs. Cocut's **Setup Guide** walks through them on first launch.

**Easiest:** open **Terminal**, paste this, and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install.sh | bash
```

**By hand:**
1. Download **Cocut.zip** from the [latest release](https://github.com/mjcocat/cocut/releases/latest), unzip it, and drag Cocut into Applications.
2. Open Cocut, click **Done** on the warning, then click **Open Anyway** in **System Settings › Privacy & Security**.
3. Follow the **Setup Guide**:
   - **Screen Recording** — required. Turn it on, then reopen Cocut.
   - **App Management** — needed for automatic updates.
   - **Player Card** — optional.

You can open the Setup Guide again any time from **Help › Setup Guide**. Each release page also repeats these steps.

This installs the latest release into `/Applications`. After that, Cocut updates itself. It checks when it opens and every few hours, and offers new versions as they appear. It never interrupts a recording: an offer found mid-recording waits until you're done. **Later** snoozes an offer for a day, and **Skip This Version** ignores it. While an update is waiting, an **Update to x.y.z** button also sits in the toolbar. You can also choose **Cocut › Check for Updates…** at any time, or turn automatic checks off in **Settings › Updates**.

### "Apple could not verify Cocut…"

CI builds aren't notarized, which requires a paid Apple Developer account. The install script and the in-app updater both avoid this warning. If you download a zip by hand, clear the warning one of two ways:

- Run `xattr -dr com.apple.quarantine /Applications/Cocut.app`.
- Or open **System Settings › Privacy & Security** and click **Open Anyway**.

**If the Dock icon just keeps bouncing** after you click **Open Anyway**, a copy held back by the first, blocked launch is still stuck and blocks new launches. Run `pkill -9 -x Cocut`, then open Cocut again.

## Recording

1. Open the game film in your browser. Pause it just before the first play.
2. Choose **Record Region…** from the menu bar icon or the **Record** button, or press **⇧⌘R** in Cocut.
3. Drag over the video. Stay inside the picture, above the player's control bar. Pick 16:9, 4:3, or Free, then adjust with the corner handles.
4. Leave **Record when video plays** on and click **Start**. A dashed outline means Cocut is waiting.
5. **Press play.** The outline turns red and a clip starts. **Pause** and the clip saves about three seconds later with a soft pop. The clip itself ends right where you paused. Scrub to the next play and press play again. Each play/pause becomes its own clip.
6. When you're done, click **Done** on the floating control next to the video. It also shows the keyboard shortcuts for the player. You can also press **⌥⌘R**, or choose **Done, Back to Cocut** from the menu bar. Cocut comes back with your new clips selected.

To record a whole display, choose **Record Full Screen** (**⇧⌘F**), or click **Use Full Screen** while selecting a region. You don't need to aim: after each clip, Cocut finds the part of the screen that moved (the video) and crops the clip to it, so the menu bar, browser, and black bars drop away. A cropped clip shows **Cropped to the video**, and **Show Full Recording** undoes it.

While a clip records, the clock stops as soon as you pause and reads **Paused · saving…** until the clip is saved.

### Recording with the video in fullscreen

When YouTube or Hudl is in fullscreen (press **F** on YouTube, **\\** on Hudl), Cocut's window and menus are out of reach. Use the system-wide shortcuts instead:

| Shortcut | Action |
|---|---|
| **⌥⌘F** | Record the full screen. Press again to finish. |
| **⌥⌘N** | Select a region over the fullscreen video. Press again to finish. |
| **⌥⌘R** | Record the last region again. Press again to finish. |

The floating control tucks into the top-right corner and stays out of the recording.

Tips:
- Click the video once, then use the keyboard. Moving the mouse over the video makes the player's controls appear in the clip.
  - **YouTube:** Space or K to play/pause, ← → to skip 5s, J L to skip 10s, , . to step frames.
  - **Hudl:** Space to play/pause. Hudl's film-study player also has C (play/pause), Z/B (skip −2s/+5s), X/V (step frames), and D/F (previous or next clip).
  - **Any site:** the ⏯ (F8) key plays and pauses the browser's video without clicking it.
- Clips include the video's sound. Turn that off with the speaker button in the selector or **Record › Record Sound**.
- Bursts shorter than two seconds, like hover animations, scrubbing, or page flicker, are ignored. Cocut also keeps your display from dimming while a session is running.
- Turn **Record when video plays** off to record immediately until you press **⌥⌘R**.

Clips are saved to `~/Movies/Cocut/Clips` as 60 fps H.264 `.mov` files at full Retina resolution.

**Clip library:**

| To | Do this |
|---|---|
| Reorder clips | Drag them in the list. The list order is the reel order. |
| Watch a clip | Select it, and it plays in the player on the right. |
| Rename a clip | Click its name under the player, or right-click › **Rename…**. |
| Trim a clip | Click **Trim** and drag the yellow handles. The original file is kept, so **Reset Trim** undoes it. |
| Delete clips | Hover a clip and click its 🗑 button, click 🗑 under the player, or press ⌫. Select several with ⌘-click or ⇧-click to delete them together. Deleted clips go to the Trash. |
| Leave a clip out of the reel | Uncheck **In Reel**, or right-click › **Leave Out of Reel**. |
| Import videos | Use **Import** (⌘I), or drag .mp4/.mov files onto the list. This works for Hudl downloads. |

## Sections and tags

**Sections** group the reel, for example Kills, Blocks, Serves:
- **+ › New Section…** adds a heading.
- Right-click selected clips › **New Section from Selection…** gathers them under a new heading.
- Drag clips under a heading, or use **Move to Section**.
- Select a heading to rename it, and to turn on its **divider card**: a short title card before that section in the exported reel. It's off by default.
- **Add new recordings and imports here** sends new clips straight into that section while you work through one kind of play.

**Tags** are for your workflow and never appear in the export:
- Click tag chips under the player, or right-click › **Tags** (works on several clips at once).
- **+ › Manage Tags…** renames, recolors, or deletes tags.
- The filter button in the list footer shows only clips with a given tag. Reordering pauses while a filter is on.

## Player Card

The **Player Card** section designs the reel's intro card, and an optional end card with contact details. You can set:
- a headshot (drag in a photo)
- name, position, class year, height, age
- club and high school with jersey numbers
- hometown, GPA, contact details
- up to six custom stats, such as approach touch or block touch

Pick a layout (Split or Centered) and a team color: one of the presets, or any color with **Custom**. The preview updates as you type, and blank fields are left off the card. Everything is saved in `~/Movies/Cocut`.

## Preview

**Preview Reel** (⌘Y, or the ▶︎ button in the toolbar) plays the whole reel in its own window, just as it will export, without rendering a file. It includes the cards, the order, trims, crops, crossfades, clip-name captions and sound. It's ready in a few seconds.
- The strip under the video shows every piece. Click or drag it to jump anywhere.
- **Space** plays and pauses. **⌘←** and **⌘→** go to the previous or next clip.
- The list on the right shows each card and clip. Click one to play from there.
- Right-click a clip in the Clips list › **Preview Reel from This Clip** to start there.
- Keep the preview open while you reorder, trim, or change settings. It notices the change and offers **Update Preview** (⌘R), then picks up where you were.

Previews play at 720p. The export uses the resolution and frame rate you pick.

## Export

The **Export** section (⌘E) shows the reel in order (intro card, included clips, end card) and its estimated length. You can choose:
- how long each card is shown
- cut or crossfade between clips
- whether to show clip names as captions
- whether to include sound
- 720p, 1080p, or 4K, at 30 or 60 fps

Click **Preview** to watch it first, or **Export Highlight Reel…** to save an MP4 (by default in `~/Movies/Cocut/Exports`). When it's done you can play it in place, share it, or show it in Finder.

## Settings

**Cocut › Settings…** adjusts how long a pause has to last before a clip is saved, the shortest clip to keep, and the save sound. It also lists every shortcut.

**If something goes wrong,** Cocut shows an alert with a **Show Log** button. The log lives at `~/Library/Logs/Cocut/Cocut.log`. You can also open it from **Help › Show Log**.

## Releases and updates

Bump `MARKETING_VERSION` in `project.yml` and push to `main`. CI builds the app and publishes a `vX.Y.Z` release with `Cocut.zip` if that version hasn't been released yet. Pushing a `v*` tag does the same.

Every push to `main` is built on GitHub's macOS runners. Each build is downloadable as an artifact from the **Actions** tab.

The updater only offers a release whose version is higher than the installed one.

The updater reads GitHub's latest release, downloads `Cocut.zip`, checks the bundle ID, swaps the app in place, and relaunches.

### Keep Screen Recording permission across updates (one-time)

macOS ties Screen Recording permission to the app's code signature. Ad-hoc CI builds get a new signature every time, so macOS would ask again after each update. Give CI a stable signing identity by running this once on your Mac:

```bash
brew install gh && gh auth login   # if you don't have the GitHub CLI yet
curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/setup-signing.sh | bash
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
│   ├── GlobalHotKey.swift    ⌥⌘R/⌥⌘F/⌥⌘N system-wide shortcuts
│   ├── AppSettings.swift     Preferences + Settings window
│   ├── Splash.swift          Launch splash
│   └── Log.swift             Unified log + ~/Library/Logs/Cocut
├── Capture/
│   ├── CaptureRegion.swift   Region model + coordinate helpers
│   ├── RegionSelector.swift  Full-screen drag-to-select overlay
│   ├── RegionRecorder.swift  ScreenCaptureKit → AVAssetWriter
│   └── RecordingBorder.swift Red outline around the captured area
├── Library/                  Clip model, JSON index, thumbnails
├── Profile/                  Player profile, card designs, editor
├── Export/                   Reel composer (AVFoundation), preview, Export screen
├── Updates/                  GitHub Releases updater + sheet
└── Views/                    Main window, clip grid, preview
```

## Roadmap

- A spotlight ring to point out the athlete at the start of a clip
- Background music under the reel
- Multiple players or reels
