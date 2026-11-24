# Notch

A Dynamic Island–style overlay for the MacBook notch. A borderless, click-through
`NSPanel` sits above the menu bar, and SwiftUI draws a black shape that grows out
of the physical notch.

## Install

```sh
brew install --cask devaduttmohan/tap/notch
```

Homebrew installs Notch.app and puts `notchctl` on your PATH (it lives inside the app). Or
download `Notch-x.y.z.zip` from the [releases](https://github.com/devaduttmohan/notch/releases),
unzip it into Applications and right-click › Open the first time (the app is signed locally,
not notarised). Apple silicon, macOS 14 or later.

## Updates

Customise › About shows whether Notch is up to date and, when a newer release is out, its
highlights, **What's new** and **Update**; the sidebar gets a dot, the menu bar menu an
"Update to Notch x.y.z…" item, and a banner says so once. Notch looks at GitHub's public
releases API about 20 s after starting, every 6 hours, when you open About, or on **Check
now** (no sign-in; an ETag makes an unchanged answer nearly free; nothing while you're away;
switch it off with **Check automatically**).

**Update** first makes sure Notch can write next to itself (and clears what an earlier update
left there), then downloads the zip (with progress), checks it against the SHA-256 GitHub
publishes for it, unzips it, and checks the app: its bundle ID, its version, a valid
signature, that it's signed as Notch, that it's built for this Mac's processor, and that this
macOS is new enough for it. Those catch a broken or wrong download; the trust itself comes
from GitHub (over HTTPS) and its checksum, since Notch is signed locally rather than with an
Apple Developer ID. Then Notch quits; a small helper copies the new app next to the old one,
swaps the two, starts it, and keeps the old one until the new one has been running for 3 s.
Anything wrong, nothing is replaced; if the new version doesn't start, the old one goes back.
A failure is reported after the restart (a banner and the About card); a success with
"Updated to Notch x.y.z" and what's new. Settings, Calendar access, the login item and the
Jenkins token all carry over. The Homebrew cask is `auto_updates true`, so Homebrew leaves
updating to Notch (`brew upgrade --greedy` still works).

Copies that don't update themselves, with the reason in About: a build from source
(`build/Notch.app` in a checkout, or `swift run`), a copy macOS runs from a temporary place
(App Translocation; move it with Finder), and a copy in Downloads, Desktop or Documents
(privacy-protected folders, where the helper may lose access once Notch has quit).

Known limits:
- The helper's "another copy is running" check only sees your own processes started by path;
  two people running the same `/Applications/Notch.app` at once can still get in each other's
  way.
- Removable, network and iCloud volumes aren't refused up front like Downloads; if the helper
  is refused there, the update fails safely (the old app stays and is restarted).
- A 0.7.2 copy in Downloads, Desktop or Documents can still be updated once (by 0.7.2's own
  helper); after that it says to move it to Applications, without an "Updated to" banner.
- A rare rollback fallback (`Notch.app.failed.<pid>`) isn't cleaned up automatically, and a
  dangling symlink named `Notch.app.incoming` is reported as "can't write here".

## Releasing

```sh
CO_AUTHOR="Name <email>" bin/release 0.7.3 [notes.md] [--no-install]   # notes default: build/release/notes-0.7.3.md
```

Checks first (clean main, notes there, no such tag or release here or on GitHub, gh answering),
then sets the version, builds and zips Notch.app and checks the zip (signature, signed as
Notch, version, Apple silicon, `notchctl` inside); anything wrong puts Info.plist back with
nothing committed. Then it commits and pushes the version, uploads the release as a draft,
waits for GitHub's checksum of the zip and checks it matches, publishes it (tagged on the
commit that was built), updates the Homebrew cask in the tap (`../homebrew-tap`, or `TAP_DIR`)
and pushes it, and reinstalls here unless `--no-install`. GitHub calls after the upload are
retried. If it stops after the push but before the upload, run it again: it carries on. The
cask's template is `packaging/homebrew/notch.rb`.

Known limits: a few failure messages after the upload can give imperfect advice (a draft that
never shows in GitHub's list reads as a network failure; if reading the checksum keeps failing
it suggests checking the draft and publishing, though the checksum wasn't compared; if
publishing went through but every reply was lost and the follow-up check fails too, it says to
delete a release that is already published). When in doubt, look at the release on GitHub
before acting on the message.

