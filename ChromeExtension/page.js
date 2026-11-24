// Runs in the page's own JavaScript world ("world": "MAIN") so it can see the
// site's Media Session info and handlers. Talks to content.js via window.postMessage.
// It may also be injected late, into tabs that were already open when the extension
// was installed or reloaded, so it has to cope with media that's already playing.
(() => {
  // Old copies of this script keep running in tabs that were open while the extension
  // was updated. The message tag carries the version, so an old copy can neither hear
  // commands meant for this one nor have its reports relayed. Bump VERSION (here and in
  // content.js) whenever the two scripts change together.
  const VERSION = 4;
  const TAG = `__notchNowPlaying:v${VERSION}`;
  if ((window.__notchNowPlayingVersion || 0) >= VERSION) return; // this or a newer copy is running
  window.__notchNowPlayingVersion = VERSION;

  // Kept on the page so a future version injected later still knows the handlers the site
  // registered before it arrived (a late copy can't see those any other way).
  const KEEPALIVE_MS = 4000; // re-send while media is around: wakes the worker, re-syncs the playhead
  const MEDIA_EVENTS = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata',
    'durationchange', 'ratechange', 'seeked', 'volumechange'];
  const session = navigator.mediaSession;
  const shared = window.__notchShared || (window.__notchShared = { handlers: new Map(), position: null });
  const handlers = shared.handlers; // action -> the site's own handler
  // shared.position: last setPositionState(): { duration, position, rate, at, playing }
  let seenMedia = false;
  let lastKey = '';
  let lastSent = null;        // playhead as last reported: { position, rate, isPlaying, at }
  let lastSentAt = 0;
  let lastCommand = '';
  let pending = 0;

  if (session && typeof session.setActionHandler === 'function') {
    // Remember the site's play/pause/next/previous/seek handlers so the notch can call them.
    const originalSetAction = session.setActionHandler.bind(session);
    session.setActionHandler = (action, handler) => {
      if (typeof handler === 'function') handlers.set(action, handler);
      else handlers.delete(action);
      seenMedia = true;
      schedule();
      return originalSetAction(action, handler);
    };
    // Sites report duration and playhead here; keep the latest.
    if (typeof session.setPositionState === 'function') {
      const originalSetPosition = session.setPositionState.bind(session);
      session.setPositionState = (state) => {
        const result = originalSetPosition(state); // throws on bad input, like the original
        shared.position = state && Number.isFinite(state.duration) && state.duration > 0
          ? { duration: state.duration, position: state.position || 0, rate: state.playbackRate || 1,
              at: performance.now(), playing: isPlayingNow(mediaElement()) }
          : null; // no argument clears it
        seenMedia = true;
        schedule();
        return result;
      };
    }
    watch('metadata');
    watch('playbackState');
  }

  // Report whenever the site changes metadata or playback state.
  function watch(key) {
    const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(session), key);
    if (!desc || !desc.get || !desc.set) return;
    Object.defineProperty(session, key, {
      configurable: true,
      enumerable: true,
      get() { return desc.get.call(session); },
      set(value) { desc.set.call(session, value); seenMedia = true; schedule(); },
    });
  }

  const onMediaEvent = () => { seenMedia = true; schedule(); };

  // Media events don't bubble, but they do pass through document while capturing.
  for (const type of MEDIA_EVENTS) document.addEventListener(type, onMediaEvent, true);

  // Some players play through an element that's never added to the page (new Audio()),
  // which neither querySelectorAll nor document listeners can see. Remember every element
  // that starts playing (weakly, so they can still be garbage-collected).
  let detached = [];
  const known = new WeakSet();
  const originalPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    if (!known.has(this)) {
      known.add(this);
      detached.push(new WeakRef(this));
      for (const type of MEDIA_EVENTS) this.addEventListener(type, onMediaEvent);
    }
    onMediaEvent();
    return originalPlay.apply(this, args);
  };

  function mediaElement() {
    detached = detached.filter((ref) => ref.deref());
    const offPage = detached.map((ref) => ref.deref()).filter((el) => el && !el.isConnected);
    const all = [...document.querySelectorAll('video, audio'), ...offPage];
    const audible = (el) => !el.paused && !el.ended && hasAudio(el);
    return all.find(audible) || all.find((el) => !el.paused && !el.ended) || all.find((el) => el.currentTime > 0) || null;
  }

  function bestArtwork(meta) {
    const list = meta && meta.artwork ? [...meta.artwork] : [];
    if (!list.length) return '';
    const area = (img) => { const m = /(\d+)x(\d+)/.exec(img.sizes || ''); return m ? m[1] * m[2] : 0; };
    list.sort((a, b) => area(b) - area(a));
    try { return new URL(list[0].src, location.href).href; } catch { return ''; }
  }

  // The site's own player buttons, found by their accessibility label. Used when we never
  // saw its Media Session handlers (this script arrived after the site set them up).
  // Exact names only (with an optional shortcut hint like "Next (SHIFT+n)"), so links such
  // as "Next page" or buttons such as "Play all" never match.
  const CONTROL_LABELS = {
    nexttrack: /^(skip (to )?)?next( (track|song|video|episode))?( \(.*\))?$/i,
    previoustrack: /^(skip (to )?)?prev(ious)?( (track|song|video|episode))?( \(.*\))?$/i,
    play: /^(play|resume)( \(.*\))?$/i,
    pause: /^pause( \(.*\))?$/i,
  };
  let controls = { at: -Infinity, found: {} };

  function findControl(action) {
    const now = performance.now();
    if (now - controls.at > 3000) {           // re-scan at most every few seconds
      const found = {};
      for (const el of document.querySelectorAll('button, [role="button"], [aria-label]')) {
        const label = (el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
        if (!label || el.disabled || el.getAttribute('aria-disabled') === 'true') continue;
        for (const [name, pattern] of Object.entries(CONTROL_LABELS)) {
          if (!found[name] && pattern.test(label) && el.getClientRects().length) found[name] = el;
        }
      }
      controls = { at: now, found };
    }
    const el = controls.found[action];
    return el && el.isConnected ? el : null;
  }

  function isPlayingNow(el) {
    const declared = session ? session.playbackState : 'none';
    return declared === 'playing' || (declared !== 'paused' && !!el && !el.paused && !el.ended);
  }

  // Duration and playhead: from setPositionState() if the site uses it, else the element.
  // The site's position only advances while playing, so re-anchor it whenever play/pause
  // flips (sites often report it once while paused and not again when playback starts).
  function timing(el, isPlaying) {
    if (shared.position) {
      const ps = shared.position;
      const now = performance.now();
      const position = Math.min(ps.duration, ps.position + (ps.playing ? ((now - ps.at) / 1000) * ps.rate : 0));
      if (ps.playing !== isPlaying) shared.position = { ...ps, position, at: now, playing: isPlaying };
      return { duration: ps.duration, position, rate: ps.rate };
    }
    if (el && Number.isFinite(el.duration) && el.duration > 0) {
      return { duration: el.duration, position: el.currentTime, rate: el.playbackRate || 1 };
    }
    return { duration: 0, position: 0, rate: 1 }; // unknown, or a live stream
  }

  // Unmuted isn't the same as audible: a looping wallpaper or product preview can play
  // unmuted with no audio track at all. Chrome counts the audio it has decoded (none after
  // a second and a half of playing means silent); Firefox says so directly.
  function hasAudio(el) {
    if (!el || el.muted || el.volume === 0) return false;
    if (el.tagName === 'AUDIO') return true;
    if (typeof el.mozHasAudio === 'boolean') return el.mozHasAudio;
    if (typeof el.webkitAudioDecodedByteCount === 'number') {
      return el.webkitAudioDecodedByteCount > 0 || el.currentTime < 1.5;
    }
    return true;
  }

  function snapshot() {
    const meta = session ? session.metadata : null;
    const el = mediaElement();
    if (!meta && !hasAudio(el)) return null; // muted or silent autoplay videos don't count
    const isPlaying = isPlayingNow(el);
    const t = timing(el, isPlaying);
    return {
      title: (meta && meta.title) || document.title,
      artist: (meta && meta.artist) || '',
      artwork: bestArtwork(meta),
      isPlaying,
      canSkip: handlers.has('nexttrack') || handlers.has('previoustrack')
        || !!findControl('nexttrack') || !!findControl('previoustrack'),
      canSeek: t.duration > 0 && (handlers.has('seekto') || !!el),
      duration: t.duration,
      position: t.position,
      rate: t.rate,
    };
  }

  function schedule() {
    clearTimeout(pending);
    pending = setTimeout(() => report(false), 150);
  }

  // Send when something visible changed, when the playhead jumped (seek) or drifted,
  // and every few seconds while there's media (keepalive). Not on every tick.
  function report(force) {
    const state = snapshot();
    const now = performance.now();
    const key = state
      ? JSON.stringify([state.title, state.artist, state.artwork, state.isPlaying, state.canSkip,
        state.canSeek, Math.round(state.duration), state.rate])
      : 'null';
    let due = force || key !== lastKey;
    if (!due && state && lastSent) {
      const expected = lastSent.position + (lastSent.isPlaying ? ((now - lastSent.at) / 1000) * lastSent.rate : 0);
      due = Math.abs(state.position - expected) > 1.5 || now - lastSentAt > KEEPALIVE_MS;
    }
    if (!due) return;
    lastKey = key;
    lastSent = state && { position: state.position, rate: state.rate, isPlaying: state.isPlaying, at: now };
    lastSentAt = now;
    window.postMessage({ [TAG]: 'state', state }, '*');
  }

  setInterval(() => { if (seenMedia) report(false); }, 2000);

  function run(action, seekTime) {
    const el = mediaElement();
    if (action === 'seekto') {
      if (typeof seekTime !== 'number' || !Number.isFinite(seekTime) || seekTime < 0) return;
      const handler = handlers.get('seekto');
      if (handler) {
        try { handler({ action: 'seekto', seekTime, fastSeek: false }); } catch { /* the site's handler threw */ }
      } else if (el) {
        el.currentTime = seekTime;
      }
      if (shared.position) shared.position = { ...shared.position, position: seekTime, at: performance.now(), playing: isPlayingNow(el) };
    } else {
      const handler = handlers.get(action);
      if (handler) {
        try { handler({ action }); } catch { /* the site's handler threw */ }
      } else if (el && action === 'play') {
        el.play().catch(() => {});
      } else if (el && action === 'pause') {
        el.pause();
      } else {
        const button = findControl(action); // the site's own next/previous/play/pause button
        if (button) button.click();
      }
    }
    schedule();
  }

  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data) return;
    const kind = event.data[TAG];
    if (kind === 'command') {
      // If an old and a new copy of content.js both relay a command, run it once.
      if (event.data.id && event.data.id === lastCommand) return;
      lastCommand = event.data.id || '';
      run(event.data.action, event.data.seekTime);
    }
    if (kind === 'report' && seenMedia) report(true);
  });

  // Injected into a tab that's already playing? Report straight away.
  if ((session && session.metadata) || document.querySelector('video, audio')) {
    seenMedia = true;
    report(true);
  }
})();
