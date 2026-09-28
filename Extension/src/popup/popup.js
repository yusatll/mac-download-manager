'use strict';
/* Popup (spec §7.3): capture toggle, connection state, per-site exception, tab media. */

const B = globalThis.browser && globalThis.browser.runtime ? globalThis.browser : globalThis.chrome;
const send = (message) => new Promise((resolve) => B.runtime.sendMessage(message, (reply) => resolve(reply || { ok: false })));

const statusEl = document.getElementById('status');
const captureEl = document.getElementById('capture');
const captureLabel = document.getElementById('capture-label');
const excludeBtn = document.getElementById('exclude');
const mediaSection = document.getElementById('media-section');
const mediaTitle = document.getElementById('media-title');
const mediaList = document.getElementById('media-list');

document.title = 'MacDM';
captureLabel.textContent = HDM.t('captureOn');
excludeBtn.textContent = HDM.t('excludeSite');
mediaTitle.textContent = HDM.t('mediaOnTab');

// Connection state (spec §7.1 ping).
send({ type: 'native', message: HDM.makeMessage('ping') }).then((reply) => {
  const connected = Boolean(reply && reply.ok);
  statusEl.textContent = connected ? HDM.t('connected') : HDM.t('disconnected');
  statusEl.classList.toggle('off', !connected);
});

// Capture toggle reflects the background's cached settings.
send({ type: 'getSettings' }).then((reply) => {
  if (reply && reply.settings) captureEl.checked = reply.settings.captureEnabled !== false;
});
captureEl.addEventListener('change', () => send({ type: 'setCapture', enabled: captureEl.checked }));

// Per-site exception for the active tab.
B.tabs && B.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
  const host = tabs[0] && tabs[0].url ? HDM.hostOf(tabs[0].url) : '';
  if (!host) { excludeBtn.hidden = true; return; }
  excludeBtn.addEventListener('click', async () => {
    await send({ type: 'excludeSite', pattern: '*.' + host.split('.').slice(-2).join('.') });
    excludeBtn.textContent = HDM.t('excluded');
    excludeBtn.disabled = true;
  });
});

// Media found on the current tab (spec §8.2 popup list).
async function loadMedia() {
  const tabs = await (B.tabs ? B.tabs.query({ active: true, currentWindow: true }) : Promise.resolve([]));
  const tabId = tabs[0] && tabs[0].id;
  const reply = await send({ type: 'getTabMedia', tabId });
  if (!reply || !reply.ok || !reply.media.length) return;
  mediaSection.hidden = false;
  for (const item of reply.media) {
    const row = document.createElement('div');
    row.className = 'media-row';
    const name = document.createElement('span');
    name.textContent = decodeURIComponent(item.url.split('/').pop() || item.url).slice(0, 40);
    const meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = item.kind.toUpperCase();
    row.append(name, meta);
    row.addEventListener('click', async () => {
      row.innerHTML = '<span class="meta">' + HDM.t('gettingQualities') + '</span>';
      const query = await send({ type: 'native', message: HDM.makeMessage('mediaQuery', {
        pageUrl: (tabs[0] && tabs[0].url) || 'https://example.com',
        title: (tabs[0] && tabs[0].title) || '',
        streams: [{ url: item.url, kind: item.kind }],
      }) });
      const formats = query && query.ok && query.mediaQuery ? query.mediaQuery.formats : [];
      if (!formats.length) {
        row.innerHTML = '<span class="meta">' + ((query && query.error) || HDM.t('failed')) + '</span>';
        return;
      }
      row.innerHTML = '';
      for (const format of formats) {
        const option = document.createElement('div');
        option.className = 'media-row';
        const label = document.createElement('span');
        label.textContent = format.label;
        const size = document.createElement('span');
        size.className = 'meta';
        size.textContent = format.ext + (format.approxSize ? ' · ~' + humanSize(format.approxSize) : '');
        option.append(label, size);
        option.addEventListener('click', async (event) => {
          event.stopPropagation();
          size.textContent = '…';
          const download = await send({ type: 'native', message: HDM.makeMessage('mediaDownload', {
            queryId: query.mediaQuery.queryId, formatId: format.id,
          }) });
          size.textContent = download && download.ok ? HDM.t('addedToDownloads') : HDM.t('failed');
        });
        row.append(option);
      }
    });
    mediaList.append(row);
  }
}
loadMedia();

function humanSize(bytes) {
  if (bytes >= 1 << 30) return (bytes / (1 << 30)).toFixed(1) + ' GB';
  if (bytes >= 1 << 20) return (bytes / (1 << 20)).toFixed(0) + ' MB';
  if (bytes >= 1 << 10) return (bytes / (1 << 10)).toFixed(0) + ' KB';
  return bytes + ' B';
}