## Run

```sh
bin/notch
```

Builds Notch, (re)starts it and follows its log
(`~/Library/Logs/Notch.log`; Ctrl-C stops following, Notch keeps running). Notch is
installed in `/Applications/Notch.app` (`bin/notch --install` did it once); every
`bin/notch` replaces that copy and runs it, and the build copy in `build/` is removed, so
there's only one Notch. Without an installed copy it runs from `build/Notch.app`.
`bin/notch --quit` quits it, `--debug` makes a quicker-to-compile debug build,
`--build-only` just builds (in `build/`, leaving the installed copy alone). The app is an
optimised (release) build, signed locally with a fixed identity, so macOS remembers its
permissions (Calendar, Automation) across rebuilds and moves. "Open at login" follows the
app: when it starts from a new place it moves the login item there. Needs Swift 6 +
Command Line Tools; Xcode isn't required.

`swift run Notch` still works for quick experiments, but macOS only lets an app
read your calendar, so meetings need `bin/notch`.

There's no Dock icon. The menu bar icon is a tiny MacBook screen whose island mirrors the
real one (a small notch when idle, a pill when something's going on, a dot when something
needs you; it springs between them, and its tooltip says what). Click it for the menu,
including **Customise…** (⌘,).

### Development flags

```sh
bin/notch --demo timer                # also: music, claude, done, ended, charging, airpods, build, meeting
bin/notch --customise motion          # open the customiser on a pane
bin/notch --state expanded            # pin a state: idle | compact | expanded | banner
bin/notch --slow 5                    # every animation 5x slower, to inspect the motion
```

## Customiser

Menu bar capsule → **Customise…**, or **Customise** in the open island. A dark
window in the island's style, with a live preview island over a pretend desktop
(scenes: idle, music, player, meeting, join, banner, Claude, or a tour). Changes
apply instantly and save to `~/Library/Application Support/Notch/settings.json`.

- **Appearance:** background (Midnight, Graphite, Ambient: glows with the album
  art or activity colour, Aurora: drifting light), accent colour, shadow depth,
  coloured glow, edge highlight, size, corner roundness.
- **Motion:** personality (Snappy, Smooth, Bouncy, Gentle) bends every spring;
  speed 0.6–1.6×; content effect (blur, zoom, fade); Reduce Motion.
- **Behaviour:** open on hover, hover and hold (it swells first), or click;
  **Alerts**; haptics; sounds; which display; open at login.
