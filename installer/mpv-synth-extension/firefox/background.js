// ── Native Messaging Host identifier (must match native/mpv_synth_host.json "name")
const NATIVE_HOST = 'com.mpvsynth.launcher';

// ── Compatibility shim: normalise browser vs chrome namespaces ──────────────
const api = (typeof browser !== 'undefined') ? browser : chrome;

// ── Create context menu entries on install ──────────────────────────────────
api.runtime.onInstalled.addListener(() => {
  // Right-click on a link
  api.contextMenus.create({
    id: 'play-link-in-mpv-synth',
    title: 'Play link in mpv-synth',
    contexts: ['link']
  });
  // Right-click anywhere on a page that contains video
  api.contextMenus.create({
    id: 'play-page-in-mpv-synth',
    title: 'Play this page in mpv-synth',
    contexts: ['page', 'video']
  });
});

// ── Helper: send a one-shot message to the native host ─────────────────────
function sendNative(message) {
  return new Promise((resolve, reject) => {
    if (typeof browser !== 'undefined' && browser.runtime.sendNativeMessage) {
      browser.runtime.sendNativeMessage(NATIVE_HOST, message)
        .then(resolve)
        .catch(reject);
    } else {
      chrome.runtime.sendNativeMessage(NATIVE_HOST, message, (response) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve(response);
        }
      });
    }
  });
}

// ── Build the URL to play based on context ──────────────────────────────────
// tab.url is the authoritative source for the current page URL and requires
// the "tabs" permission. info.pageUrl is a fallback — it can be undefined
// when right-clicking on a <video> element due to the browser's own video
// context menu layer intercepting the event before the extension sees it.
function getUrlFromInfo(info, tab) {
  if (info.menuItemId === 'play-link-in-mpv-synth') return info.linkUrl;
  // For page/video context: prefer tab.url (reliable), fall back to pageUrl
  return (tab && tab.url) || info.pageUrl;
}

// ── Context menu click handler ─────────────────────────────────────────────
api.contextMenus.onClicked.addListener((info, tab) => {
  const knownItems = ['play-link-in-mpv-synth', 'play-page-in-mpv-synth'];
  if (!knownItems.includes(info.menuItemId)) return;

  const url = getUrlFromInfo(info, tab);
  if (!url) return;

  api.storage.sync.get(
    ['mpvLocation', 'configLocation', 'cacheSecs', 'limit1080p'],
    (settings) => {
      if (!settings.mpvLocation || !settings.configLocation) {
        api.runtime.openOptionsPage();
        return;
      }

      sendNative({
        action:           'play',
        mpv_location:     settings.mpvLocation,
        config_location:  settings.configLocation,
        cache_secs:       settings.cacheSecs !== undefined ? settings.cacheSecs : 30,
        limit_1080p:      !!settings.limit1080p,
        url:              url
      }).catch((err) => {
        console.error('[mpv-synth] Native messaging error:', err.message);
      });
    }
  );
});

// ── Toolbar icon click → open options ─────────────────────────────────────
if (api.action) {
  api.action.onClicked.addListener(() => api.runtime.openOptionsPage());
} else if (api.browserAction) {
  api.browserAction.onClicked.addListener(() => api.runtime.openOptionsPage());
}

// ── Message listener for options page (browse-folder requests) ─────────────
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.action === 'browse_folder') {
    sendNative({ action: 'browse_folder' })
      .then((response) => sendResponse({ folder: response.folder || '' }))
      .catch((err)  => sendResponse({ folder: '', error: err.message }));
    return true;
  }
});
