// Relays between page.js (the page's world) and background.js (the extension).
// Runs in the extension's isolated world, which can use chrome.runtime. Wrapped in a
// function so it can be injected again after the extension reloads without clashing.
(() => {
  const VERSION = 4; // must match page.js: only that version's messages are relayed
  const TAG = `__notchNowPlaying:v${VERSION}`;
  let reported = false;

  function send(state) {
    try {
      chrome.runtime.sendMessage({ type: 'state', state }).catch(() => {});
    } catch {
      // Extension was reloaded; this old copy is orphaned.
    }
  }

  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data || event.data[TAG] !== 'state') return;
    if (event.data.state) reported = true;
    send(event.data.state);
  });

  // Leaving the page: tell the extension this tab has stopped (only if it ever reported).
  window.addEventListener('pagehide', () => { if (reported) send(null); });

  chrome.runtime.onMessage.addListener((message) => {
    if (message && (message.type === 'command' || message.type === 'report')) {
      window.postMessage({ [TAG]: message.type, action: message.action, seekTime: message.seekTime, id: message.id }, '*');
    }
  });

  // page.js may have been running since before this copy arrived: ask what's playing.
  window.postMessage({ [TAG]: 'report' }, '*');
})();