- **Alerts:** for Claude Code, pull requests, Flock reviews, Jenkins builds and
  commands, each on its own: **Until seen** (on the notch until you've looked at it
  in the open island; a command's until you open the island after it showed) or
  **Hide after** 3 s to 2 min, or Auto (each alert's usual 4–7 s) for PRs, builds
  and commands. A Claude or Flock update counts its seconds only while it's the
  banner on the notch and you're there (not behind another banner or "Claude needs
  you", not while the island is open or the pointer rests on it, not while the
  screen is locked or asleep); then it, and any older news set to hide, waits unread
  in the open island. PR, build and command alerts set to hide pass like any banner.
  Defaults are as before: Claude and Flock stay; PRs, builds and commands Auto.
- **Modules:** switch Now Playing, Meetings, Claude Code, command alerts, timers,
  battery and headphones on or off.
- **Meetings:** calendar access, which calendars, when the pill appears, time left,
  chime, video calls only, and what's coming up.

## Several things at once

The pill shows the most important activity; the second splits off into a small **bubble**
beside it (a third and more show as "+1"). Order: Claude needs you, a meeting starting now,
a runaway process, music playing, a meeting soon, a timer, PR news, paused music. Hover
the pill to open its activity, or the bubble to open the bubble's. Open, the camera row
holds a **tab per activity** (page dots when there are many): click one, or two-finger
swipe across the island, and the page slides over while the island springs to its height.
The section you choose (a tab, a swipe, the bubble) is what the closed island shows
afterwards, the rest moving to the bubble; only "Claude needs you" and a meeting starting
now go ahead of it. Tabs keep their order while open.

## Pull requests

Through the GitHub CLI (`gh`, already signed in; Notch never sees the token), paused while
you're away: the Mac asleep, the screen locked, the displays asleep or another user switched
in. When you're back it catches up in one look, so nothing is missed (a quiet check every
minute ends a pause whose "back" notification never came). GitHub's GraphQL budget (5,000 points an hour) is shared with everything using
your gh login, so each look is a 1-point "pulse" (every PR's last update, latest commit,
merge state and check counts) and a PR is read in full (2 points; ~25 for the very first
load) only when something needs it: it's new, a push, a comment or review, a merge-state
or review-decision change, a check failing or being re-run, and the end of a run. A check
merely finishing doesn't: the pulse's counts drive the ring and "7/11". Every minute,
every 20 s while checks run (about 60 points an hour idle, ~180 while CI runs); every 5
minutes when under 15% is left, and a pause until the reset when it's nearly gone. Each
full read is logged with why and what it cost ("#5042 checks finished after 14 looks on
counts alone · 2 points"). The budget shows in Customise › Modules. Events are what's new
since the last look, not standing state (many PRs sit "failing" on purpose): checks
passed/failed on a push, approvals, changes requested, comments (bots in Customise ›
Modules are left out; Flock's reviews count), ready to merge, merged, review requested of
you. One banner per look (several fold into "Flock reviewed 3 PRs"). The PR page lists
what's new first, then running, then the rest, for PRs active in the last 7 days (older
ones summed up as "+6 older"). "Approved" means a person approved and every check, including
hatch/flock-review, passes (Flock's own approval doesn't count). Rows show open Flock
comment threads. The island grows or shrinks to fit the list. **Flock's news is sticky**,
like Claude's: it stays on the notch until you've looked at the PR page. A row opens
to show failed checks, the latest word, and **Open**, **Details** (the failed check's page,
or the PR's checks) and **Copy ▾**: the link, the title and link (rich text, so Slack, Jira,
Notion and Mail paste the title as a link; plain text elsewhere), the branch name, or
Markdown. A failed GitHub Actions run adds a re-run button. Right-click any row for the
same choices. Looking at the page for half a second marks things seen.

Customise › Modules › Pull requests shows the GitHub account gh is signed in as (picture,
name, @login). **Sign in with GitHub** runs gh's own browser sign-in: Notch shows the
one-time code, **Copy code & open GitHub** puts it on the clipboard and opens
github.com/login/device, and Notch carries on by itself once you approve (Cancel stops it;
the code expires after 15 minutes). **Switch account** picks another account gh holds, or
signs in to one more. Notch uses gh's active account, the same as your terminal, so a
switch changes it there too; Notch then starts the new account afresh rather than calling
its PRs "news". **Ignore comments from** is editable: × removes someone, **Add** takes a
login (or @login, or a profile link; bots end in [bot]), people and bots who've commented
on your PRs are offered underneath, and **Restore defaults** brings back the starting list.
Matching ignores case.

## Open in …

`notchctl claude` sends the processes above the hook, so Notch knows where each session
runs, and, for a session the Claude app started, the app's own ID for it
(`CLAUDE_CODE_HOST_SESSION_ID`, a `local_…` ID). **Open in …** on a Claude update or "needs
you": Claude opens that very session (its `claude://code/continue?session=…` link; a session
running from before learns its ID with its next event); Terminal and iTerm select the exact
tab; VS Code, Cursor and Antigravity focus the project's window; Warp comes to the front.

## Keep awake

While a Claude Code turn runs (from your prompt until Claude stops; not while it waits
on you), while a `notchctl run` command runs, or when you click ☕ in the open island
(also **Keep Mac Awake** in the menu bar), Notch holds a standard macOS "prevent idle
sleep" assertion; `pmset -g assertions` shows it as "Notch: Claude is working in …".
The display may still sleep. Each source can be switched off in Customise › Behaviour.

## System health

