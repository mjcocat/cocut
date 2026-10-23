# What's new in Cocut

Each version's changes, newest first. The update window shows the entries for every version newer
than the one you have. Keep each line short and about what you'll notice.

## 0.50.0
- **Spotlight ring styles**: **No Ring** (just the lit area around the athlete), **Thin**, **Standard**, **Thick**, or **Painted**, a hand-drawn brush stroke that paints itself on around the athlete. Choose it next to the shape and color in the spotlight editor or Export; the editor shows it as the reel will.

## 0.49.1
- Phone Frame › Custom: steering while the clip plays works like holding the camera. The frame stays exactly where you hold it (even when the mouse is still), replaces the old path there, and when you let go it stays put for a second before gliding on, instead of snapping back to the path that was there. Steered moves are smoothed so hand wobble doesn't show.

## 0.49.0
- **Position the headshot**: Player Card › **Position…** next to Choose Photo. Drag the photo to choose what's in the middle and zoom in with the slider; the card preview updates as you go. Every card layout (round and square photos, widescreen and phone) uses it. A new photo starts centered.

## 0.48.6
- Phone reels follow players who are small in the picture better (wide shots, 720p Hudl highlights). When Cocut finds only a few people in a frame, it looks again at each half of the picture, where players are nearly twice the size to it. On a Hudl highlight it was finding about 2 of the 10 players a frame and lost the athlete after 3 seconds. Clips are followed again the next time you export.

## 0.48.5
- Fixed: phone exports came out completely white (and widescreen ones white during the cards) whenever the Cocut logo or clip names were on. Cocut now draws every frame of the reel itself, logo and captions included, instead of using macOS's overlay tool, which was blanking the picture.

## 0.48.4
- The mark over the clips is the full Cocut logo (layers and the CoCut wordmark) on a clear background, instead of the app icon's dark square. The end card's "Made with Cocut" line uses the clear layers icon too.

## 0.48.3
- The Cocut icon over the clips and the "Made with Cocut" line on the end card are twice the size.

## 0.48.2
- A quieter "Made with Cocut": over the clips it's just Cocut's icon, small and faint, in the corner. The words are now a small line at the bottom of the end card (with the icon). The same switch in Export turns off both.

## 0.48.1
- The "Made with Cocut" mark shows its words again (only the little icon came through), and clip-name captions show their text: both are now drawn as pictures, which exports render reliably.

## 0.48.0
- **Spotlight any moment in the clip**, not just the first frame. If your athlete is hidden behind someone at the start, slide **Moment** in the spotlight editor (or use ← →) to where you can see them and click them there. The reel plays up to that moment, holds it with the ring, then carries on. Phone reels follow the player from that moment too, backwards to the start as well as forwards.
- Fixed: since 0.47.0, exports showed white instead of the intro and end cards (they only flashed during the crossfade), and white where a spotlight holds its frame.
- The "Made with Cocut" mark is twice the size, and a little less faint.

## 0.47.3
- Add Videos says up front what you're adding: **Full Match** (from your Mac, from YouTube or Hudl, or a match you've analyzed) goes to Find Rallies, and **Clips Only** (from your Mac, or from YouTube or Hudl) goes straight into Clips. The YouTube or Hudl window then doesn't ask "full match or clip?" again.

## 0.47.2
- Find Rallies no longer gets stuck at 98–99%. If one rally stops responding while its jersey numbers are read (it waits on macOS's video or text reading), Cocut leaves that rally's numbers out after 90 seconds and finishes; the log says which rally. The number reader also starts up once before the work begins, instead of four times at once, which is when it got stuck.

## 0.47.1
- Hudl: public highlight links (www.hudl.com/video/…) download right away, with the highlight's name, and no sign-in. Before, the Hudl window opened and played the video but Download never lit up. Highlights come at Hudl's best quality for them (720p) and don't need ffmpeg.

## 0.47.0
- Exports carry a small, faint **Made with Cocut** mark (the Cocut icon and the words) in the corner of the clips: bottom right in widescreen, bottom center in phone shapes. It isn't on the intro or end cards. On by default; turn it off in Export › Clips › “Made with Cocut” mark. (Preview doesn't show it.)

## 0.46.0
- **Free Up Space** (File › Free Up Space…, or in Find Rallies): lists the big files Cocut made with their sizes: full matches downloaded from YouTube and Hudl, exported reels, and temporary files left by stopped downloads or exports. Each download says which match uses it and whether its rallies are already in Clips; those are ticked for you. Move to Trash puts them in the Trash (you can still put them back). Your clips and projects are never touched.

## 0.45.1
- Hudl: public broadcasts from newer Hudl streams (like school livestream archives) download now. Before, Hudl refused them ("HTTP Error 403: Forbidden"); Cocut now asks Hudl's player where the video is, the same way the Hudl website does.

