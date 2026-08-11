# mpv-synth
### A media player for Windows built for how people actually watch things

Official website: https://mpvsynth.app

mpv-synth is a Windows media player built on mpv, with frame interpolation, automatic HDR colour management, a filmstrip timeline, OpenSubtitles integration, and one-click browser streaming. Free and open source.

![mpv-synth](screenshot-opensubs.png)

---

## The problem

Windows has never had a great media player. The third-party ecosystem hasn't kept pace with how people watch things now. The most popular options work, but they feel like they were designed a decade ago, because they were.

Clunky interfaces assembled from stock Windows form components. Windows that sit on your desktop doing nothing after playback ends. No memory of where you were in a file. No awareness that you might want to move on to the next episode automatically. No consideration of the display you're watching on, the colour space of the content, or whether the motion could benefit from interpolation.

Compare it to your phone. You open a file and it plays. When it's done, it's done. It gets out of the way. There's no application to wrangle. It feels like a feature that should be part of any modern operating system.

That's the experience mpv-synth delivers on Windows. Open a video file and it plays, full stop. No splash screens, no library to build, no window hanging around after playback ends. When there are no more videos to watch in a folder, the player closes itself. It knows its job is done.

---

## Features

**Frame Interpolation** — Full VapourSynth pipeline. Feed it any framerate. Match your display's refresh rate, stick to 60fps, or push 144. The presets in the right-click menu are just numbers in a config file: change them, add more, remove ones you don't need. Set it to activate automatically and limit by resolution, if your GPU handles 1080p fine but struggles at 4K, set a max resolution and it only kicks in below that. Entirely optional → the player works fine without it.

**Automatic Colour Management** — The icc-detect plugin reads the colour space and HDR metadata of every file on load. HDR content passes through natively on capable displays and tone-maps correctly on SDR, automatically, every time.

**Filmstrip Timeline** — 150 evenly-spaced thumbnail slices by default, have as many or as few as you like to achieve your best look, composited into the seekbar, giving you a visual map of the entire file. Hover for a frame-accurate preview. Jump to any scene with a click.

**Auto-advance & Resume** — When a video ends, mpv-synth moves to the next file in the folder automatically → when you quit mid-file, it resumes exactly where you stopped. No manual bookmarking required.

**Smart Subtitle Selection** — The auto-subs plugin activates a subtitle track only when it matches every term in a configurable list → `match=en,forced` picks up English (Forced) automatically, while leaving everything else untouched. Fine-grained, or one-word simple.

**OpenSubtitles Integration** — The opensubs plugin searches and downloads subtitles from OpenSubtitles and other providers directly from the right-click menu. Manual search, best-match download, or browse results, all without leaving the player. Supports login credentials for premium providers.

**Simplified On-Screen Controls** — The osc-simplified plugin replaces mpv's default OSC with a clean, minimal control bar. Configurable skip buttons (left, right, middle click, each with its own seek duration), dark and light modes, and rounded corners. No clutter.

**Dynamic Right-Click Menu** — The dyn_menu plugin builds a native Windows context menu from your input.conf bindings. Every shortcut you define appears in the menu automatically, organized by the menu path you specify. No separate menu config to maintain. Modified from the original mpv-menu-plugin for reliability.

**Self-updating** — Press `U` from within the player to pull the latest versions of mpv, ffmpeg, yt-dlp, plugins, and the updater itself. The entire toolchain stays current with a single keypress, or run `updater.bat` directly without opening the player.

---

## Quick Start