Every 5 s Notch reads your own processes' CPU time and memory (public libproc calls,
no permissions). A process above 150 % CPU for 2 minutes, or holding over 8 GB, gets a
banner and a pill: hover for its app or folder (which tells your dev servers apart),
a live CPU sparkline, and **Quit** (then **Force Quit**), **Not now** (30 min), or
**ignore** for good. Compilers and VMs are ignored by default. Also warns below 10 GB
and 5 GB of free disk, and when macOS starts throttling a hot Mac. Thresholds and the
ignore list are in Customise › Modules.

## CPU & memory

Off until you switch it on in Customise › Modules. The Mac's totals (Mach and sysctl calls,
no permissions) every 2 s, every second while its page is open, nothing while you're away.
The closed pill shows CPU on the left and memory used on the right (CPU only, or memory
only, if you prefer): **always**, only **when busy** (the default: CPU averaging 80 % or more
over 30 s, adjustable to 70 or 90, or memory pressure raised), or never (**island only**).
A busy reading turns orange, a critical one red. Busy CPU or critical memory takes the
pill from your music; memory pressure that's only elevated (a Mac that swaps all day) waits
behind it, in the bubble. The open island's page has CPU over the
last minute (user and system), memory split like Activity Monitor (app, wired, compressed,
free) with its pressure and swap, and your apps using the most, helpers summed into their
app and a dev server shown with its folder; click one to quit it.

## Jenkins builds

Builds you start in Jenkins, on any job: Notch asks Jenkins which builds are running
(`/computer/api/json`, one small request that covers every executor, pipelines included)
and which are queued, and keeps the ones started by you, or by a push of yours (your
GitHub login). The pill shows a blue hammer and a ring filling towards Jenkins' estimate
with the minutes left ("queued" while it waits for an executor; time so far on a first run,
which has no estimate). Open the island for the builds page: each build's current stage
and time ("Test · 3m 41s of ~5m"), a **stage bar** for pipelines (green done, blue running,
red failed; from the Stage View plugin's `wfapi`, or the newer Pipeline Graph View, whichever
the server has, found once per job), or for a job without stages (freestyle) a time bar
filling towards the estimate with "~12m left · done ~10:57" ("over by 3m" in orange when it
runs long), finished builds with how they
ended, and **Console**. When one ends, a banner: "Deploy-staging #482 passed · took 4m 10s",
or "failed · at Test · after 4m 10s". A failure keeps a red dot until you've seen the page.

Sign in from Customise › Modules › Jenkins builds: the server (filled in from your PR
checks' links), your Jenkins username, and an API token (**Make a token** opens Jenkins'
page for it). The token is checked with Jenkins, then stored in your login keychain through
macOS's `security` tool, the way gh keeps its token (never in the settings file): the entry
belongs to that tool rather than one build of Notch, so rebuilding never brings up a keychain
prompt, and it's read off the main thread. **Sign out** removes it. Notch only reads. Every 20 s while a build
of yours runs (executors, queue, stages: about 540 small requests an hour, only then).
Otherwise builds come in bursts: every minute for 10 minutes after anything of yours ran
(executors and queue), then every 2 minutes asking only the executors (about 30 small
requests an hour, ~20 KB each). Not less often: a build that starts and ends between two looks
is never seen running. A push to one of your PRs brings a look forward. The first time Notch
sees you build in a job, it reads that job's history at once, so an earlier build there that
slipped between looks still shows in your history.
Nothing while you're away; a job without the stage view is asked once and then left alone.

## Meetings

From the Calendar app's calendars (add Google or Exchange in Internet Accounts).
From 10 minutes before (adjustable), the pill shows the calendar's colour, a ring
and the minutes left; in the last two minutes and the first five of the meeting it
outranks music. Hover for the title, time and a green **Join** (Meet, Zoom, Teams,
Webex, Slack huddles, Chime, Whereby links are found in the invite). When it
starts: a banner and a chime; during it, the time left. All-day, cancelled and
declined events are skipped. Nothing leaves the Mac.

## The three states

| State | When | What it looks like |
|---|---|---|
| **idle** | nothing happening | exactly the physical notch, so it's invisible |
| **compact** | an activity is running | wider pill, one glyph each side of the camera (the middle stays empty) |
| **expanded** | mouse over it | drops into a panel with full controls; clickable |

