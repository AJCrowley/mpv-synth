# mpv-synth
### An mpv-based media player for Windows built for the way people actually watch things

Official website: https://mpvsynth.app

**Tired of broken mpv setups, outdated players, and endless config tweaking?**

mpv-synth gives you a fully working, self-updating mpv-based media player with modern features — out of the box.

No setup headaches. No maintenance. Just press play.

![mpv-synth](screenshot.png)

---

## The problem with Windows media players

Windows has never had a truly great built-in media player, and the third-party ecosystem hasn't kept pace with how people actually consume media in 2026. The most popular options are functional but feel like they were designed a decade ago — and in most cases, they were. Clunky interfaces assembled from stock Windows form components. Windows that linger on your desktop doing nothing after playback ends. No memory of where you were in a file. No awareness that you might want to move on to the next episode without hunting through a file browser. No consideration of the display you're watching on, the colour space of the content, or whether the motion might benefit from interpolation.

Contrast that with how media playback works on your phone. You open a file — it plays. When it's done, it's done. It remembers your position. It just gets out of the way. There's no application to wrangle. It feels like a feature of the operating system rather than a third-party tool bolted on top of it.

That's the experience mpv-synth is built to deliver on Windows.

---

## What mpv-synth is

**mpv-synth turns video playback into a native OS-level experience.**

Open a file → it plays → it closes when done.

No UI clutter. No library management. No friction.

---

## What you get

- Works instantly — no manual setup
- Automatically updates mpv, scripts, and tools
- Seamless episode playback (auto-next)
- Remembers where you left off
- Advanced video features (HDR, interpolation) — optional
- Filmstrip timeline with previews
- Stream videos directly from your browser

---

## Zero maintenance

mpv-synth keeps itself up to date.

Press `U` at any time and it updates:
- mpv
- ffmpeg
- yt-dlp
- scripts and plugins

No manual downloads. No version mismatches. No breakage.

---

## Who this is for

- You use mpv but hate maintaining it
- You want a clean, minimal playback experience
- You watch series and want seamless episode playback
- You want advanced features without manual setup

---

## Quick Start (30 seconds)

1. Download and extract the latest release into your Program Files
2. Run `INSTALL.BAT`
3. Double-click any video

Done.

---

## What mpv-synth does differently

**It behaves like a native OS feature, not an app.** Open a video file and it plays — full stop. No splash screens, no library to build, no window hanging around after playback ends. When there are no more videos to watch in a folder, the player closes itself. It knows its job is done.

**It remembers where you are.** Close a file mid-way through and pick it up later — it resumes exactly where you left off, automatically.

**It auto-advances through episodes.** When one video ends, mpv-synth moves to the next file in the folder. Binge a season without touching anything except the occasional skip when you don't feel like watching the credits roll.

**It manages colour automatically.** The bundled ICC-detect plugin reads the colour space and HDR metadata of every file you open, and configures the player accordingly without any manual input. HDR content is passed through natively on capable displays and tone-mapped correctly on SDR displays. You get the right picture for your setup, automatically, on every file.

**It interpolates frames.** Via a full VapourSynth pipeline, mpv-synth can smoothly interpolate any video up to 30, 60, 90, 120, or 144fps — switchable from the right-click menu or with a keypress. The effect is colloquially known as the "soap opera effect", and it's entirely optional. If you've never seen it done well, give it a shot. A lot of people who claim to hate it change their minds fairly quickly once they've had some time with it.

**It has a filmstrip timeline.** The seekbar is populated with 150 evenly-spaced thumbnail slices of the video, giving you an at-a-glance map of the entire file. Hover over any point and a frame-accurate preview thumbnail appears. Jump directly to any scene with a single click.

**It streams from the web.** mpv-synth includes browser extensions for Chrome-family browsers and Firefox that add a "Play in mpv-synth" option to your right-click menu on any link to a page with video or currently open page with a video. One click routes the stream through the player, bypassing browser-based playback entirely.

**It updates itself.** Press `U` from within the player (or run `updater.bat`) and mpv-synth will pull the latest versions of mpv, ffmpeg, yt-dlp, plugins, and associated tools. Keeping everything current is a single keypress.

---

## Feature overview