1. Download and extract the latest release. `C:\Program Files\` is the recommended location.
2. Run `INSTALL.BAT` (right-click and Run as Administrator on Windows 10).
3. Double-click any video.

Done.

---

## Installation

### mpv-synth

1. Download the zip and extract it where you want the installation to live. `C:\Program Files\` is the recommended location.

2. Run `INSTALL.BAT`. This single script downloads the latest versions of mpv, ffmpeg, ffprobe, yt-dlp, and VapourSynth\*; registers file associations; creates Start Menu and AutoPlay entries; then removes itself. **The install is interactive**. Read the prompts as they appear. Defaults are set to the recommended choices throughout, with one exception: if your machine is more than roughly a decade old, choose `x86_64` at the first prompt rather than the default `x86_64-v3`. Any modern hardware should handle v3 fine.

3. Set your language (optional, English by default). Open `portable_config\mpv.conf` and set your preferred language codes:
   ```
   alang=ja,jpn,en
   slang=en,eng
   ```
   For subtitles to activate automatically, edit `portable_config\script-opts\auto-subs.conf` and set your match terms. A track is only selected if it matches every term in the list, so you can be as broad or as specific as you like:
   ```
   match=en,forced
   ```
   The `match` list is comma-separated with no spaces. Each entry must appear somewhere in the subtitle track's name or language tag for it to be selected. The default `match=en,forced` targets tracks labelled something like English (Forced).

4. Double-click a video. mpv-synth registers itself as the default handler for common video formats. If Windows asks which app to use, select mpv-synth and tick "Always".

\* VapourSynth have released R74, which is not yet compatible, so R73 will be used until such time as that changes.

### Browser extensions

The browser extensions are completely optional. mpv-synth works perfectly as a local player without them. They add a "Play in mpv-synth" right-click option to any page with embedded video in Chrome-family browsers and Firefox.

1. Extract `installer\mpv-synth-extension.zip` in place. Then, inside the `native\` folder, right-click `install.bat` and choose "Run as Administrator". This registers the Python host that allows the browser to securely launch mpv. You only need to do this once. **Prerequisite:** Python 3 must be installed and on your PATH.

2. Load the extension in your browser. **Chrome / Edge / Brave / Vivaldi:** Go to `chrome://extensions`, enable Developer Mode, click "Load unpacked", and select the `chrome\` folder. **Firefox:** Go to `about:debugging#/runtime/this-firefox`, click "Load Temporary Add-on...", navigate to the `firefox\` folder, and select `manifest.json`.

3. Click the mpv-synth icon in your toolbar. Fill in the mpv Location (the folder containing `mpv.exe`) and Config Location. If you installed to the default location, you can leave the pre-filled placeholders as-is. Click Save.

Extensions are currently distributed for developer-mode installation rather than through browser extension stores. This sounds more technical than it is. The walkthrough above covers everything, and it takes under a minute.

---

## Usage

All actions are available in the right-click menu with keyboard shortcuts displayed alongside them. Here are the ones you'll reach for most often:

| Key | Action |
|---|---|
| `Escape` | Toggle fullscreen |
| `Space` | Play / Pause |
| `q` | Quit → position saved automatically |
| `←` / `→` | Seek 5 seconds; hold `Ctrl` for 5 minutes |
| `↑` / `↓` | Seek 30 seconds forward / back |
| `a` / `d` | Previous / next chapter |
| `w` / `s` | Step one frame forward / back |
| `,` / `.` | Previous / next file in folder |
| `[` / `]` | Playback speed −10% / +10% |
| `{` / `}` | Playback speed ½× / 2× |
| `Backspace` | Reset playback speed |
| `-` / `=` | Volume down / up |
| `v` | Toggle subtitle visibility |
| `Ctrl+v` | Cycle subtitle tracks |
| `Shift+s` | Browse OpenSubtitles |
| `Alt+t` | Download best-match subtitles from OpenSubtitles |
| `Alt+s` | Manual OpenSubtitles search |
| `Ctrl+i` | Toggle automatic ICC profile detection |
| `Alt+` | VapourSynth off |
| `Alt+5` | VapourSynth 60fps |
| `Alt+8` | VapourSynth 120fps |
| `I` | Edit keyboard bindings & menu |
| `E` | Edit player configuration |
| `U` | Update all components (mpv, ffmpeg, yt-dlp…) |
| `t` | Toggle statistics overlay |

### Customising shortcuts and the right-click menu

All shortcuts and right-click menu entries are defined in `portable_config\input.conf`. Each line follows this pattern:

```
[key]    [action]    #menu: Top Level > Submenu > Item name
```

For example:
```
Right    seek 60    #menu: Navigate > Skip > 1 min forward
```