## 0.45.0
- **Import from Hudl**, next to YouTube (Add Videos › Full Match › From YouTube or Hudl…, or ⇧⌘I). Paste a Hudl link: a public broadcast downloads right away; for your team's film, a Hudl window opens where you sign in once (Cocut remembers it) and open the video, and Cocut downloads it in full quality. Hudl needs ffmpeg (brew install ffmpeg).

## 0.44.4
- Phone reels follow your player better: tuned on 16 clips from three matches, they keep the player in frame more often and switch to a teammate standing next to them less. Clips are followed again the next time you export.

## 0.44.3
- Phone Frame editor: while Cocut follows the player for the first time it shows how far along it is ("Following the player… 40%"); the frame starts moving when it's done. Before, it looked like it wasn't trying.
- Click Head is gone: the spotlight alone is enough now. (Head clicks from before can be cleared with Clear Head Clicks.)
- A tip when the Player Card has no jersey number: the number helps tell your player from teammates.

## 0.44.2
- Cocut Lab's splash stays up for a moment (at least a second and a half) and fades out, like Cocut's.

## 0.44.1
- Cocut Lab opens with its logo and a progress bar (what it's loading, and how far along) instead of looking frozen. Once open it stays quick: the score under the clip list is worked out in the background instead of every time the window redraws.

## 0.44.0
- Cocut Lab: **Check Rallies** scores how well Find Rallies finds rallies, against the rallies you settled on in your matches (the ones where you added, removed, unticked or retimed a rally). It reports how many real rallies it found, how many it found that weren't real, short rallies, and how far off the start and end times are, per match. Also `cocut-lab rallies`.

## 0.43.2
- The toolbar button says **Add Videos**, and its menu is grouped: **Full Match** (from your Mac, from YouTube, or a match you've analyzed), **Clips on Your Mac**, **Record Your Screen** (a region, full screen, or the same region again), and **From Other Projects**.

## 0.43.1
- A quieter toolbar: just **Add**. Find Rallies is "A full match video…" (or "Matches You've Analyzed…" to go back to one) in that menu, recording is in the menu bar, and Preview is in Export. The keyboard shortcuts still work (⇧⌘M, ⇧⌘R, ⌘Y).

## 0.43.0
- One **Add** button in the toolbar for every way to bring film in, the same as Get Started: a full match, a YouTube video, clips on your Mac, recording your screen (full screen or the same region again), and clips from other projects. It replaces Import and the arrow next to Record.

## 0.42.1
- Cocut Lab, for Claude Code doing the marking: pictures come as contact sheets (four moments each), and runs of right guesses are accepted with one command (`cocut-lab accept`). About a quarter of the pictures, so it's faster and uses much less of your Claude plan.

## 0.42.0
- Who's This? learns from your answers: when you untick most of a group, Cocut takes it that players who look that alike can be different people and keeps them apart. Fewer mixed groups, and fewer questions that look like repeats. The "more worth answering" estimate no longer climbs as you answer.
- Cocut Lab: finds the people in clips by itself as soon as they're added (and when it opens), so the yellow guess is there right away.
- Cocut Lab: press **Space** to play through a clip, accepting the yellow guess at each moment. Press Space again when it's wrong (it takes back the one it just accepted), click your player's head, and carry on.

## 0.41.2
- Cocut Lab: select several clips (⌘-click, Shift-click, ⌘A) and remove them at once with Delete, the trash button, or right-click. It asks first only when clips have marks.
- Cocut Lab has its own icon.

## 0.41.1
- Import from YouTube works with videos macOS can't open as YouTube sends them: with ffmpeg installed (in Terminal: brew install ffmpeg), the downloader puts the video and sound together itself. Without it, Cocut says so instead of a vague error.

## 0.41.0
- New: **Cocut Lab**, a separate app for tuning how phone reels follow your player on your own clips. Mark where your player is (mostly by pressing Return), and it searches for the settings that keep them in the frame, checked on matches it didn't tune on. It also runs from Terminal and Claude Code. Setup: docs/cocut-lab.md in the Cocut repository.
- Import from YouTube: when putting the video and sound together fails, Cocut now tries again another way (and as a last resort keeps the video as downloaded) instead of stopping, and the log says exactly what went wrong.

## 0.40.4
- Phone reels: better when your player starts a rally standing right behind a teammate (lined up before the serve). Cocut used to stay on the teammate; now it picks your player up as soon as they step apart. Tuned on four rallies.

## 0.40.3
- Phone reels: when your player is completely hidden behind a teammate (Cocut can't see him at all), the frame stays where he was instead of jumping to someone else across the court. Fixes the drift at the end of a clip.
- Following a clip is quicker.

## 0.40.2
- Phone reels follow your player much better, tuned on the clips you sent. With the detections from your Mac, the player is now in the phone frame at 25 of 29 checkpoints in one rally (was 7) and 13 of 14 in another (was 10). A rally that 0.40.1 lost almost at once is now followed most of the way.
- Still weak: a moment where your player stands right behind a teammate and Cocut sees them as one person. Click Head fixes those.

## 0.40.1
- Phone reels: the Player Card's number now always decides who your player is. 0.40.0 could take a teammate's number read on the spotlighted box (when two players stand together) and follow the wrong player for a whole clip.
- Following a clip now saves what Cocut saw (in the Following folder next to the log: Help › Show Log), so a clip that's followed badly can be sent in to improve it.

## 0.40.0
- Phone reels follow your player far better. Cocut now looks through the **whole clip** before deciding who your player is, instead of guessing frame by frame. Moments where it's clear who's who are joined up, and teammates are ruled out by the numbers on their backs. A teammate crossing in front, or your player hidden for a moment, no longer pulls the frame away. In tests on real match clips, the player stayed in the phone frame far more often.
- One spotlight per clip is all it needs. Click Head is still there for a clip it gets wrong.
- Fill in the jersey number on the Player Card: it's how Cocut tells your player from teammates in the same uniform.
- The first phone export after updating looks through each clip again, and takes a little longer.

## 0.39.0
- New in the **Phone Frame** editor: **Click Head**. Turn it on and click your player's head. Following starts over on them from that moment. Click at the start of a clip, and wherever the frame wanders off them; each click shows as a yellow ring on the timeline. Works on clips without a spotlight too.
- Phone reels hold on to your player much better. 0.38.1 lost track of them after about a second in most clips. Now Cocut finds players the way Find Rallies does (which tells apart players standing together at the net), follows their head (which stays in view when someone stands in front), and bridges short gaps.
- It no longer mistakes a teammate's number for your player's.

## 0.38.1
- Phone reels stay on your player. The frame used to slide onto a teammate who walked between the camera and your player (they look much bigger up close). Now Cocut follows by size, direction and the **number on their back** (from the Player Card), and if it ever catches itself on the wrong number it goes back and finds your player again.
- Clips are followed again the first time you export after updating, so it takes a little longer once.

## 0.38.0
- New: **Phone Frame** editor (the button next to Spotlight on any clip). See the whole picture with the phone frame on it and the phone-shaped result beside it, live. Drag the frame, or click where it should look, to set a key; the export glides from key to key. Drag while the clip plays to steer it like a camera.
- Starting from Follow Player keeps what tracking found, so you only fix the moments it got wrong. Switch between 9:16 and 4:5 to check both.
- Title cards have **tall layouts** for phone reels: intro, section and end cards fill a 9:16 or 4:5 screen instead of sitting small on a blurred background, and keep clear of the app buttons at the top and bottom. Preview them in Player Card with the new Widescreen / Phone / Feed switch.

## 0.37.0
- New: **export for phones**. In Export, choose **Phone 9:16** (Reels, TikTok, Shorts, Stories) or **Feed 4:5** (Instagram and Facebook feeds).
- The frame **follows your spotlighted player** through each clip, moving smoothly like a camera operator. Spotlight a clip and Cocut does the rest.
- Clips without a spotlight are centered, or shown whole on a blurred background, your choice. Change any clip with ··· › Phone Framing, or right-click several.
- Cards are shown whole on a blurred background, and Preview shows the phone shape before you export.

## 0.36.1
- The menu bar icon is now Cocut's logo (its stacked layers and play button) instead of scissors.

## 0.36.0
- New: **Add from Other Projects**. Making a season reel? Pull the best plays from each tournament's project. Filter by rating (starts at ★★★★ and up), player or tag, pick the clips, and they're copied in with their trim, rating, tags, players and spotlight. Each project can get its own section.
- Find it on Get Started, in the + menu under the clip list, and in the File menu. Clips already added are marked, so nothing comes in twice.

## 0.35.3
- You can delete your last project. Cocut starts over with an empty one, on the Get Started screen.

## 0.35.2
- A new Get Started screen: four big tiles to pick from (a full match, a video on YouTube, clips on your Mac, or recording your screen). Click anywhere on a tile.

## 0.35.1
- Import from YouTube checks what it got: if a video offered in 1080p comes through at less, it tells you and offers to try again instead of quietly using a lower quality.

## 0.35.0
- New: **Import from YouTube** (File menu, ⇧⌘I). Paste a link and Cocut downloads the whole video in its original quality, up to 1080p, which is cleaner than recording the screen. Say whether it's a full match (opens Find Rallies) or a clip (goes into Clips).
- The first import fetches a small download tool (yt-dlp) from its official release and checks it. It stays up to date by itself.
- Only for film you have the right to use, like your own uploads or your team's.

## 0.34.5
- The floating recording control is easy to read over any video, and the dashed recording outline no longer runs through it.
- Start and Done keep their color while you record, instead of looking grayed out.

## 0.34.4
- While recording, the red light on the floating control pulses, so you can tell at a glance it's recording. The discard button sits apart from Done.

## 0.34.3
- Check Accuracy: the "is in it" and "Not in it" buttons are bigger and colored, and the rally list shows just two things to scan, Listed and your mark, with a warning where Cocut is wrong.
- Setup Guide: finished steps fold down to one line.

## 0.34.2
- Find Rallies: Team Roster, Identify Players and Open Match show their names in the toolbar. The rally list no longer picks up color from what's behind the window.
- Who's This?: number buttons line up evenly, and Other #, Not Our Team and Skip sit on one row.
- Reel Preview: the video sits at the top with its controls right under it, and the list no longer picks up color from behind.

## 0.34.1
- Clips: the selected clip sits at the top with its details right under it, instead of floating in the middle.
- Export: the spotlight shape and color controls are labeled.
- Player Card: the caption sits right under the card preview.

## 0.34.0
- A cleaner look throughout: one consistent style for panels, banners and labels, in Light and Dark Mode.
- Record is a red button in the toolbar again, with Full Screen and Same Region in the menu next to it. Import and Find Rallies are in the toolbar too. Undo and Redo are in the Edit menu (⌘Z, ⇧⌘Z).
- The sidebar shows your reel at a glance, with Preview and Export.
- Clip details: name and an In Reel switch on top, then Trim, Spotlight and stars. Move to Trash is in the ··· menu.
- The selected clip plays in a framed picture instead of a big black area.
- Export and section settings are tidy grouped forms.
- Find Rallies: Team Roster and Identify Players are in the toolbar; the bottom bar is just what you're keeping and Add to Clips (⌘Return).

## 0.33.0
- In Who's This?, a number you type under Other # joins your Team Roster, so it's a button for the next questions.
- Click anywhere on a close-up in Who's This? to tick or untick it.

## 0.32.0
- Find Rallies is faster when you mark your court: it reads jersey numbers while it's still looking for the ball, instead of after.
- When a match is analyzed again, your Who's This? answers stay with the right players. Before, they could end up on someone else.

## 0.31.0
- New option when you mark your court: **Quick number reading**. Find Rallies stops reading a player's number up close once it's clearly read in the rally, which makes it faster. It's off by default; turn it on, then compare in Check Accuracy.
- Turning it on or off analyzes a match again the next time you open it. Your answers and edits are kept.

## 0.30.0
- Find Rallies reads jersey numbers and follows players faster: it looks at several frames at once and no longer jumps around the video for each one.
- The log shows how long each part of Find Rallies took, to help make it faster still.

## 0.29.0
- Mark your libero in the Team Roster. After you identify her once in Who's This?, Find Rallies finds her by her different-coloured jersey, so she stops coming up again and again.
- Nothing has to be analyzed again: your answers and what Cocut has learned are kept.

## 0.28.0
- Who's This? progress is steadier: the bar climbs from 0% with each answer, and "about N more" counts down to 0 instead of going up.
- The bar reaches 100% only when most players are sorted out, so it no longer jumps there all at once.

## 0.27.0
- Identify Players and Check Accuracy open in their own windows on the Mac, so you can move them anywhere and size them freely.
- The Who's This? progress bar starts at 0% on each match and counts up as you answer. The first answers, about the players seen most, move it the most.
- The update window shows what's new in each version since yours.

## 0.26.0
- Who's This? is a fixed page: the picture and close-ups resize with the window, and the number buttons are always in view.
- Every stretch of a person gets a close-up you can untick, clearest first.
- When most players are sorted out, Who's This? offers to stop.
- After Find Rallies, a slim bar suggests the next step: roster, warm-up, identify players, then use the rallies. Hide it with ×.

## 0.25.0
- With a Team Roster, a rally lists at most six of your players: the six seen most in it.
- Who's This? asks only about people seen during rallies and seen clearly, most useful first, and says about how many more are worth answering.
- Right-click a rally › Leave Out Earlier Rallies, for the warm-up and lineup.

## 0.24.0
- Timeouts are left out of the rallies.
- A number read only a few times no longer labels a whole group of look-alikes.
- Rally player lists fill in short gaps and drop strays using the rallies around them.

## 0.23.0
- Point at a close-up in Who's This? to see it big, or magnify the frame. Pinch on iPhone and iPad.
- Check Accuracy has a bigger video, Magnify (Z) and Play/Pause (Space).

## 0.22.0
- Players are grouped more carefully, so teammates in the same uniform are mixed up less often.
- Who's This? shows a close-up from each time a player was followed: untick any that aren't them.
- New Check Accuracy: mark which rallies a player is really in, and see how well Cocut lists them.