| Feature | Details |
|---|---|
| Frame interpolation | VapourSynth presets at 30/60/90/120/144fps, fully customisable |
| Automatic colour management | ICC-detect reads per-file colour space and HDR metadata; native HDR passthrough on capable displays |
| Filmstrip timeline | 150 thumbnail slices composited into the seekbar; slide-from-bottom animation |
| Hover thumbnails | Frame-accurate preview on timeline hover via thumbfast, with stall watchdog for reliability |
| Auto-advance | Automatically plays next file in folder when playback ends |
| Resume playback | Position saved on exit, restored on next open |
| Browser streaming | Chrome/Edge/Brave/Vivaldi and Firefox extensions; right-click any video link to play in mpv-synth |
| Self-updating | Single keypress or script updates mpv, ffmpeg, yt-dlp, and tooling |
| Fully configurable | Right-click menu, keyboard shortcuts, and all plugin options are editable via plain text config files |

---

## Installation

### mpv-synth

1. Download and extract the zip (or clone the repo) to your chosen location — `C:\Program Files\mpv-synth` is recommended.

2. Run `INSTALL.BAT`. This single script handles everything: it downloads the latest versions of mpv, ffmpeg, ffprobe, yt-dlp, VapourSynth, and the required interfacing libraries; registers file associations; creates Start Menu and AutoPlay entries; and then removes itself. **The install is interactive** — read the prompts as they appear. Defaults are set to the recommended choices throughout, with one exception: if your computer is more than roughly a decade old, choose option 2 (`x86_64`) at the first prompt rather than the default option 1 (`x86_64-v3`). Any modern machine should handle `x86_64-v3` without issue.

3. After installation, double-click any video file. If Windows asks which app to use, select mpv-synth and tick "Always" — you shouldn't need to do this more than once per file type.

That's it. The `INSTALL.BAT` script deletes itself after a successful run. Everything from that point forward is handled by the built-in updater.

**If you need to change the build architecture after install**, open `settings.xml` in the install root and set `<arch>x86_64-v3</arch>` or `<arch>x86_64</arch>`. The next time the updater runs (or you press `U` in the player), it will switch to the selected build. Deleting `mpv.exe` forces an immediate download on next updater run.

**If performance is an issue**, open `portable_config\mpv.conf` and read the comments around the `QUALITY PROFILE` and `PERFORMANCE PROFILE` blocks. Starting with `vo=gpu` and `gpu-context=d3d11` under the Performance Profile will make the biggest difference. mpv is extremely lightweight at its core — any machine that can run Windows 11 should be able to run mpv-synth smoothly. The quality settings are there if you want them, not because the player requires them.

### Browser extensions

The browser extensions are entirely optional — mpv-synth works perfectly as a local mpv-based media player without them.

To install:

1. Extract `installer\mpv-synth-extension.zip` in place.
2. Follow the instructions in the `README.md` inside the extracted `mpv-synth-extension` folder. Installation takes under a minute and the instructions are clear.

Extensions are included for Chrome, Edge, Brave, Vivaldi, and Firefox. The Chrome and Firefox extensions share the vast majority of their code — the separation exists only because of Firefox's different extension architecture.

Once installed, right-clicking any link to a page with embedded video will show a "Play link in mpv-synth" option. Click it, and the stream routes to the player. Right clicking an empty space on a page containing a video with show a "Play page in mpv-synth" option. Click it, and again the stream routes to the player.

> Note: Extensions are currently distributed for developer-mode installation rather than through the Chrome Web Store or Firefox Add-Ons. This sounds more complicated than it is — the README inside the extension zip walks through it step by step, and it takes less than a minute. If demand warrants it, I'll pursue formal store publication.

---

## Usage

**For most things, just double-click a video.** mpv-synth registers itself as the default handler for common video formats during installation. If a file opens in something else, right-click it → Open with → Choose another app → mpv-synth, ticking "Always". If mpv-synth doesn't appear in the list, choose "Choose an app on your PC" and browse to `mpv.exe` in your install directory.

When you open a file, mpv-synth automatically builds a playlist from all videos in the same folder, ordered by filename. Once the filmstrip has generated (a few seconds on first load), the seekbar will be filled with thumbnail slices of the video. Hover over the seekbar for a frame-accurate preview at any point.

**Frame interpolation** is off by default. Enable it from the right-click menu under VapourSynth, or with the keyboard shortcuts listed below. Try 60fps first. It may take a moment to activate as VapourSynth initialises.