`NotchModel.state` picks one: hover wins, then any activity, otherwise idle.
Each state's size and corner radii live in `NotchLayout.spec(for:)`. The
leading glyph (timer icon / artwork) is shared between compact and expanded via
`matchedGeometryEffect`, so it slides and grows instead of swapping.

## Spaces and full-screen apps

Notch keeps its panel in a Space of its own that sits above every other and never moves
(the way macOS keeps its volume and brightness pop-ups up), so the island stays on screen
through swipes between desktops and full-screen apps. That needs a private window-server
(SkyLight) call: each function is looked up at launch, and if a macOS update drops one,
Notch logs it and falls back to moving into each Space after the switch. Turn it off in
Customise › Behaviour › Display (**Stay put when switching Spaces**). Because a window up
there would sit over the lock screen too, Notch hides itself (and takes no clicks) while
the screen is locked or the screen saver runs.

## Motion

All timing lives in `Motion.swift`, tuned by eye to the Dynamic Island (Apple
doesn't publish its curves):

- **Each part has its own spring.** Opening widens first, then drops down a beat
  later with a little more bounce; closing pulls up first, then narrows.
- **Opening is springier than closing** (about 2.5% / 4.6% overshoot on width /
  height going out; almost none coming back).
- **Content is revealed, not resized.** Each state's content is laid out at its
  final size and the growing shape uncovers it. It blurs and scales in about
  100 ms after the shape starts, and blurs out at once on the way back.
- **Details:** countdown digits roll (`.numericText`), play/pause morphs
  (`.symbolEffect(.replace)`), track changes blur from old to new, the waveform
  morphs into a play icon when paused, buttons dip when pressed, and the open
  panel casts a soft shadow.
- **Seek slider:** the thumb glides on a spring (`Motion.seekGlide`) whenever it
  moves by anything other than plain playback (a tap on the bar, grabbing it away
  from the thumb, a seek, a correction from the browser), and the thumb and bar
  grow under the pointer (`Motion.grow`).
- **Nothing vanishes:** a paused player keeps the compact pill (play icon in place
  of the waveform); prev/next dim when the site doesn't offer them instead of
  disappearing.

Use `--slow 5` to watch it in slow motion while tuning.

Note: on the macOS 27 SDK, `@State` is a macro whose plugin ships only with
Xcode, so `NotchView` holds plain `State<T>` properties instead.

## Alerts: `notchctl`, Claude Code, your Mac

**`notchctl`** sends things to the notch from scripts and terminals. Use the stable
path `bin/notchctl` (it finds the built binary):

```sh
bin/notchctl say "Deploy finished" --title Staging --icon ok   # icon: ok | fail | info | any SF Symbol
bin/notchctl run -- swift build      # runs it; banner with ✓/✗ and how long it took; keeps the exit code
```

It talks to the app over a Unix socket in `~/Library/Application Support/Notch/`
(folder `0700`, socket `0600`, and each connection is checked to be your user), so
nothing on the network or another user can post to it. If Notch isn't running,
`say` exits 1 and `run` still runs the command.

**Claude Code** hooks in `~/.claude/settings.json` run `bin/notchctl claude` (async,
never blocks Claude, always exits 0) on Notification, Stop, UserPromptSubmit,
PostToolUse and SessionEnd:

- *Notification* (needs permission / waiting for input): an orange **Needs you** pill
  with a breathing dot. It beats everything else in the pill and stays until that
  session moves on (you reply, a tool runs, it ends) or you press **Dismiss**.
- *Stop*: **Claude finished · project** with the first line of Claude's last message
  (read from the session transcript). Turns under 15 s finish quietly.
- *SessionEnd*: **Session ended · project** with how long it ran. Sessions ending
  together (quitting the app) share one; `/clear` and resume stay quiet.
- *Background work* (commands, agents, watches Claude runs in the background): the
  pill shows a turning ring around Claude's mark, "+2" for the rest, and how long the
  oldest has run; the open island lists them under Claude's page ("3 running in the
  background"), each with its project, kind and time so far. A start comes from the
  tool call (PostToolUse); each turn's end (Stop's `background_tasks`) says what's
  still running, and one that's gone has finished. Claude Code reports no progress,
  estimate or exit code for them, so the ring only turns, and a finished one simply
  leaves. Needs `notchctl` from this version (it forwards those fields).
