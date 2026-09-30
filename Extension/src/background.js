'use strict';
/*
 * Background: capture, context menus, media registry, settings cache and the native relay
 * (spec §7.3). Runs as Chrome's MV3 service worker entry (importScripts below) and as one of
 * Safari's background scripts (lib/hdm.js is listed before this file there).
 */
if (typeof HDM === 'undefined' && typeof importScripts === 'function') importScripts('lib/hdm.js');

const B = globalThis.browser && globalThis.browser.runtime ? globalThis.browser : globalThis.chrome;

const state = {
  settings: Object.assign({}, HDM.DEFAULT_SETTINGS),
  altClicks: new Map(),     // url → timestamp (⌥-click bypass, §7.3)
  mediaByTab: new Map(),    // tabId → [{url, kind, mime}]
  drmTabs: new Set(),
};

// --- Native relay ----------------------------------------------------------------

function detectBrowser() {
  const ua = (navigator && navigator.userAgent) || '';
  if (ua.includes('Brave')) return 'brave';
  if (ua.includes('Edg/')) return 'edge';
  if (ua.includes('Vivaldi')) return 'vivaldi';
  if (B.runtime.getURL('').startsWith('safari-web-extension')) return 'safari';
  return 'chrome';
}

/** `name=value; …` for every cookie the browser would send to `url` (HttpOnly included). */
async function cookieHeader(url) {
  try {
    const jar = await B.cookies.getAll({ url });
    return jar.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ');
  } catch {
    return '';
  }
}

/**
 * Video queries need the page's cookies (members-only pages such as Kajabi courses redirect
 * yt-dlp to a login page without them) and every stream the tab has produced so far.
 */
async function enrichMediaQuery(message, tabId) {
  const enriched = Object.assign({}, message);
  if (!enriched.cookies && HDM.isHttpUrl(enriched.pageUrl)) {
    enriched.cookies = (await cookieHeader(enriched.pageUrl)) || undefined;
  }
  enriched.streams = HDM.mergeStreams(enriched.streams || [], tabId != null ? tabMedia(tabId) : []);
  return enriched;
}

function sendNative(message) {
  return new Promise((resolve) => {
    try {
      B.runtime.sendNativeMessage(HDM.NATIVE_HOST, message, (reply) => {
        resolve(reply || { ok: false, error: 'app_unavailable' });
      });
    } catch (error) {
      resolve({ ok: false, error: String(error) });
    }
  });
}

// --- Settings cache (§7.1: hello refreshes it) ------------------------------------

async function loadCachedSettings() {
  try {
    const stored = await B.storage.local.get('settings');
    if (stored && stored.settings) {
      state.settings = Object.assign({}, HDM.DEFAULT_SETTINGS, stored.settings);
    }
  } catch { /* storage unavailable */ }
}

async function refreshSettings() {
  const reply = await sendNative(HDM.makeMessage('hello', {
    browser: detectBrowser(), extensionVersion: HDM.EXTENSION_VERSION,
  }));
  if (reply && reply.ok && reply.hello) {
    // Keep the user's popup toggle and popup-added exceptions; take the rest from the app.
    state.settings.captureEnabled = reply.hello.captureEnabled;
    state.settings.fileTypes = reply.hello.fileTypes || state.settings.fileTypes;
    state.settings.exceptions = reply.hello.exceptions || state.settings.exceptions;
    state.settings.minimumSizeBytes = reply.hello.minimumSizeBytes || 0;
    state.settings.panelEnabled = reply.hello.panelEnabled !== false;
    try { await B.storage.local.set({ settings: state.settings }); } catch { }
  }
}

async function persistSettings() {
  try { await B.storage.local.set({ settings: state.settings }); } catch { }
}

loadCachedSettings().then(refreshSettings);
setInterval(refreshSettings, 60_000);

// --- Capture (Chrome family; Safari has no downloads API — content script handles it)

