'use strict';
/*
 * Content script (all frames, spec §8.1/§8.2): reports media and DRM to the background,
 * shows the "⬇ Download this video" overlay, and intercepts plain link clicks in Safari
 * (which has no downloads API). lib/hdm.js is listed before this file in both manifests.
 */
(() => {
  if (window.__MACDM_CONTENT__) return;
  window.__MACDM_CONTENT__ = true;

  const B = globalThis.browser && globalThis.browser.runtime ? globalThis.browser : globalThis.chrome;
  const send = (message) => new Promise((resolve) => B.runtime.sendMessage(message, (reply) => resolve(reply || { ok: false })));
  const isTopFrame = window === window.top;

  let settings = Object.assign({}, HDM.DEFAULT_SETTINGS);
  send({ type: 'getSettings' }).then((reply) => {
    if (reply && reply.settings) settings = Object.assign({}, HDM.DEFAULT_SETTINGS, reply.settings);
  });

  // --- ⌥-click bypass (§7.3) --------------------------------------------------------
  document.addEventListener('click', (event) => {
    if (!event.altKey) return;
    const anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
    if (anchor) send({ type: 'altClick', url: anchor.href });
  }, true);

  // --- Safari: capture link clicks (§7.4) -------------------------------------------
  if (!B.downloads) {
    document.addEventListener('click', (event) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey
          || event.shiftKey || event.altKey) return;
      const anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
      if (!anchor || !/^https?:/i.test(anchor.protocol)) return;
      const name = decodeURIComponent(anchor.pathname.split('/').pop() || '');
      const captured = HDM.shouldCapture({ url: anchor.href, filename: name, hasDownloadAttribute: anchor.hasAttribute('download') }, settings)
        || (anchor.hasAttribute('download') && HDM.isHttpUrl(anchor.href));
      if (!captured) return;
      event.preventDefault();
      send({ type: 'native', message: HDM.makeMessage('download', {
        url: anchor.href,
        referrer: document.referrer || undefined,
        pageUrl: location.href,
        filename: name || undefined,
        userAgent: navigator.userAgent,
        source: 'click',
      }) }).then((reply) => {
        if (!reply || !reply.ok) window.location.href = anchor.href;   // fallback: open normally
      });
    }, true);
  }

  // --- Media detection (§8.1) --------------------------------------------------------

  const foundStreams = new Map();   // url → {url, kind, mime}
  let flushTimer = null;

  function rememberStream(url, mime) {
    if (!HDM.isHttpUrl(url) || url.startsWith('blob:')) return;
    if (!foundStreams.has(url)) {
      foundStreams.set(url, { url, mime: mime || '' });
      scheduleFlush();
    }
  }

  function scheduleFlush() {
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      const streams = Array.from(foundStreams.values()).filter((stream) => HDM.classifyMediaUrl(stream.url));
      if (streams.length) send({ type: 'mediaFound', streams });
    }, 1500);
  }

  function scanMediaElements() {
    for (const element of document.querySelectorAll('video, audio')) {
      if (element.currentSrc) rememberStream(element.currentSrc, '');
      for (const source of element.querySelectorAll('source')) {
        if (source.src) rememberStream(source.src, source.type);
      }
    }
  }

  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      if (entry.name) rememberStream(entry.name, '');
    }
  });
  try { observer.observe({ resource: true, buffered: true }); } catch { }
  scanMediaElements();
  setInterval(scanMediaElements, 5000);

  // --- DRM detection (§8.1): page-hook posts a window message -----------------------

  window.addEventListener('message', (event) => {
    if (event.source === window && event.data && event.data.__MACDM_DRM__) {
      send({ type: 'drmFound' });
      drmDetected = true;
    }
  });

  let drmDetected = false;
  try {
    const hook = document.createElement('script');
    hook.src = B.runtime.getURL('page-hook.js');
    hook.async = false;
    (document.head || document.documentElement).appendChild(hook);
    hook.remove();
  } catch { /* MAIN world injection unavailable */ }

  // --- The overlay (§8.2) — only on the top frame ------------------------------------

  if (!isTopFrame) return;

  const dismissed = new WeakSet();
  let host = null;      // shadow host over the video
  let panel = null;     // quality dropdown

  function pickVideo() {
    let best = null;
    for (const video of document.querySelectorAll('video')) {
      const rect = video.getBoundingClientRect();
      if (rect.width < 200 || rect.height < 120) continue;
      if (dismissed.has(video)) continue;
      const playing = !video.paused && !video.ended;
      const hovered = rect.top <= event_lastY && event_lastY <= rect.bottom && rect.left <= event_lastX && event_lastX <= rect.right;
      const score = (playing ? 1e6 : 0) + (hovered ? 1e5 : 0) + rect.width * rect.height;
      if (!best || score > best.score) best = { video, rect, score };
    }
    return best;
  }

  let event_lastX = -1, event_lastY = -1;
  window.addEventListener('mousemove', (event) => { event_lastX = event.clientX; event_lastY = event.clientY; }, { passive: true });

  const CSS = `
    .hdm-btn {
      position: absolute; display: flex; align-items: center; gap: 6px;
      background: rgba(28, 28, 30, 0.92); color: #fff;
      font: 13px -apple-system, system-ui, sans-serif; font-weight: 600;
      border: none; border-radius: 8px; padding: 8px 12px; cursor: pointer;
      box-shadow: 0 2px 12px rgba(0,0,0,.35); z-index: 2147483646;
    }
    .hdm-btn:hover { background: rgba(60, 60, 67, 0.95); }
    .hdm-close {
      position: absolute; background: rgba(28,28,30,.92); color: #fff; border: none;
      width: 22px; height: 22px; border-radius: 11px; cursor: pointer; font: 13px system-ui;
      display: flex; align-items: center; justify-content: center; z-index: 2147483646;
    }
    .hdm-panel {
      position: absolute; min-width: 240px; max-width: 360px;
      background: rgba(28,28,30,.97); color: #fff; border-radius: 10px; padding: 6px;
      font: 13px -apple-system, system-ui, sans-serif;
      box-shadow: 0 8px 28px rgba(0,0,0,.45); z-index: 2147483647;
    }
    .hdm-panel .row { padding: 8px 10px; border-radius: 7px; cursor: pointer; display: flex; gap: 8px; justify-content: space-between; }
    .hdm-panel .row:hover { background: rgba(10,132,255,.75); }
    .hdm-panel .note { color: rgba(235,235,245,.65); font-weight: 400; }
    .hdm-panel .status { padding: 10px; color: rgba(235,235,245,.8); }
  `;

  function ensureHost() {
    if (host) return host;
    host = document.createElement('div');
    host.style.cssText = 'position:absolute;top:0;left:0;width:0;height:0;z-index:2147483645;';
    const shadow = host.attachShadow({ mode: 'closed' });
    const style = document.createElement('style');
    style.textContent = CSS;
    const box = document.createElement('div');
    shadow.append(style, box);
    host.__box = box;
    document.documentElement.appendChild(host);
    return host;
  }

  function placeOver(element, rect) {
    const x = rect.left + window.scrollX;
    const y = rect.top + window.scrollY;
    element.style.left = `${x + rect.width - element.offsetWidth - 14}px`;
    element.style.top = `${y + 10}px`;
  }

  async function showPanel(anchorButton) {
    if (panel) { panel.remove(); panel = null; }
    panel = document.createElement('div');
    panel.className = 'hdm-panel';
    const shadowBox = ensureHost().__box;
    panel.style.position = 'absolute';
    shadowBox.append(panel);
    panel.innerHTML = `<div class="status">${HDM.t('gettingQualities')}</div>`;
    placeOver(panel, anchorButton.getBoundingClientRect());

    if (drmDetected) {
      panel.innerHTML = `<div class="status">${HDM.t('drmProtected')}</div>`;
      return;
    }
    const reply = await send({ type: 'native', message: HDM.makeMessage('mediaQuery', {
      pageUrl: location.href,
      title: document.title || '',
      streams: Array.from(foundStreams.values()),
      referrer: document.referrer || location.href,
      userAgent: navigator.userAgent,
    }) });
    if (!panel.isConnected) return;
    if (!reply || !reply.ok || !reply.mediaQuery || !reply.mediaQuery.formats.length) {
      panel.innerHTML = `<div class="status">${(reply && reply.error) || HDM.t('failed')}</div>`;
      return;
    }
    const query = reply.mediaQuery;
    panel.innerHTML = '';
    for (const format of query.formats) {
      const row = document.createElement('div');
      row.className = 'row';
      const label = document.createElement('span');
      label.textContent = format.id === 'Audio only' || /audio/i.test(format.id) ? HDM.t('audioOnly') : format.label;
      const meta = document.createElement('span');
      meta.className = 'note';
      const size = format.approxSize ? ' · ~' + humanSize(format.approxSize) : '';
      meta.textContent = `${format.ext}${size}${format.note ? ' · ' + format.note : ''}`;
      row.append(label, meta);
      row.addEventListener('click', () => {
        panel.innerHTML = `<div class="status">${HDM.t('gettingQualities')}</div>`;
        send({ type: 'native', message: HDM.makeMessage('mediaDownload', {
          queryId: query.queryId, formatId: format.id,
        }) }).then((downloadReply) => {
          panel.innerHTML = `<div class="status">${downloadReply && downloadReply.ok ? HDM.t('addedToDownloads') : HDM.t('failed')}</div>`;
          setTimeout(() => { if (panel) { panel.remove(); panel = null; } }, 1600);
        });
      });
      panel.append(row);
    }
  }

  function humanSize(bytes) {
    if (bytes >= 1 << 30) return (bytes / (1 << 30)).toFixed(1) + ' GB';
    if (bytes >= 1 << 20) return (bytes / (1 << 20)).toFixed(0) + ' MB';
    if (bytes >= 1 << 10) return (bytes / (1 << 10)).toFixed(0) + ' KB';
    return bytes + ' B';
  }

  function tick() {
    if (!settings.panelEnabled) {
      if (host) { host.__box.innerHTML = ''; }
      return;
    }
    const picked = pickVideo();
    const shadowBox = picked ? ensureHost().__box : null;
    const existingButton = shadowBox && shadowBox.querySelector('.hdm-btn');
    const existingClose = shadowBox && shadowBox.querySelector('.hdm-close');
    if (!picked) {
      if (existingButton) existingButton.remove();
      if (existingClose) existingClose.remove();
      return;
    }
    if (!existingButton) {
      const button = document.createElement('button');
      button.className = 'hdm-btn';
      button.textContent = '⬇ ' + HDM.t('downloadThisVideo');
      button.addEventListener('click', (event) => {
        event.preventDefault(); event.stopPropagation();
        showPanel(button);
      });
      shadowBox.append(button);
      const close = document.createElement('button');
      close.className = 'hdm-close';
      close.textContent = '×';
      close.title = 'MacDM';
      close.addEventListener('click', (event) => {
        event.preventDefault(); event.stopPropagation();
        dismissed.add(picked.video);
        close.remove(); button.remove();
      });
      shadowBox.append(close);
    }
    const button = shadowBox.querySelector('.hdm-btn');
    const close = shadowBox.querySelector('.hdm-close');
    button.style.display = 'flex';
    close.style.display = 'flex';
    placeOver(button, picked.rect);
    placeOver(close, picked.rect);
    close.style.left = `${parseFloat(button.style.left) - 26}px`;
    close.style.top = button.style.top;
  }

  setInterval(tick, 800);
  window.addEventListener('scroll', () => tick(), { passive: true });
  window.addEventListener('resize', () => tick(), { passive: true });
})();