- Finished / ended updates **stay on the notch until you look**: hover it (it opens
  with the details) and move away, or press **Dismiss**. A brush past under half a
  second doesn't count. Several waiting show a count; a passing banner (charging, a
  build) shows over them and then they're back; "Needs you" takes priority.

**Your Mac** (public IOKit / CoreAudio APIs, no permissions): **Charging** with a
battery ring when you plug in, **Low Battery** at 20/10/5 %, and a banner when
AirPods or other headphones become the sound output. Their battery fills in as a
ring a moment later (each earbud and the case for AirPods/Beats), read from Apple's
`system_profiler`. Third-party headphones show it only if macOS knows it (if
System Information › Bluetooth lists a battery level for them).

Banners are a fourth island shape: a short drop-down that closes by itself after a
few seconds; several queue up with a beat between them. Hover opens the panel as
usual. Preview them from the menu-bar icon → Preview.

## Spotify and Apple Music (desktop apps)

Both apps announce every play/pause/track change with a system-wide notification
(`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`), so Notch
follows them with no permission. Controls (play/pause, skip, seek) use AppleScript:
the first time, macOS asks once per app (running from Terminal, the prompt names
your terminal app). Artwork and the exact playhead are read with AppleScript only
after that permission exists, so nothing ever prompts on its own.

When several players report at once (a browser tab, Spotify, Music), the notch
shows a playing one over a paused one, and otherwise whichever changed last.

## What's playing in Chrome

`ChromeExtension/` sends what's playing in Chrome (YouTube, YouTube Music,
Spotify web, SoundCloud, …) to the app, and the notch's play/pause/skip buttons
control that tab. It uses only supported APIs: the page's Media Session info
and handlers, read by the extension, sent over a local WebSocket.

**Install (once):**

1. Open `chrome://extensions` and turn on **Developer mode** (top right).
2. Click **Load unpacked** and choose the `ChromeExtension` folder.
3. Run the app (`swift run Notch`) and play something in Chrome. The terminal logs
   `Notch: browser: playing "…" on YouTube`.

After editing the extension, press the reload icon on its card in
`chrome://extensions`. It adds itself to tabs that are already open, so you don't
need to refresh them.

**Media that's already playing** is picked up:

- *Tabs open before the extension was (re)loaded:* the extension injects its
  scripts into them on install/reload and they report straight away. Title and
  play state show at once, the timeline as soon as the site next reports its
  position. The site's Media Session handlers were registered before the script
  arrived, so for next/previous (and play/pause) it presses the site's own player
  buttons, found by exact accessibility labels ("Next", "Previous (SHIFT+p)", …;
  never "Next page" or "Play all"). A tab refresh gives it the real handlers.
- *Notch started while something plays:* pages with media check in every ~4 s,
  which wakes the extension and reconnects to Notch within a few seconds.

**Video thumbnails:** the site's Media Session artwork; for a video without one,
its poster, or the page's share image (`og:image` / `twitter:image`), https only.
A video (a `<video>` with a picture, not sound only) shows its still wide in the
pill and the open island, with the still blurred behind the open island; with no
picture, a film icon. Square art stays square. Some sites (JioHotstar, for one)
give none of these, and protected video can't be captured, so they get the icon.

**Seek slider:** when the site reports a duration (Media Session
`setPositionState`, or the `<audio>/<video>` element), the open panel grows a
little and shows elapsed / remaining time and a bar you can drag. The playhead
moves on its own between updates. Live streams have no slider.

**How it fits together:**

| Piece | Runs in | Job |
|---|---|---|
| `page.js` | the page's own JS world | reads `navigator.mediaSession` + `<video>/<audio>` (even ones never added to the page), remembers the site's play/pause/next/seek handlers and position, keepalive every ~4 s |
| `content.js` | extension's isolated world | relays between `page.js` and the background worker |
| `background.js` | extension service worker | picks the tab to show (playing beats paused, newest wins), talks to the app, injects into already-open tabs on install/reload |
| `BrowserBridge.swift` | the app | WebSocket server on `127.0.0.1:47821` |