function baseName(path) {
  const raw = String(path || '').split(/[\\/]/).pop();
  return raw || '';
}

function recentAltClick(url) {
  const stamp = state.altClicks.get(url);
  if (!stamp) return false;
  if (Date.now() - stamp > 2000) {
    state.altClicks.delete(url);
    return false;
  }
  return true;
}

if (B.downloads && B.downloads.onCreated) {
  B.downloads.onCreated.addListener(async (item) => {
    try {
      const url = item.finalUrl || item.url;
      if (!HDM.isHttpUrl(url)) return;
      if (recentAltClick(item.url) || recentAltClick(url)) return;
      const name = baseName(item.filename && item.filename.current != null ? item.filename.current : item.filename);
      const captured = HDM.shouldCapture({
        url, filename: name, mime: item.mime,
        size: typeof item.fileSize === 'number' && item.fileSize >= 0 ? item.fileSize : undefined,
      }, state.settings);
      if (!captured) return;

      await B.downloads.pause(item.id);
      let cookies = '';
      try {
        const jar = await B.cookies.getAll({ url });
        cookies = jar.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ');
      } catch { }
      const reply = await sendNative(HDM.makeMessage('download', {
        url,
        referrer: item.referrer || undefined,
        filename: name || undefined,
        mime: item.mime || undefined,
        size: typeof item.fileSize === 'number' && item.fileSize >= 0 ? item.fileSize : undefined,
        cookies: cookies || undefined,
        userAgent: navigator.userAgent,
        source: 'capture',
      }));
      if (reply && reply.ok) {
        try { await B.downloads.cancel(item.id); } catch { }
        try { await B.downloads.erase({ id: item.id }); } catch { }
      } else {
        try { await B.downloads.resume(item.id); } catch { }   // never lose a download (§7.3)
      }
    } catch {
      try { await B.downloads.resume(item.id); } catch { }
    }
  });
}

// --- Context menus (§7.3) ----------------------------------------------------------

function installMenus() {
  if (!B.contextMenus) return;
  B.contextMenus.removeAll(() => {
    B.contextMenus.create({ id: 'hdm-link', title: HDM.t('downloadWithHDM'), contexts: ['link'] });
    B.contextMenus.create({ id: 'hdm-all', title: HDM.t('downloadAllWithHDM'), contexts: ['page', 'selection'] });
  });
}
B.runtime.onInstalled.addListener(installMenus);

function pageLinks(selectionOnly) {
  let scope = document;
  if (selectionOnly && window.getSelection && window.getSelection().rangeCount) {
    scope = window.getSelection().getRangeAt(0).cloneContents();
  }
  const links = [];
  for (const anchor of scope.querySelectorAll ? scope.querySelectorAll('a[href]') : []) {
    if (/^https?:/i.test(anchor.protocol)) {
      links.push({ url: anchor.href, text: (anchor.textContent || '').trim().slice(0, 120) });
    }
  }
  return links.slice(0, 500);
}

async function collectLinks(tab, selectionOnly) {
  if (!B.scripting || !tab) return [];
  const results = await B.scripting.executeScript({
    target: { tabId: tab.id },
    func: pageLinks,
    args: [Boolean(selectionOnly)],
  });
  const seen = new Set();
  const links = [];
  for (const frame of results || []) {
    for (const link of frame.result || []) {
      if (seen.has(link.url)) continue;
      seen.add(link.url);
      links.push(link);
    }
  }
  return links;
}

if (B.contextMenus) {
  B.contextMenus.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId === 'hdm-link' && info.linkUrl) {
      let cookies = '';
      try {
        const jar = await B.cookies.getAll({ url: info.linkUrl });
        cookies = jar.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ');
      } catch { }
      sendNative(HDM.makeMessage('download', {
        url: info.linkUrl, referrer: info.pageUrl, cookies: cookies || undefined,
        userAgent: navigator.userAgent, source: 'context',
      }));
    } else if (info.menuItemId === 'hdm-all') {
      const links = await collectLinks(tab, Boolean(info.selectionText && info.selectionText.length));
      if (links.length) {
        sendNative(HDM.makeMessage('downloadLinks', {
          links, pageUrl: info.pageUrl, userAgent: navigator.userAgent,
        }));
      }
    }
  });
}

