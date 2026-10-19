# Cocut

A native macOS app for building athlete highlight reels: record plays from YouTube or Hudl by selecting the video area on screen, collect them as clips, add a player intro card, and export one finished video.

**Status: v0.17.** Everything from capture to a finished reel works on the Mac, and an iPhone/iPad version is in testing (see [iPhone and iPad](#iphone-and-ipad)):
- play-to-record capture, including with the video in fullscreen
- a reorderable clip library with trimming and import
- a player card designer
- sections with optional divider cards, plus workflow tags
- a live reel preview that plays everything in order without rendering
- Find Rallies: turns a full match video into just its rallies
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

## Getting started

An empty project opens on **Get Started**, which shows the three ways to get film in:
- **A full match video** (camera, phone, Hudl download): opens **Find Rallies**, which cuts out the dead time.
- **Clips you already have:** opens **Import**.
- **Film on YouTube or Hudl:** starts **Record Region**.

It also shows what comes after: rate, spotlight, Player Card, Preview, Export. **New Project…** is a two-step wizard. First, name the project and either keep the same athlete or enter a new one (name, number, position, team color), which pre-fills the Player Card. Then pick where your film is, and **Create** goes straight into it.

## Projects

Each **project** has its own clips, sections, tags, roster and Player Card, for example one per season, team or athlete ("Fall 2026 Club", "HS Season"). Use the project menu at the top of the sidebar to switch, create, rename, show in Finder, or delete (to the Trash). A new project can start with a copy of the current Player Card. Your existing library becomes the first project automatically. Projects live in `~/Movies/Cocut/Projects`.

## Recording

1. Open the game film in your browser. Pause it just before the first play.
2. Click **Record** in the toolbar and choose **Region…** (or **Full Screen**, or **Same Region Again**). The menu bar icon and **⇧⌘R** work too.
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
| Reorder clips | Drag them in the list by the ☰ grip (or anywhere on the row). The list order is the reel order. |
| Watch a clip | Select it, and it plays in the player on the right. |
| Rename a clip | Click its name under the player, or right-click › **Rename…**. |
| Trim a clip | Click **Trim** and drag the yellow handles. The original file is kept, so **Reset Trim** undoes it. |
| Delete clips | Hover a clip and click its 🗑 button, click 🗑 under the player, or press ⌫. Select several with ⌘-click or ⇧-click to delete them together. Deleted clips go to the Trash. |
| Leave a clip out of the reel | Uncheck **In Reel**, or right-click › **Leave Out of Reel**. |
| Import videos | Use **Import** (⌘I), or drag .mp4/.mov files onto the list. This works for Hudl downloads. |

## Find Rallies in a full match

**Find Rallies** (⇧⌘M, or the 🏐 toolbar button) takes a whole match video and finds the rallies, so an hour of film becomes about 15–25 minutes of play.

1. Choose the match video (or drop it on the window).
2. **Mark your court:** on a frame of the match, drag the yellow box over the air above your court, from the top of the net up and between the antennas. Cocut only looks for the ball there, so neighboring courts, the crowd and players walking between points are ignored. It remembers the box for next time; **Skip (Automatic)** uses the whole top of the picture. **Court Area…** in the bottom bar redoes it later (and finds the rallies again). Cocut then analyzes the match on your Mac, which takes a few minutes for an hour of video.
3. Review: the strip under the video shows the whole match, with each rally as a blue block. **Rallies only** plays the rallies back to back, skipping dead time. Checked rallies are the ones you keep. Use **Keep: All** to start with everything and uncheck the duds, or **Keep: None** to watch them all and check only the plays you want. Select a rally to nudge its start or end, or set either to the playhead. **Add Rally Here** adds one it missed.
4. Choose **Add to Clips** to make every kept rally a clip, in a new section named after the match, ready to tag and use in a reel. Or choose **Export Condensed Match…** to save the rallies back to back as one video.

**Players in each rally.** While finding rallies, Cocut also reads jersey numbers, twice a second, using the Mac's built-in text recognition. Each rally lists the players it saw, like "#15 #50 #30".
- **All Players › #15** in the rally list shows only rallies with #15. **Rallies only** playback, **Add to Clips**, and **Export Condensed Match** then use just those.
- A number has to be read at least twice in a rally to count. With a **Team Roster**, only roster numbers count; without one, only numbers seen in at least two rallies do. That leaves out referees and passers-by.
- Missed someone? Select the rally and type their number in the players row. Remove a wrong one with its ×.
- Cocut follows each nearby player through the rally (body-pose detection plus appearance), so a number read once labels that player for as long as they're followed.
- **Teach a Player…** finds a player whose number is hard to read (a lone "1", a libero's number). Pause on a moment they're in, choose **Teach a Player…**, click them (or drag a box around them), type their number and choose **Teach**. Every frame they were followed in that rally becomes an example. Cocut finds them in every rally by how they look, comparing against the players whose numbers it did read, so teammates in the same uniform are told apart. Teach the same player at two or three moments (facing toward and away) for better matches. The **Looser/Stricter** slider shows how many rallies each taught player is found in.
- Rallies added to Clips keep their players. In Clips, the filter's **Player** section finds every clip with that player.
- Numbers on backs facing the camera read best. Import matches at **1080p or better**: at 720p, front-row numbers are often too small to read.

How it works: from a fixed camera, the walls and ceiling above the net never move. During a rally the ball keeps crossing that area, so Cocut looks for a small, fast object there. The referee's whistle (a steady tone around 3–4 kHz) marks where each rally starts and ends. Each rally starts just before the serve. Turn on **Include serve setup** to start at the serve whistle instead (at most 5 seconds earlier), showing the server getting ready.

Works best with:
- a tripod behind the end line that doesn't pan or zoom
- some wall or ceiling visible above the net
- the sound kept

A handheld or panning camera confuses it.

## Sections and tags

**Sections** group the reel, for example Kills, Blocks, Serves:
- **+ › New Section…** adds a heading.
- Right-click selected clips › **New Section from Selection…** gathers them under a new heading.
- Drag clips under a heading, or use **Move to Section**.
- Select a heading to rename it, and to turn on its **divider card**: a short title card before that section in the exported reel. It's off by default.
- **Add new recordings and imports here** sends new clips straight into that section while you work through one kind of play.

**Players** (jersey numbers) can be listed on each clip, from Find Rallies or typed under the player. The filter button's **Player** section shows every clip with that player. **+ › Team Roster…** adds names, so numbers read "#11 Lilah".

**Spotlight** your athlete so coaches know who to watch. Select a clip and click **Spotlight** under the player. Cocut shows the clip's first frame: click your athlete, drag to fine-tune, and size the ring with the slider. **Save & Next** (Return) saves and moves to the next clip, so circling every rally goes quickly. In the reel, that first frame holds for about 1.4 seconds while the rest of the picture dims and a ring in your team color snaps in around the athlete; then play rolls. Set the clip's trim so it starts on a good frame. Choose the **shape** (a tall oval that fits a standing player, or a circle) and **color** (your team color, or any color) right in the spotlight editor or under **Export**; they apply to every spotlight in the reel. Reel Preview shows spotlights too, and **Export › Player spotlights** turns them all off at once.

**Ratings** put your best plays first. Coaches often watch only the first 30–60 seconds.
- Rate a clip with the stars under the player, or select clips and press **1–5** (**0** clears). Right-click › **Rating** works on several clips at once.
- The **Sort** button (↑↓) in the list footer › **Best Rated First** sorts each section best-first. Unrated clips go last, and ties keep their order.
- The filter's **Rating** section shows only ★★★★★, 4+ or 3+ clips.

**Undo and redo** (⌘Z, ⇧⌘Z, or the ↶ ↷ toolbar buttons) cover your clip edits: renames, trims, ratings, deletes, reordering, sections, tags and players. Undoing a delete brings the file back from the Trash. In Find Rallies, ⌘Z undoes rally edits (keep/leave out, start/end, players, added rallies).

**Tags** are for your workflow and never appear in the export:
- Click tag chips under the player, or right-click › **Tags** (works on several clips at once).
- **+ › Manage Tags…** renames, recolors, or deletes tags.
- The filter button in the list footer shows only clips with a given tag. Reordering pauses while any filter is on.

## Player Card

The **Player Card** section designs the reel's intro card, and an optional end card with contact details. You can set:
- a headshot (drag in a photo)
- name, position, class year, height, age
- club and high school with jersey numbers
- hometown, GPA, contact details
- up to six custom stats, such as approach touch or block touch

Pick a **layout** and a **theme** from the live thumbnails, and a team color: one of the presets, or any color with **Custom**.
- **Layouts:** Split, Centered, Poster (full-height photo with your number behind the name), Jersey (a giant number as the backdrop) and Minimal (a clean stat sheet).
- **Themes:** Night, Light, Team Color (the whole card in your team color) and Varsity (cream with stripes and serif type).
- Every layout works with every theme. Text colors adjust so light team colors like gold stay readable, and section divider and end cards follow the theme too.
 The preview updates as you type, and blank fields are left off the card. Everything is saved in `~/Movies/Cocut`.

## Preview

**Preview Reel** (⌘Y, or the ▶︎ button in the toolbar) plays the whole reel in its own window, just as it will export, without rendering a file. It includes the cards, the order, trims, crops, crossfades, clip-name captions and sound. It's ready in a few seconds.
- The strip under the video shows every piece. Click or drag it to jump anywhere.
- **Space** plays and pauses. **⌘←** and **⌘→** go to the previous or next clip.
- The list on the right shows each card and clip. Click one to play from there.
- Right-click a clip in the Clips list › **Preview Reel from This Clip** to start there.
- Keep the preview open while you reorder, trim, or change settings. It notices the change and offers **Update Preview** (⌘R), then picks up where you were.

Previews play at 720p. The export uses the resolution and frame rate you pick.

## Export

The intro card has a thin progress bar along the bottom, in the theme's color, that fills while it's on screen, so viewers can tell the video is playing and not frozen. Turn it off under **Export › Progress bar on the intro card**.

The **Export** section (⌘E) shows the reel in order (intro card, included clips, end card) and its estimated length. You can choose:
- how long each card is shown
- cut or crossfade between clips
- whether to show clip names as captions
- whether to include sound
- 720p, 1080p, or 4K, at 30 or 60 fps

Click **Preview** to watch it first, or **Export Highlight Reel…** to save an MP4 (by default in `~/Movies/Cocut/Exports`). When it's done you can play it in place, share it, or show it in Finder.

### Upload to YouTube

When an export finishes, click **Upload to YouTube…**. Cocut writes a title and a description from the Player Card (position, class, height, club, school, stats, contact), each with a **Copy** button. **Open YouTube Upload** opens YouTube's upload page in your browser and shows the video in Finder: drag it in, paste the title and description, and choose **Unlisted** so coaches can watch with the link but it won't show up in search. No setup or sign-in to Cocut needed.

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

## iPhone and iPad

`CocutiOS` is the iPhone/iPad app (iOS/iPadOS 26+). It shares the engine in `Shared/` with the Mac app: clip library, projects, Player Card, Find Rallies, Preview and Export. Clips and matches come from Photos or the Files app; finished reels can be shared or saved to Photos. Everything lives in Cocut's folder in the Files app. There's no screen recording on iOS.

For now it's installed from Xcode with a free Apple ID (the install lasts 7 days; press ▶ again to renew):
1. `make ios`, then choose the **CocutiOS** scheme and your iPhone in Xcode's toolbar.
2. Under **Signing & Capabilities** for **CocutiOS**, set **Team** to your Personal Team.
3. On the iPhone, turn on **Settings › Privacy & Security › Developer Mode** (it appears after the phone is connected to Xcode).
4. Press ▶. The first time, trust yourself under **Settings › General › VPN & Device Management**.

CI compiles the iOS target on every push, unsigned.

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
├── Rallies/                  Find Rallies: ball + whistle detection, review window
├── Updates/                  GitHub Releases updater + sheet
└── Views/                    Main window, clip grid, preview
Shared/                       Used by both apps
├── App/                      Log, platform helpers (images, colors, paths, Trash)
├── Library/                  Clip model, JSON index, projects, thumbnails
├── Profile/                  Player profile and card designs
├── Export/                   Reel composer, exporter, preview
└── Rallies/                  Rally + jersey number detection, court area step
CocutiOS/                     iPhone/iPad screens: Clips, Find Rallies, Player Card, Export
```

## Roadmap

- A spotlight ring to point out the athlete at the start of a clip
- Background music under the reel
- Multiple players or reels