If the port is busy (for example a second copy of Notch is running), the app
logs it once and keeps retrying with backoff, so whichever copy is left takes
over. The port number lives in `BrowserBridge.port` and `ENDPOINT` in
`background.js`; change both together.

**Safety:** the app listens on 127.0.0.1 only (not reachable from the network)
and refuses WebSocket handshakes unless the Origin is a `chrome-extension://`
URL, so web pages can't connect. Artwork is only loaded over https. The
extension's install prompt says it can "read and change all your data on all
websites" because the content scripts run on every page; they only read media
info and only send it to this app.

**Limits:** Chrome-family browsers only (Chrome, Arc, Brave, Edge). Media in
iframes (embedded players) isn't picked up yet. Spotify/Apple Music desktop apps
need their own route (not built yet).

## Code map

| File | What |
|---|---|
| `NotchGeometry.swift` | notch size from the hardware; per-state sizes (`NotchLayout`) |
| `NotchModel.swift` | state rules, timer, now playing, media actions |
| `NotchShape.swift` | the shape: rounded bottom, concave top flares, animatable radii |
| `Motion.swift` | every spring, delay and transition (see Motion) |
| `NotchView.swift` | SwiftUI content for each state and activity |
| `NotchPanel.swift` | overlay panel, hover detection, click-through switching, screen changes |
| `PinnedSpace.swift` | the panel's own Space above all others (private SkyLight calls, looked up at launch) |
| `AppDelegate.swift` | menu bar item, launch flags, wires up the browser bridge |
| `BrowserBridge.swift` | local WebSocket server the Chrome extension talks to |
| `AlertServer.swift` | private Unix socket for `notchctl`; `say` / `run` banners |
| `ClaudeCode.swift` | Claude Code hook events → Needs-you pill and Finished banner |
| `SystemEvents.swift` | charging, low battery, headphones |
| `DesktopMusic.swift` | Spotify / Apple Music: broadcasts in, AppleScript controls out |
| `Settings.swift` | everything the customiser changes (`NotchSettings`, saved as JSON) |
| `Appearance.swift` | background styles, edge highlight, album-art colour |
| `Meetings.swift` + `MeetingViews.swift` | calendar (EventKit), join links, the meeting pill and panel |
| `CustomiserWindow.swift`, `CustomiserView.swift`, `CustomiserControls.swift` | the customiser window, its panes, preview and controls |
| `Resources/Info.plist` + `bin/notch` | the app bundle: build, sign, launch |
| `SystemMonitor.swift` + `ProcessViews.swift` | runaway processes, low disk, heat; their pill and panel |
| `LoadMonitor.swift` + `LoadViews.swift` | CPU & memory, live: the sampler with busy/calm, its pill and page |
| `PRCopy.swift` | what Copy puts on the clipboard for a PR (link, rich title and link, branch, Markdown) |
| `Updater.swift` | new releases from GitHub: check, download, verify, swap in, restart (Customise › About) |
| `KeepAwake.swift` | the idle-sleep assertion and its reasons |
| `GitHub.swift` + `PRViews.swift` | PR watcher (gh GraphQL), change detection, banners; pill, bubble, tabs, PR page |
| `GitHubAccount.swift` | the gh account: who's signed in, browser sign-in, switching |
| `Jenkins.swift` + `BuildViews.swift` | your Jenkins builds: watcher, history, keychain token; pill, stage bar, builds page |
| `Symbols.swift` + `StatusIcon.swift` | Notch's own drawn icons (PR, meetings); the menu bar icon |
| `SessionJump.swift` | where a Claude session runs, and bringing it forward |
| `Sources/notchctl/` + `bin/notchctl` | the command-line companion |
| `ChromeExtension/` | the Chrome extension (see above) |

On a display without a notch it falls back to a 190-pt fake notch.

## Next steps

1. A drag-and-drop file shelf in the open island.
2. Hover details for finished builds' stages (running builds have them).
3. Signing with a Developer ID, so the app runs on other Macs without the Gatekeeper
   warning (today it's signed locally, ad hoc).

Reference: [boring.notch](https://github.com/TheBoredTeam/boring.notch)
(reported GPL-3.0: read for patterns, don't paste code).