// --- Media registry (§8.1) --------------------------------------------------------

function tabMedia(tabId) {
  return (state.mediaByTab.get(tabId) || []).slice();
}

function storeMedia(tabId, streams, frameUrl) {
  if (!streams || !streams.length) return;
  const current = state.mediaByTab.get(tabId) || [];
  const seen = new Set(current.map((item) => item.url));
  for (const stream of streams) {
    const kind = HDM.classifyMedia(stream.url, stream.mime);
    if (!kind || seen.has(stream.url)) continue;
    current.push({ url: stream.url, kind, mime: stream.mime, frameUrl: stream.frameUrl || frameUrl });
    seen.add(stream.url);
  }
  if (current.length > 50) current.splice(0, current.length - 50);
  state.mediaByTab.set(tabId, current);
}

// Chrome/Brave (spec §8.1): streams whose URL has no media extension are recognised by their
// Content-Type, e.g. Wistia's …/deliveries/<id>.bin (video/mp4) or extensionless HLS playlists.
if (B.webRequest && B.webRequest.onResponseStarted) try {   // Safari may not offer responseHeaders
  B.webRequest.onResponseStarted.addListener((details) => {
    if (details.tabId == null || details.tabId < 0) return;
    const header = (details.responseHeaders || []).find((h) => h.name && h.name.toLowerCase() === 'content-type');
    const mime = header && header.value ? header.value : '';
    if (!HDM.classifyMedia(details.url, mime)) return;
    storeMedia(details.tabId, [{ url: details.url, mime, frameUrl: details.documentUrl || details.initiator }], details.initiator);
  }, { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'other'] }, ['responseHeaders']);
} catch { /* content-script detection still works */ }

B.tabs && B.tabs.onRemoved.addListener((tabId) => {
  state.mediaByTab.delete(tabId);
  state.drmTabs.delete(tabId);
});

// --- Message router (content scripts + popup) --------------------------------------

B.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    try {
      switch (message && message.type) {
        case 'altClick':
          state.altClicks.set(message.url, Date.now());
          return sendResponse({ ok: true });
        case 'getSettings':
          return sendResponse({ ok: true, settings: state.settings });
        case 'setCapture':
          state.settings.captureEnabled = Boolean(message.enabled);
          await persistSettings();
          return sendResponse({ ok: true });
        case 'excludeSite':
          if (message.pattern && !state.settings.localExceptions.includes(message.pattern)) {
            state.settings.localExceptions.push(message.pattern);
            await persistSettings();
          }
          return sendResponse({ ok: true });
        case 'mediaFound':
          storeMedia(sender.tab && sender.tab.id, message.streams, sender.url);
          return sendResponse({ ok: true });
        case 'drmFound':
          state.drmTabs.add(sender.tab && sender.tab.id);
          return sendResponse({ ok: true });
        case 'getTabMedia': {
          const tabId = message.tabId != null ? message.tabId : (sender.tab && sender.tab.id);
          return sendResponse({ ok: true, media: tabMedia(tabId), drm: state.drmTabs.has(tabId) });
        }
        case 'native': {
          let outgoing = message.message;
          if (outgoing && outgoing.type === 'mediaQuery') {
            outgoing = await enrichMediaQuery(outgoing, sender.tab && sender.tab.id);
          }
          return sendResponse(await sendNative(outgoing));
        }
        default:
          return sendResponse({ ok: false, error: 'unknown_message' });
      }
    } catch (error) {
      sendResponse({ ok: false, error: String(error) });
    }
  })();
  return true;   // keep the channel open for the async reply
});
