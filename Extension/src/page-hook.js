'use strict';
/*
 * Injected into the page's MAIN world (script tag from the content script). Wraps
 * requestMediaKeySystemAccess so DRM playback (Widevine/FairPlay/PlayReady) can be
 * reported (spec §8.1). Never touches the page otherwise.
 */
(function () {
  if (window.__MACDM_PAGE_HOOK__) return;
  window.__MACDM_PAGE_HOOK__ = true;
  const original = Navigator.prototype.requestMediaKeySystemAccess;
  if (typeof original !== 'function') return;
  Navigator.prototype.requestMediaKeySystemAccess = function (keySystem) {
    try { window.postMessage({ __MACDM_DRM__: true, keySystem }, '*'); } catch { }
    return original.apply(this, arguments);
  };
})();
