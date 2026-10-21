# Cocut Lab: tuning the phone follow on your Mac

Cocut Lab is a separate app for one job: making Cocut's phone reels (9:16 and 4:5) keep your
player in the frame. You mark where your player really is in real clips, and the Lab searches
for the settings that follow them best. It checks those settings on matches it didn't tune on,
so they work for clips in general, not just the ones you marked.

It has a window (for marking) and a command line (for Claude Code to run the tuning).

## One-time setup

Open **Terminal** (Applications › Utilities) and run these one at a time.

1. **Install Cocut Lab**

   ```
   curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install-lab.sh | bash
   ```

   This puts **Cocut Lab** in Applications and adds the `cocut-lab` command. Check it with
   `cocut-lab status` (open a new Terminal window first if it says "command not found").

2. **Install Homebrew** (skip if `brew --version` works)

   ```
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   Follow what it prints at the end (it asks you to run two lines that add `brew` to your PATH).

3. **Get the Cocut code**, so Claude Code can change the settings and publish an update

   ```
   brew install gh
   gh auth login
   gh repo clone mjcocat/cocut ~/Developer/cocut
   ```

   For `gh auth login`, choose GitHub.com, HTTPS, and log in with a web browser.

4. **Install Claude Code**

   ```
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Then start it in the Cocut folder and log in when it asks:

   ```
   cd ~/Developer/cocut
   claude
   ```

   If anything here has changed, the current instructions are at https://code.claude.com/docs.

## Marking clips (you, in the Cocut Lab window)

1. Open **Cocut Lab**. Click **Add Clips** › your project › **Clips with a Spotlight**. Cocut Lab
   then finds the people in each clip by itself (a few seconds per clip; the toolbar shows it).
2. Pick a clip. You see one moment every half second, with everyone Cocut found outlined and its
   current guess in **yellow**.
3. Press **Space** to play: it steps through the moments, accepting the yellow guess at each. When
   the yellow box is on the wrong player, press **Space** (it takes back the one it just accepted)
   and click your player's head. Press **Space** again to carry on.
   Or one moment at a time:
   - Yellow box is your player: press **Return**.
   - It isn't: **click your player's head**.
   - Can't see them (hidden, or out of the picture): press **H**.
   - Not sure who it is: press **U**.
   - **←** and **→** move back and forward; **Delete** clears a mark.
4. Set **Following #** at the bottom of the clip list to your player's number, if it's not filled in.

A 15-second clip is about 30 moments; with Space it plays through in about 20 seconds. Clips
from **different matches** are worth the most: the Lab checks its tuning on each match in turn.

## Tuning (Claude Code)

In Terminal, in the Cocut folder, start `claude` and ask, for example:

> Tune the phone follow with Cocut Lab. Import the clips from my "Future" and "Spring Classic"
> projects, find people, and tell me what the tuning finds.

Claude Code follows the instructions in `.claude/skills/tune-phone-follow/SKILL.md`. It shows
you the report and adopts new settings only if they do better on matches they weren't tuned on.
When you agree, it updates the code and publishes a new version of Cocut the usual way.

You can also ask it to do the marking from pictures ("mark the clips in the lab you can"). That
uses more of your Claude plan, and it marks "not sure" when it can't tell.

## From Terminal yourself

```
cocut-lab status            what's in the lab, and the score now
cocut-lab projects          your Cocut projects
cocut-lab import-project "Future"
cocut-lab detect            find people in new clips
cocut-lab tune              search for better settings (report in ~/Documents/Cocut Lab/reports)
cocut-lab rallies           how well Find Rallies finds rallies, scored against your corrections
cocut-lab help              everything else
```