All plugin and player options are in `portable_config\script-opts\` — one `.conf` file per plugin, named accordingly.

### Keyboard shortcuts

All shortcuts are visible in the right-click menu next to their corresponding action. These are the ones you'll reach for most often:

| Key | Action |
|---|---|
| `Escape` | Toggle fullscreen |
| `Space` | Play / pause |
| `q` | Quit (position is saved automatically) |
| `←` / `→` | Seek 5 seconds; hold `Ctrl` for 5 minutes |
| `↑` / `↓` | Seek 30 seconds forward / back |
| `a` / `d` | Previous / next chapter |
| `w` / `s` | Previous / next frame (step) |
| `,` / `.` | Previous / next file in playlist |
| `[` / `]` | Playback speed −10% / +10% |
| `{` / `}` | Playback speed ½× / 2× |
| `Backspace` | Reset playback speed |
| `-` / `=` | Volume down / up |
| `v` | Toggle subtitle visibility |
| `Ctrl+v` | Cycle subtitle tracks |
| `Ctrl+p` | Quick menu |
| `I` | Edit input bindings and menu |
| `M` | Edit player configuration |
| `U` | Update all components (mpv, ffmpeg, yt-dlp, etc.) |
| `u` | Update uosc interface theme |

### Customising shortcuts and the right-click menu

Everything is configured in `portable_config\input.conf`. Each line follows the pattern:

```
[key]    [action]    #menu: Top Level > Submenu > Item name
```

For example:

```
Right    seek 60    #menu: Navigate > Skip > 1 min forward
```

This binds the right arrow key to skip 60 seconds, and places it in the menu at Navigate → Skip → 1 min forward. The `#menu:` portion is optional — omit it if you want the binding without a menu entry. Use `_` as the key if you want a menu entry with no keyboard shortcut. Nesting depth is unlimited: each `>` adds a submenu level.

The layout becomes obvious within a few minutes of looking at the file. You can also open it directly from within the player via Tools → Edit Config in the right-click menu, or by pressing `I`.

---

## Filmstrip and thumbnail settings

The filmstrip defaults to **150 thumbnails** generated across **4 concurrent threads**. This gives a dense, visually useful timeline and works smoothly on modest hardware — tested on a 65W Ryzen 7 mini-PC. Both values are configurable in `portable_config\script-opts\filmstrip.conf`:

```ini
thumbnail_count=150
max_concurrent=4
```

If the filmstrip is impacting playback performance during generation, reducing `max_concurrent` to 2 (or even 1) will slow thumbnail generation but eliminate any playback impact. Reducing `thumbnail_count` to 100 still looks good and generates faster. Set `thumbnail_count=0` (or `enabled=no`) to disable the filmstrip entirely.

---

## Acknowledgements

mpv-synth is built on the work of a lot of talented people. Several of the bundled components are used in modified form — patched for reliability, compatibility with this specific setup, or to resolve issues that appeared during testing.

- **[mpv](https://github.com/mpv-player/mpv)** — the player at the core of everything. Extremely capable, extraordinarily extensible.
- **[mpv-hero](https://github.com/stax76/mpv-hero/)** — the starting point and inspiration for this project.
- **[VapourSynth](https://github.com/vapoursynth/vapoursynth)** — the frame processing framework powering interpolation.
- **[uosc](https://github.com/tomasklaen/uosc)** — the interface layer. The de facto standard for mpv UI.
- **[mpv-menu-plugin](https://github.com/tsl0922/mpv-menu-plugin)** — native Windows right-click menu integration (modified).
- **[thumbfast](https://github.com/po5/thumbfast)** — timeline hover thumbnails (modified; stall watchdog added).
- **[open-file-dialog](https://github.com/rossy/mpv-open-file-dialog)** — native Windows file/folder open dialog.
- **[recent-menu](https://github.com/natural-harmonia-gropius/recent-menu)** — recently played files.
- **[bjaan](https://github.com/bjaan/)** — libraries for VapourSynth integration.

Plugins written for this project:

- **vapoursynth.lua + vapoursynth.vpy** — VapourSynth integration layer; fps preset menu.
- **filmstrip.lua** — Filmstrip timeline overlay; composite rendering; resize/fullscreen handling.
- **icc-detect.lua** — Per-file colour space and HDR detection; automatic player configuration.

---

## Buy me a coffee

I want to be straightforward: I did not expect this to take as long as it did. I came back to Windows after a long absence, found the media player situation genuinely disappointing, and decided to fix it. What started as integrating VapourSynth into an existing player base turned into months of debugging Lua timing issues, writing my own plugins from scratch, learning the internals of a rendering pipeline I didn't know existed, and testing across hardware configurations to make sure it worked reliably for people who weren't me.

The software is free. If you find yourself using it and appreciating the difference, [a coffee would mean a lot](https://buymeacoffee.com/ajcrowley). Not required, not expected — but genuinely appreciated, more than you'd think.

If you run into a problem or have an idea for something that should be here but isn't, open an issue on GitHub. I keep an eye on it and I take requests seriously.

---

## Markdown note

If you're reading this as a `.md` file without a renderer, the [Markdown Reader](https://md-reader.github.io/) browser extension will render it nicely — just drag the file to your browser's address bar or use File → Open.
