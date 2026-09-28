'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

function loadHDM() {
  const context = { navigator: { language: 'en' }, URL, console, crypto: require('node:crypto').webcrypto };
  vm.createContext(context);
  vm.runInContext(readFileSync(join(__dirname, '../src/lib/hdm.js'), 'utf8'), context);
  return context.HDM;
}

test('shouldCapture applies every rule from the design (§7.3)', () => {
  const HDM = loadHDM();
  const settings = { ...HDM.DEFAULT_SETTINGS };

  assert.equal(HDM.shouldCapture({ url: 'https://e.com/setup.dmg' }, settings), true);
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/setup.DMG' }, settings), true);
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/page.html' }, settings), false, 'not in type list');
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/noext' }, settings), false, 'no extension');
  assert.equal(HDM.shouldCapture({ url: 'blob:https://e.com/x' }, settings), false, 'blob stays in browser');
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/file' , mime: 'application/pdf' }, settings), true, 'mime fallback');

  const disabled = { ...settings, captureEnabled: false };
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/setup.dmg' }, disabled), false);

  const excluded = { ...settings, exceptions: ['*.apple.com'] };
  assert.equal(HDM.shouldCapture({ url: 'https://swcdn.apple.com/x.pkg' }, excluded), false);
  assert.equal(HDM.shouldCapture({ url: 'https://apple.com/x.pkg' }, excluded), false);
  assert.equal(HDM.shouldCapture({ url: 'https://notapple.com/x.pkg' }, excluded), true);

  const local = { ...settings, localExceptions: ['cdn.e.com'] };
  assert.equal(HDM.shouldCapture({ url: 'https://cdn.e.com/x.zip' }, local), false);

  const minimum = { ...settings, minimumSizeBytes: 5 << 20 };
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/x.zip', size: 1 << 20 }, minimum), false);
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/x.zip', size: 9 << 20 }, minimum), true);
  assert.equal(HDM.shouldCapture({ url: 'https://e.com/x.zip', size: undefined }, minimum), true, 'unknown size still captured');
});

test('matchesException matches the Swift semantics', () => {
  const HDM = loadHDM();
  const patterns = ['*.apple.com', 'example.com', 'example.*', 'cdn-*.cdn.io'];
  assert.equal(HDM.matchesException('apple.com', patterns), true);
  assert.equal(HDM.matchesException('music.apple.com', patterns), true);
  assert.equal(HDM.matchesException('notapple.com', patterns), false);
  assert.equal(HDM.matchesException('example.com', patterns), true);
  assert.equal(HDM.matchesException('www.example.com', patterns), true);
  assert.equal(HDM.matchesException('badexample.com', patterns), false, 'suffix must respect labels');
  assert.equal(HDM.matchesException('example.org', patterns), true, 'example.* covers TLDs');
  assert.equal(HDM.matchesException('a.example.org', patterns), false, 'example.* does not cover subdomains');
  assert.equal(HDM.matchesException('cdn-1.cdn.io', patterns), true);
  assert.equal(HDM.matchesException('cdn-1.evil.io', patterns), false);
  assert.equal(HDM.matchesException('', patterns), false);
});

test('classifyMediaUrl sorts streams and drops fragments (§8.1)', () => {
  const HDM = loadHDM();
  assert.equal(HDM.classifyMediaUrl('https://e.com/live/master.m3u8?tok=1'), 'hls');
  assert.equal(HDM.classifyMediaUrl('https://e.com/v/manifest.mpd'), 'dash');
  assert.equal(HDM.classifyMediaUrl('https://e.com/clip.MP4'), 'file');
  assert.equal(HDM.classifyMediaUrl('https://e.com/audio.m4a'), 'file');
  assert.equal(HDM.classifyMediaUrl('https://e.com/seg-00042.ts'), null, 'fragment');
  assert.equal(HDM.classifyMediaUrl('https://e.com/chunk-1.m4s?x=1'), null, 'fragment');
  assert.equal(HDM.classifyMediaUrl('https://e.com/range/123-456'), null, 'range part');
  assert.equal(HDM.classifyMediaUrl('https://e.com/page'), null);
});

test('makeMessage produces the flat envelope the app decodes', () => {
  const HDM = loadHDM();
  const message = HDM.makeMessage('download', { url: 'https://e.com/a.zip', source: 'capture' });
  assert.equal(message.v, 1);
  assert.equal(message.type, 'download');
  assert.equal(message.url, 'https://e.com/a.zip');
  assert.equal(message.source, 'capture');
  assert.match(message.id, /^[0-9a-f]{32}$/);
  const other = HDM.makeMessage('ping');
  assert.notEqual(message.id, other.id);
});

test('i18n switches with the navigator language', () => {
  const source = readFileSync(join(__dirname, '../src/lib/hdm.js'), 'utf8');
  const context = { navigator: { language: 'tr-TR' }, URL, console, crypto: require('node:crypto').webcrypto };
  vm.createContext(context);
  vm.runInContext(source, context);
  assert.equal(context.HDM.t('downloadThisVideo'), 'Bu videoyu indir');

  const english = { navigator: { language: 'en-US' }, URL, console, crypto: require('node:crypto').webcrypto };
  vm.createContext(english);
  vm.runInContext(source, english);
  assert.equal(english.HDM.t('downloadThisVideo'), 'Download this video');
  assert.equal(english.HDM.t('nonexistent-key'), 'nonexistent-key');
});
