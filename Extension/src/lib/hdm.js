'use strict';
/*
 * Shared library for every HDM extension context (spec §3 "Eklenti" row):
 * loaded as a classic script — content scripts list it first, Chrome's service worker
 * importScripts()s it, Safari loads it via background.scripts, Node tests run it in a VM.
 * Everything lands on globalThis.HDM.
 */
(function (root) {
  const EXTENSION_VERSION = '0.2.0';
  const NATIVE_HOST = 'com.macdm.bridge';

  const DEFAULT_SETTINGS = {
    captureEnabled: true,
    fileTypes: ['3gp','7z','aac','apk','avi','bz2','dmg','doc','docx','epub','exe','flac','flv','gz',
      'iso','m4a','m4v','mkv','mov','mp3','mp4','mpeg','mpg','msi','ogg','opus','pdf','pkg',
      'ppt','pptx','rar','tar','tgz','wav','webm','wma','wmv','xls','xlsx','xz','zip'],
    exceptions: [],
    localExceptions: [],   // added from the popup; merged with app-provided patterns
    minimumSizeBytes: 0,
    panelEnabled: true,
  };

  function isHttpUrl(url) {
    try { const u = new URL(url); return u.protocol === 'http:' || u.protocol === 'https:'; }
    catch { return false; }
  }

  function hostOf(url) {
    try { return new URL(url).hostname.toLowerCase(); } catch { return ''; }
  }

  function pathOf(url) {
    try { return new URL(url).pathname; } catch { return ''; }
  }

  function extensionOf(url) {
    const base = pathOf(url).substring(pathOf(url).lastIndexOf('/') + 1);
    const dot = base.lastIndexOf('.');
    return dot === -1 ? '' : base.substring(dot + 1).toLowerCase();
  }

  const MIME_EXTENSIONS = {
    'application/zip': 'zip', 'application/x-zip-compressed': 'zip', 'application/x-7z-compressed': '7z',
    'application/x-rar-compressed': 'rar', 'application/gzip': 'gz', 'application/x-tar': 'tar',
    'application/pdf': 'pdf', 'application/octet-stream': '',
    'application/x-apple-diskimage': 'dmg', 'application/x-msdownload': 'exe',
    'application/vnd.android.package-archive': 'apk',
    'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/ogg': 'ogg', 'audio/opus': 'opus',
    'audio/x-wav': 'wav', 'audio/x-flac': 'flac', 'audio/aac': 'aac',
    'video/mp4': 'mp4', 'video/webm': 'webm', 'video/quicktime': 'mov', 'video/x-matroska': 'mkv',
    'text/plain': 'txt',
  };

  function extensionFromMime(mime) {
    const key = String(mime || '').split(';')[0].trim().toLowerCase();
    return MIME_EXTENSIONS[key] || '';
  }

  /** Same wildcard semantics as HDMCore.SiteExceptions so both sides agree. */
  function matchesException(host, patterns) {
    if (!host) return false;
    for (const raw of patterns) {
      const pattern = String(raw || '').trim().toLowerCase();
      if (!pattern) continue;
      if (pattern.startsWith('*.')) {
        const domain = pattern.slice(2);
        if (host === domain || host.endsWith('.' + domain)) return true;
      } else if (pattern.endsWith('.*')) {
        const base = pattern.slice(0, -2);
        if (host === base || (host.startsWith(base + '.') && !host.slice(base.length + 1).includes('.'))) return true;
      } else if (pattern.includes('*')) {
        if (globMatch(pattern, host)) return true;
      } else if (host === pattern || host.endsWith('.' + pattern)) {
        return true;
      }
    }
    return false;
  }

  function globMatch(pattern, host) {
    const patternParts = pattern.split('.');
    const hostParts = host.split('.');
    if (patternParts.length !== hostParts.length) return false;
    return patternParts.every((part, i) => labelGlob(part, hostParts[i]));
  }

  function labelGlob(pattern, text) {
    const p = pattern.split('*');
    let index = 0;
    for (let i = 0; i < p.length; i++) {
      if (p[i] === '') continue;
      index = text.indexOf(p[i], index);
      if (index === -1) return false;
      if (i === 0 && index !== 0) return false;   // leading literal must anchor
      index += p[i].length;
    }
    const tail = p[p.length - 1];
    if (tail !== '' && !text.endsWith(tail)) return false;
    return true;
  }

  /** The capture decision (spec §7.3): all conditions must hold. */
  function shouldCapture(download, settings) {
    if (!settings || !settings.captureEnabled) return false;
    if (!isHttpUrl(download.url)) return false;   // blob:/data: stay in the browser
    const host = hostOf(download.url);
    if (matchesException(host, (settings.exceptions || []).concat(settings.localExceptions || []))) return false;
    if (settings.minimumSizeBytes > 0 && typeof download.size === 'number' && download.size > 0
        && download.size < settings.minimumSizeBytes) return false;
    const nameExt = download.filename ? String(download.filename).split('.').pop().toLowerCase() : '';
    const ext = extensionOf(download.url) || nameExt || extensionFromMime(download.mime);
    if (!ext) return false;
    return (settings.fileTypes || []).includes(ext);
  }

  /** null (not media) | 'file' | 'hls' | 'dash' (spec §8.1). Fragment parts are dropped. */
  function classifyMediaUrl(url) {
    const path = pathOf(url);
    if (/\.(ts|m4s)(\?|$)/i.test(path) || /\/seg-?\d|\/range\//i.test(path)) return null;
    const ext = extensionOf(url);
    if (ext === 'm3u8') return 'hls';
    if (ext === 'mpd') return 'dash';
    if (['mp4', 'webm', 'm4a', 'mp3', 'flac', 'ogg', 'wav', 'opus', 'mov', 'mkv'].includes(ext)) return 'file';
    return null;
  }

  function randomId() {
    const crypto_ = root.crypto;
    if (crypto_ && crypto_.getRandomValues) {
      const bytes = new Uint8Array(16);
      crypto_.getRandomValues(bytes);
      return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
    }
    return 'id-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  /** Flat envelope matching the app's HDMIPC decoder. */
  function makeMessage(type, extra) {
    return Object.assign({ v: 1, id: randomId(), type }, extra || {});
  }

  const STRINGS = {
    en: {
      downloadWithHDM: 'Download with MacDM',
      downloadAllWithHDM: 'Download all links with MacDM',
      downloadThisVideo: 'Download this video',
      gettingQualities: 'Getting qualities…',
      audioOnly: 'Audio only',
      drmProtected: 'This video is DRM protected and cannot be downloaded.',
      addedToDownloads: 'Added to downloads',
      failed: 'Failed',
      captureOn: 'Capture browser downloads',
      connected: 'MacDM is running',
      disconnected: 'MacDM is not running',
      openHDM: 'Open MacDM',
      excludeSite: "Don't capture from this site",
      excluded: 'Site excluded',
      mediaOnTab: 'Media on this tab',
      noMedia: 'No media found on this tab',
    },
    tr: {
      downloadWithHDM: 'MacDM ile indir',
      downloadAllWithHDM: 'Tüm linkleri MacDM ile indir',
      downloadThisVideo: 'Bu videoyu indir',
      gettingQualities: 'Kaliteler alınıyor…',
      audioOnly: 'Sadece ses',
      drmProtected: 'Bu video DRM ile korunuyor, indirilemez.',
      addedToDownloads: 'İndirmelere eklendi',
      failed: 'Başarısız',
      captureOn: 'Tarayıcı indirmelerini yakala',
      connected: 'MacDM çalışıyor',
      disconnected: 'MacDM çalışmıyor',
      openHDM: "MacDM'yi aç",
      excludeSite: 'Bu siteyi yakalama',
      excluded: 'Site istisnalara eklendi',
      mediaOnTab: 'Bu sekmedeki medyalar',
      noMedia: 'Bu sekmede medya bulunamadı',
    },
  };

  function locale() {
    const language = (root.navigator && root.navigator.language) || 'en';
    return String(language).toLowerCase().startsWith('tr') ? 'tr' : 'en';
  }

  function t(key) {
    const language = locale();
    return (STRINGS[language] && STRINGS[language][key]) || STRINGS.en[key] || key;
  }

  root.HDM = {
    EXTENSION_VERSION, NATIVE_HOST, DEFAULT_SETTINGS,
    isHttpUrl, hostOf, pathOf, extensionOf, extensionFromMime,
    matchesException, shouldCapture, classifyMediaUrl,
    makeMessage, randomId, t, locale,
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
