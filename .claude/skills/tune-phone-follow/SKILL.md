---
name: tune-phone-follow
description: Tune how Cocut's phone reels (9:16 and 4:5) follow the spotlighted player, using Cocut Lab on real clips on this Mac. Use when asked to tune, test or improve phone framing / player following, to add clips to the lab, or to mark where the player is in clips.
---

# Tuning the phone follow with Cocut Lab

Cocut's phone export finds everyone in each frame with Apple's Vision (slow, done once per clip)
and then `PlayerChain` (Shared/Export/PlayerChain.swift) works out which of them is the player,
using the numbers in `PlayerChain.Settings`. Cocut Lab saves what Vision found, lets people mark
where the player really is every half second, and searches for settings that keep the player in
the phone frame more often, checking them on clips the search didn't see.

Everything goes through the `cocut-lab` command (Cocut Lab's command line). If it's missing, run
`scripts/install-lab.sh` from this repo. `cocut-lab help` lists the commands. The lab folder is
`~/Documents/Cocut Lab`.

## The loop

1. **Look**: `cocut-lab status`. It lists each clip, whether its people have been found, how many
   checkpoints are marked, and how often the player is in the phone frame now.

2. **Add clips** when asked (or when the lab has fewer than ~10 clips, suggest it):
   - `cocut-lab projects` lists Cocut's projects.
   - `cocut-lab import-project "<name>"` adds that project's clips with a spotlight, with the
     Player Card's jersey number. Prefer clips from several matches: the check on held-out clips
     works by match (project), and settings that only suit one match aren't worth adopting.
   - Then `cocut-lab detect` (finds people in new clips; a few seconds per clip).

3. **Marks** are the ground truth. The person may mark clips in the Cocut Lab window. If they ask
   you to mark clips:
   - `cocut-lab frames <clip>` writes one picture per checkpoint into the lab's `frames/` folder.
     Everyone Vision found is boxed and numbered; the current guess is yellow; existing marks are
     green.
   - Look at each picture (Read the PNG). Find the player: their jersey number (the lab's number,
     see status) and where they were at the previous checkpoint. Then:
     `cocut-lab mark <clip> <time> box <n>` when they're in box n,
     `cocut-lab mark <clip> <time> head <x> <y>` when they have no box (x, y: 0...1 across and up
     from the bottom-left of the picture),
     `cocut-lab mark <clip> <time> hidden` when they can't be seen,
     `cocut-lab mark <clip> <time> unsure` when you can't tell who it is.
   - Be strict: a wrong mark teaches the tuning the wrong thing. Use `unsure` whenever the number
     isn't visible and you can't follow them from neighboring checkpoints. Never change marks the
     person made unless they ask.
   - Pictures cost usage. Mark a few clips at a time and say how many checkpoints you marked.

4. **Tune**: `cocut-lab tune` (add `--tries 1200` for a longer search). It prints and saves a
   report in the lab's `reports/` folder: the score now and tuned, per clip, and **held out**:
   tuned without each match, then scored on that match.

5. **Decide.** Adopt the tuned settings only when all of these hold:
   - the report says **Recommended** (better on held-out clips, no held-out match more than 5
     points worse);
   - there are clips from at least 2 matches, and at least ~8 marked clips in all;
   - the gain isn't from one clip alone (look at the per-clip table).
   Otherwise, report what you found and what more clips would help (another match, another
   camera position, the situations that fail).

6. **Adopt** (only after the person agrees):
   - Paste the report's settings into the defaults of `PlayerChain.Settings` in
     `Shared/Export/PlayerChain.swift`.
   - Bump `TrackedPlayer.version` in `Shared/Export/PhoneExport.swift` (with a one-line comment),
     so Cocut follows clips again instead of reusing old results.
   - Run `scripts/test-player-chain.sh` (synthetic checks must still pass) and
     `cocut-lab score --settings ~/Documents/"Cocut Lab"/reports/latest-settings.json`.
   - This repo releases from `main`: bump `MARKETING_VERSION` in `project.yml` (patch version),
     add a short entry at the top of `CHANGELOG.md` (what the person will notice, e.g. "Phone
     reels follow your player better, tuned on N clips from M matches"), commit, and push to
     `main`. GitHub Actions builds and publishes the release; Cocut updates itself, and
     `scripts/install-lab.sh` updates Cocut Lab.

## Notes

- `cocut-lab score` scores the settings built into the installed Cocut Lab. After adopting new
  settings, the Lab's built-in settings change only when Lab is updated; until then pass
  `--settings <file>`.
- The score counts a mark as "in the phone frame" when the player's head is inside the 9:16
  window the camera would show. "Right/wrong player" says whether the followed box was them.
- Clips without a Cocut spotlight are pointed out by their first head mark.
