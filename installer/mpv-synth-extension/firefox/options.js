// ── Compatibility shim ──────────────────────────────────────────────────────
const api = (typeof browser !== 'undefined') ? browser : chrome;

// ── Default placeholder values ───────────────────────────────────────────────
const DEFAULT_MPV    = 'C:\\Program Files\\mpv-synth';
const DEFAULT_CONFIG = 'C:\\Program Files\\mpv-synth\\portable_config';

// ── Elements ────────────────────────────────────────────────────────────────
const mpvInput    = document.getElementById('mpvLocation');
const cfgInput    = document.getElementById('configLocation');
const browseMpv   = document.getElementById('browseMpv');
const browseCfg   = document.getElementById('browseConfig');
const saveBtn     = document.getElementById('saveBtn');
const statusEl    = document.getElementById('status');
const previewEl   = document.getElementById('preview');
const cacheSlider = document.getElementById('cacheSecs');
const cacheVal    = document.getElementById('cacheSecsVal');
const limit1080   = document.getElementById('limit1080p');

// Track which fields have been explicitly saved
let mpvSaved    = false;
let configSaved = false;

// ── Helper: normalise to Windows backslashes ─────────────────────────────────
function toWinPath(p) { return p.replace(/\//g, '\\'); }

// ── Placeholder-as-default behaviour ─────────────────────────────────────────
// Shows default value in muted italic style. On click, clears to blank if
// the value is still the unsaved default so the user types from a clean slate.
function setPlaceholder(input, value) {
  input.value = value;
  input.classList.add('is-placeholder');
}

function clearPlaceholderOnClick(input, defaultVal) {
  input.addEventListener('click', () => {
    if (input.classList.contains('is-placeholder')) {
      input.value = '';
      input.classList.remove('is-placeholder');
    }
  });
  input.addEventListener('blur', () => {
    if (input.value.trim() === '') {
      setPlaceholder(input, defaultVal);
    }
  });
}

clearPlaceholderOnClick(mpvInput, DEFAULT_MPV);
clearPlaceholderOnClick(cfgInput, DEFAULT_CONFIG);

// ── Load saved settings ─────────────────────────────────────────────────────
api.storage.sync.get(
  ['mpvLocation', 'configLocation', 'cacheSecs', 'limit1080p'],
  (s) => {
    if (s.mpvLocation) {
      mpvInput.value = toWinPath(s.mpvLocation);
      mpvInput.classList.remove('is-placeholder');
      mpvSaved = true;
    } else {
      setPlaceholder(mpvInput, DEFAULT_MPV);
    }

    if (s.configLocation) {
      cfgInput.value = toWinPath(s.configLocation);
      cfgInput.classList.remove('is-placeholder');
      configSaved = true;
    } else {
      setPlaceholder(cfgInput, DEFAULT_CONFIG);
    }

    if (s.cacheSecs !== undefined) {
      cacheSlider.value = s.cacheSecs;
    }
    cacheVal.textContent = cacheSlider.value + 's';

    limit1080.checked = !!s.limit1080p;

    updatePreview();
  }
);

// ── Slider live display ──────────────────────────────────────────────────────
cacheSlider.addEventListener('input', () => {
  cacheVal.textContent = cacheSlider.value + 's';
  updatePreview();
});

limit1080.addEventListener('change', updatePreview);

// ── Live preview ────────────────────────────────────────────────────────────
function getEffectiveMpv() {
  return mpvInput.classList.contains('is-placeholder') ? DEFAULT_MPV : mpvInput.value.trim();
}
function getEffectiveCfg() {
  return cfgInput.classList.contains('is-placeholder') ? DEFAULT_CONFIG : cfgInput.value.trim();
}

function updatePreview() {
  const mpv      = getEffectiveMpv();
  const cfg      = getEffectiveCfg();
  const secs     = cacheSlider.value;
  const cap1080  = limit1080.checked;
  const url      = 'https://www.youtube.com/watch?v=example';

  const exe  = mpv  ? `${mpv}\\mpv`     : '<mpv location>\\mpv';
  const cdir = cfg  ? `"${cfg}"`        : '"<config location>"';

  let fmt = cap1080
    ? ' --ytdl-format=bestvideo[height<=?1080][vcodec!=?vp9]+bestaudio/best'
    : '';

  previewEl.innerHTML =
    `<span>${exe}</span> --config-dir=${cdir}` +
    ` --cache=yes --cache-secs=${secs} --ytdl=yes${fmt}` +
    ` <span>${url}</span>`;
}

mpvInput.addEventListener('input', () => {
  mpvInput.classList.remove('is-placeholder');
  updatePreview();
});
cfgInput.addEventListener('input', () => {
  cfgInput.classList.remove('is-placeholder');
  updatePreview();
});

// ── Browse buttons ──────────────────────────────────────────────────────────
async function browseFolder(targetInput) {
  const btn = targetInput === mpvInput ? browseMpv : browseCfg;
  btn.disabled = true;
  btn.textContent = '⏳ …';

  try {
    const response = await new Promise((resolve, reject) => {
      api.runtime.sendMessage({ action: 'browse_folder' }, (r) => {
        if (api.runtime.lastError) reject(new Error(api.runtime.lastError.message));
        else resolve(r);
      });
    });

    if (response && response.folder) {
      targetInput.value = toWinPath(response.folder);
      targetInput.classList.remove('is-placeholder');
      updatePreview();
    } else if (response && response.error) {
      showStatus('Native host error: ' + response.error, 'err');
    }
  } catch (e) {
    showStatus('Could not contact native host. Is it installed? See README.', 'err');
  } finally {
    btn.disabled = false;
    btn.textContent = '📁 Browse';
  }
}

browseMpv.addEventListener('click', () => browseFolder(mpvInput));
browseCfg.addEventListener('click', () => browseFolder(cfgInput));

// ── Save ────────────────────────────────────────────────────────────────────
saveBtn.addEventListener('click', () => {
  const mpv  = getEffectiveMpv();
  const cfg  = getEffectiveCfg();
  const secs = parseInt(cacheSlider.value, 10);
  const cap  = limit1080.checked;

  if (!mpv || !cfg) {
    showStatus('Please fill in both path fields before saving.', 'err');
    return;
  }

  api.storage.sync.set(
    { mpvLocation: mpv, configLocation: cfg, cacheSecs: secs, limit1080p: cap },
    () => {
      mpvSaved = true;
      configSaved = true;
      // Remove placeholder styling now values are saved
      mpvInput.classList.remove('is-placeholder');
      cfgInput.classList.remove('is-placeholder');
      showStatus('✓ Settings saved!', 'ok');
    }
  );
});

// ── Status helper ───────────────────────────────────────────────────────────
function showStatus(msg, type) {
  statusEl.textContent = msg;
  statusEl.className = type;
  clearTimeout(showStatus._t);
  if (type === 'ok') {
    showStatus._t = setTimeout(() => { statusEl.className = ''; }, 3000);
  }
}
