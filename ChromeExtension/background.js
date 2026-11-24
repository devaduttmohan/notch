// Tracks what each tab is playing and sends the most relevant one to the Notch app
// over a local WebSocket. The app only accepts connections from Chrome extensions.
const ENDPOINT = 'ws://127.0.0.1:47821'; // must match BrowserBridge.port
const PING_MS = 20_000;                  // WebSocket traffic keeps this service worker alive
const RETRY_MAX_MS = 5_000;              // how often to look for the app while it isn't running
const ACTIONS = ['play', 'pause', 'nexttrack', 'previoustrack', 'seekto'];
const SITE_NAMES = {
  'youtube.com': 'YouTube',
  'm.youtube.com': 'YouTube',
  'music.youtube.com': 'YouTube Music',
  'open.spotify.com': 'Spotify',
  'music.apple.com': 'Apple Music',
  'soundcloud.com': 'SoundCloud',
  'twitch.tv': 'Twitch',
  'netflix.com': 'Netflix',
};

const tabs = new Map(); // tabId -> { state, site, updatedAt }
let socket = null;
let lastSent = '';
let pinger = 0;
let retryDelay = 1000;
let nextAttempt = 0;
let commandCount = 0;

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return; // connecting or open
  if (Date.now() < nextAttempt) return;                       // backing off: the app isn't running
  try {
    socket = new WebSocket(ENDPOINT);
  } catch {
    socket = null;
    return;
  }
  socket.onopen = () => { retryDelay = 1000; lastSent = ''; publish(); };
  socket.onmessage = (event) => onAppMessage(event.data);
  socket.onclose = () => {
    socket = null;
    nextAttempt = Date.now() + retryDelay;
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
  };
  socket.onerror = () => {}; // the app isn't running; pages' keepalives bring us back here
}

function onAppMessage(text) {
  let message;
  try { message = JSON.parse(text); } catch { return; }
  if (message.type !== 'command' || !Number.isInteger(message.tabId) || !ACTIONS.includes(message.action)) return;
  const command = { type: 'command', action: message.action, id: `${Date.now()}-${++commandCount}` };
  if (message.action === 'seekto') {
    if (typeof message.seekTime !== 'number' || !Number.isFinite(message.seekTime) || message.seekTime < 0) return;
    command.seekTime = message.seekTime;
  }
  chrome.tabs.sendMessage(message.tabId, command).catch(() => {});
}

// Playing beats paused; within each, the most recently updated tab wins.
function current() {
  let best = null;
  for (const [tabId, entry] of tabs) {
    const rank = entry.state.isPlaying ? 1 : 0;
    if (!best || rank > best.rank || (rank === best.rank && entry.updatedAt > best.updatedAt)) {
      best = { tabId, rank, ...entry };
    }
  }
  return best;
}

function publish() {
  const best = current();
  setPinger(Boolean(best));
  if (!socket || socket.readyState !== WebSocket.OPEN) { connect(); return; }
  const message = best
    ? { type: 'nowPlaying', tabId: best.tabId, site: best.site, ...best.state }
    : { type: 'cleared' };
  const text = JSON.stringify(message);
  if (text === lastSent) return;
  socket.send(text);
  lastSent = text;
}

function setPinger(on) {
  if (on && !pinger) {
    pinger = setInterval(() => {
      if (socket && socket.readyState === WebSocket.OPEN) socket.send('{"type":"ping"}');
      else connect();
    }, PING_MS);
  } else if (!on && pinger) {
    clearInterval(pinger);
    pinger = 0;
  }
}

// Pages can post anything to content.js, so keep only well-formed, bounded fields.
function clean(state) {
  if (!state || typeof state !== 'object') return null;
  const text = (value, max = 200) => (typeof value === 'string' ? value.slice(0, max) : '');
  const num = (value, min, max, fallback) =>
    (typeof value === 'number' && Number.isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback);
  const artwork = text(state.artwork, 2000);
  const duration = num(state.duration, 0, 86_400, 0);
  return {
    title: text(state.title),
    artist: text(state.artist),
    artwork: artwork.startsWith('https://') ? artwork : '',
    kind: state.kind === 'video' ? 'video' : 'audio',
    isPlaying: state.isPlaying === true,
    canSkip: state.canSkip === true,
    canSeek: state.canSeek === true && duration > 0,
    duration,
    position: num(state.position, 0, duration, 0),
    rate: num(state.rate, 0, 16, 1),
  };
}

function siteName(url) {
  try {
    const host = new URL(url).hostname.replace(/^www\./, '');
    if (host.startsWith('music.amazon.')) return 'Amazon Music';
    return SITE_NAMES[host] || host;
  } catch {
    return 'Browser';
  }
}

chrome.runtime.onMessage.addListener((message, sender) => {
  const tabId = sender.tab && sender.tab.id;
  if (!message || message.type !== 'state' || tabId == null || sender.frameId !== 0) return;
  const state = clean(message.state);
  if (state) tabs.set(tabId, { state, site: siteName(sender.url), updatedAt: Date.now() });
  else tabs.delete(tabId);
  publish();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabs.delete(tabId)) publish();
});

// Tabs that were already open when the extension was installed or reloaded don't get
// the content scripts until they reload, so add them now: media that's already
// playing then shows up straight away.
chrome.runtime.onInstalled.addListener(async () => {
  const open = await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] });
  for (const tab of open) {
    const target = { tabId: tab.id };
    try {
      await chrome.scripting.executeScript({ target, files: ['content.js'] });
      await chrome.scripting.executeScript({ target, files: ['page.js'], world: 'MAIN' });
    } catch {
      // Pages extensions can't touch (the Web Store, some built-in pages): skip.
    }
  }
});

// The worker may have been restarted and lost its state: ask tabs with media to report again.
chrome.tabs.query({}).then((all) => {
  for (const tab of all) chrome.tabs.sendMessage(tab.id, { type: 'report' }).catch(() => {});
});
connect();