The `#menu:` portion is optional → omit it for a binding with no menu entry. Use `_` as the key for a menu entry with no keyboard shortcut. Each `>` adds a submenu level. Open the file via Tools → Edit Config in the right-click menu, or press `I`.

All plugin options live in `portable_config\script-opts\`, one `.conf` file per plugin, named accordingly. The main player options are in `portable_config\mpv.conf`. Each setting includes a comment describing what it does and its type, so you can edit them in any text editor. Every plugin written for mpv-synth can be disabled with `enabled=no` at the top of its conf file.

### Filmstrip settings

The filmstrip defaults to 150 thumbnails generated across 4 concurrent threads. This gives a dense, visually rich timeline and runs smoothly on modest hardware, tested on a 65W Ryzen 7 mini-PC.

```ini
# portable_config\script-opts\filmstrip.conf
thumbnail_count=150
max_concurrent=4
```

If generation impacts playback, reduce `max_concurrent` to 2 or 1 → thumbnails will build more slowly, but playback won't be affected. `thumbnail_count=100` still looks great.

---

## Acknowledgements

mpv-synth is built on the work of a lot of talented people. Several plugins were written from scratch for this project. Others are bundled from open source projects, some modified for reliability or to resolve issues found during testing.

**Core:**
- [mpv](https://github.com/mpv-player/mpv) — the player at the core of everything. Extraordinarily capable, extraordinarily extensible.
- [mpv-hero](https://github.com/stax76/mpv-hero/) — the starting point and inspiration for this project.

**Original plugins (written for mpv-synth):**
- **auto-subs** — automatic subtitle selection based on configurable match terms.
- **opensubs** — OpenSubtitles search and download directly from the player. Supports multiple providers with optional login credentials.
- **filmstrip** — filmstrip timeline with configurable generation and animation.
- **icc-detect** — automatic ICC profile and HDR detection. Tone-maps HDR content on SDR displays using configurable algorithms.
- **osc-simplified** — minimal on-screen control bar with configurable skip buttons, dark/light modes, and rounded corners.
- **vapoursynth** — frame interpolation integration. VapourSynth filter management with configurable FPS presets and auto-apply rules.
- **open-file-dialog** — native Windows file/folder open dialog integration.

**Modified from open source:**
- [dyn_menu](https://github.com/tsl0922/mpv-menu-plugin) — dynamic right-click menu generated from input.conf bindings. Modified from the original mpv-menu-plugin for reliability.
- [thumbfast](https://github.com/po5/thumbfast) — timeline hover thumbnails. Heavily modified → stall watchdog added, filmstrip integration, configurable process priority.

**Bundled:**
- [VapourSynth](https://github.com/vapoursynth/vapoursynth) — the frame processing framework powering interpolation.
- [uosc](https://github.com/tomasklaen/uosc) — the interface layer. The de facto standard for mpv UI.
- [recent-menu](https://github.com/natural-harmonia-gropius/recent-menu) — recently played files list.
- [bjaan](https://github.com/bjaan/) — libraries for VapourSynth integration and interpolation.

---

## Support

mpv-synth is and always will be free. No premium tier, no feature gates, no ads. The code is on GitHub for anyone to read, fork, or contribute to.

What it isn't is cost-free to build. The plugins, the bug hunts, the rendering pipeline deep dives. That's real time, and time is the one thing you can't get back. A small donation says "keep going" in a way that matters more than a star.

If mpv-synth has been useful, that's enough. If you'd like to see it grow faster → a proper GUI for managing settings without touching conf files, more plugins, better documentation, then a coffee helps make that happen sooner rather than later.

☕ **[Support development](https://buymeacoffee.com/ajcrowley)**

If you run into a problem, [open an issue on GitHub](https://github.com/AJCrowley/mpv-synth/issues).

---

## Roadmap

- **Now → Player & plugins:** The core player is stable and in daily use. Plugins are actively maintained.
- **Autumn → GUI testing:** A Tauri-based GUI is in development to manage settings, updates, and plugins without touching conf files. Internal testing begins this autumn.
- **After testing → Full release:** Barring paid work getting in the way, a full public GUI release should follow, aimed at users of all technical levels, not just those comfortable editing config files.