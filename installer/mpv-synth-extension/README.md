# mpv-synth Browser Extension

Right-click any link in Chrome or Firefox and choose **"Play link in mpv-synth"**
to open it directly in mpv-synth.

If on a page with a video already embedded, click an empty area of the page and
select **"Play page in mpv-synth"** to open it directly in mpv-synth.

---

## What's in this package

```
mpv-synth-extension/
├── chrome/          ← Load this folder as an unpacked extension in Chrome/Edge/Brave
│   ├── manifest.json
│   ├── background.js
│   ├── options.html
│   └── icons/
├── firefox/         ← Load this folder as a temporary/permanent extension in Firefox
│   ├── manifest.json
│   ├── background.js
│   ├── options.html
│   └── icons/
├── native/          ← Native messaging host (run install.bat FIRST)
│   ├── install.bat          ← Run this once to register the host
│   ├── uninstall.bat        ← Run this to remove registry entries
│   ├── mpv_synth_host.py    ← Python host script
│   ├── mpv_synth_host.bat   ← Wrapper called by the browser
│   └── mpv_synth_host.json  ← Host manifest template
└── README.md
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| **Python 3.x** (Windows) | Runs the native messaging host script |
| **mpv-synth** installed | The player that gets launched |

Download Python from https://www.python.org/downloads/ — make sure to check
**"Add Python to PATH"** during installation.

---

## Step 1 — Install the native messaging host

> This registers a small Python script with Windows so the browser can securely
> launch mpv when you click the menu item.

1. Open the `native\` folder.
2. Right-click **`install.bat`** and Run as Administrator.
3. A console window will confirm the registry keys were written and close.

You only need to do this once. If you ever move the folder, re-run `install.bat`.

---

## Step 2 — Load the extension in Chrome (or Edge / Brave / Vivaldi)

1. Go to `chrome://extensions` (or `edge://extensions`, etc.)
2. Enable **Developer mode** (toggle, top-right corner).
3. Click **"Load unpacked"**.
4. Select the **`chrome\`** folder from this package.
5. The mpv-synth icon will appear in your toolbar.

> **Chrome extension ID**: `opmkcnnaphplcmphaebinkddpcfakjla`  
> This ID is embedded in the native host manifest; it must match exactly.
> As long as you use the included `chrome\manifest.json` (which contains a
> `"key"` field), Chrome will always assign this same ID.

---

## Step 2 (alternative) — Load the extension in Firefox

### Temporary (lasts until Firefox restarts — good for testing)

1. Go to `about:debugging#/runtime/this-firefox`
2. Click **"Load Temporary Add-on…"**
3. Navigate to the `firefox\` folder and select **`manifest.json`**.

### Permanent (stays across restarts — requires signing or policy override)

**Option A — Developer Edition / Nightly (easiest)**

1. Open `about:config` and set `xpinstall.signatures.required` to `false`.
2. Go to `about:addons` → gear icon → **"Install Add-on From File…"**
3. Select the `firefox\` folder (Firefox will package it automatically).

**Option B — Enterprise policy (corporate environments)**

Add the extension ID `mpv-synth@extension` to your
`ExtensionSettings` policy with `"installation_mode": "allowed_and_offline_enabled"`.

---

## Step 3 — Configure paths

1. Click the **mpv-synth icon** in the toolbar (or right-click a link and choose
   the menu item — it will open Settings if not yet configured).
2. Fill in:
   - **mpv Location** — the *folder* containing `mpv.exe`, e.g.  
     `C:\Program Files\mpv-synth`
   - **Config Location** — the folder passed to `--config-dir`, e.g.  
     `C:\Program Files\mpv-synth\portable-config`
   - If you don't fill these out it will just save the defaults which are displayed
     as placeholders
   - **Cache Time** — value in seconds of how much video to cache
   - **Limit video to 1080p** — Limit resolution of streamed video to 1080p
3. Use the **📁 Browse** buttons to pick folders visually (requires the native
   host from Step 1).
4. Click **Save Settings**.

---

## Usage

Right-click **any link** on any page → **"Play link in mpv-synth"**.
Right-click **any page** containing a video → **"Play page in mpv-synth"**.

The extension will run (example):

```
C:\Program Files\mpv-synth\mpv.exe --config-dir="C:\Program Files\mpv-synth\portable-config" --cache=yes --cache-secs=30 --ytdl=yes --ytdl-format=bestvideo[height<=?1080][vcodec!=?vp9]+bestaudio/best https://www.youtube.com/watch?v=9izTX_e-GEA
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Play in mpv-synth" opens Settings instead of playing | Save both paths in the Settings page first |
| Browse button does nothing / returns empty path | Run `native\install.bat`; make sure Python 3 is installed |
| mpv launches but shows an error about config | Check that the Config Location folder exists |
| Firefox: "Native host has exited" error | Ensure Python is on PATH (`py --version` in cmd) |
| Chrome: "Specified native messaging host not found" | Re-run `install.bat`; verify the registry key exists under `HKCU\Software\Google\Chrome\NativeMessagingHosts\com.mpvsynth.launcher` |

**Log file**: The native host writes a log to `native\mpv_synth_host.log`.
Check this file if something goes wrong.

---

## Uninstalling

1. Remove the extension from your browser's extensions page.
2. Run `native\uninstall.bat` to clean up registry entries.
3. Delete this folder.
