// AirPoint controller.
//
// Structure:
//   Transport  — WebSocket, sequencing, ping/pong, reconnect, backpressure
//   Auth       — HMAC pairing proof over the server's challenge nonce
//   Sensors    — deviceorientation / devicemotion into the PointerPipeline
//   Gestures   — the pointer pad: clutch, tap, drag, scroll
//   UI         — four modes, haptics, toasts
//
// The motion maths lives in motion.js and mirrors the Swift reference implementation.

'use strict';

import {
  PointerPipeline,
  Calibrator,
  quatFromDeviceOrientation,
  quatConjugate,
  quatRotate,
  GyroAxisResolver,
  applyAxisCandidate,
} from '/motion.js';

const PROTOCOL_VERSION = 1;
// Bumped whenever the controller changes in a way that matters. The server compares this
// against its own version and says so when they differ: a phone holding a stale page in a
// backgrounded tab reconnects silently over WebSocket and looks perfectly healthy while
// running months-old code.
const CLIENT_VERSION = '0.1.5';
const SEND_HZ = 60;
const PING_INTERVAL_MS = 2000;
// Never let a queued motion delta accumulate: by the time a backed-up frame is delivered
// it describes a movement the user finished making some time ago.
const MAX_BUFFERED_BYTES = 32 * 1024;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const $ = (id) => document.getElementById(id);

function base64UrlToBytes(value) {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function bytesToBase64(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function haptic(pattern) {
  // Android honours this; iOS Safari ignores it. Treated as a bonus, never as feedback
  // the interface depends on — every action also has a visual response.
  if (navigator.vibrate) {
    try { navigator.vibrate(pattern); } catch { /* not supported */ }
  }
}

let toastTimer = null;
function toast(message) {
  const el = $('toast');
  el.textContent = message;
  el.classList.remove('is-hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('is-hidden'), 1800);
}

function showError(message) {
  const el = $('connect-error');
  el.textContent = message;
  el.classList.remove('is-hidden');
}

// A stable per-device identity, so a trusted device can be recognised across sessions.
// Hex-only, because the server validates the shape.
function deviceId() {
  let id = localStorage.getItem('airpoint.deviceId');
  if (!id || !/^[0-9a-f-]{1,64}$/.test(id)) {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    id = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    localStorage.setItem('airpoint.deviceId', id);
  }
  return id;
}

function deviceName() {
  const ua = navigator.userAgent;
  if (/iPad/.test(ua)) return 'iPad';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/Android/.test(ua)) return 'Android phone';
  return 'Browser';
}

// ---------------------------------------------------------------------------
// Pairing credentials
// ---------------------------------------------------------------------------

// The QR carries the secret in the URL fragment, which is never sent to the server and
// never appears in a request log. We read it once and clear it, so it does not linger in
// the address bar or in a screenshot the user shares.
function readPairingFragment() {
  const hash = location.hash.replace(/^#/, '');
  if (!hash) return null;
  const params = new URLSearchParams(hash);
  const secret = params.get('s');
  if (!secret) return null;
  history.replaceState(null, '', location.pathname);
  return { secretB64Url: secret, fingerprint: params.get('f') || '', code: params.get('c') || '' };
}

async function pairingProof(keyBytes, nonceBytes, id) {
  const key = await crypto.subtle.importKey(
    'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const message = new Uint8Array(nonceBytes.length + id.length);
  message.set(nonceBytes, 0);
  message.set(new TextEncoder().encode(id), nonceBytes.length);
  const signature = await crypto.subtle.sign('HMAC', key, message);
  return bytesToBase64(new Uint8Array(signature));
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

class Transport extends EventTarget {
  constructor() {
    super();
    this.socket = null;
    this.seq = 0;
    this.pingId = 0;
    this.pendingPings = new Map();
    this.latencyMs = null;
    this.reconnectDelay = 250;
    this.shouldReconnect = true;
    this.authenticated = false;
    this.pingTimer = null;
  }

  connect() {
    const url = `wss://${location.host}/`;
    try {
      this.socket = new WebSocket(url);
    } catch (error) {
      this.dispatchEvent(new CustomEvent('fatal', { detail: `Could not open a connection: ${error.message}` }));
      return;
    }
    this.socket.binaryType = 'arraybuffer';

    this.socket.onopen = () => {
      this.reconnectDelay = 250;
      this.dispatchEvent(new Event('open'));
    };
    this.socket.onmessage = (event) => this._receive(event.data);
    this.socket.onerror = () => {
      // The browser deliberately withholds the reason for a failed TLS handshake, so the
      // most likely cause has to be inferred and explained rather than reported.
      this.dispatchEvent(new Event('socketerror'));
    };
    this.socket.onclose = (event) => {
      this.authenticated = false;
      clearInterval(this.pingTimer);
      this.dispatchEvent(new CustomEvent('close', { detail: event }));
      if (this.shouldReconnect) this._scheduleReconnect();
    };
  }

  _scheduleReconnect() {
    setTimeout(() => {
      if (!this.shouldReconnect) return;
      this.connect();
    }, this.reconnectDelay);
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, 4000);
  }

  disconnect(reason = 'user_requested') {
    this.shouldReconnect = false;
    this.send('disconnect', { reason });
    clearInterval(this.pingTimer);
    if (this.socket && this.socket.readyState === WebSocket.OPEN) this.socket.close(1000);
  }

  get isOpen() {
    return this.socket && this.socket.readyState === WebSocket.OPEN;
  }

  get isCongested() {
    return this.isOpen && this.socket.bufferedAmount > MAX_BUFFERED_BYTES;
  }

  send(type, payload) {
    if (!this.isOpen) return false;
    this.seq = (this.seq + 1) >>> 0;
    const frame = { v: PROTOCOL_VERSION, t: type, seq: this.seq, ts: Date.now() };
    if (payload !== undefined) frame.d = payload;
    this.socket.send(JSON.stringify(frame));
    return true;
  }

  startPinging() {
    clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => {
      if (!this.isOpen) return;
      const id = ++this.pingId;
      this.pendingPings.set(id, performance.now());
      // Bound the map: a server that stops answering must not leak memory here.
      if (this.pendingPings.size > 32) {
        this.pendingPings.delete(this.pendingPings.keys().next().value);
      }
      this.send('ping', { id });
    }, PING_INTERVAL_MS);
  }

  _receive(raw) {
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (message.t === 'pong') {
      const sentAt = this.pendingPings.get(message.d?.id);
      if (sentAt !== undefined) {
        this.pendingPings.delete(message.d.id);
        this.latencyMs = Math.round(performance.now() - sentAt);
      }
      return;
    }
    if (message.t === 'welcome') this.authenticated = true;
    this.dispatchEvent(new CustomEvent('message', { detail: message }));
  }
}

// ---------------------------------------------------------------------------
// Sensors
// ---------------------------------------------------------------------------

class Sensors extends EventTarget {
  constructor() {
    super();
    this.attitude = null;
    this.rotationRate = null;
    this.accelerationG = null;
    this.lastSampleAt = 0;
    this.sampleCount = 0;
    this.rateSampleCount = 0;
    this.lastRateAt = 0;
    this.rawRate = null;
    this.started = false;
    this.permissionState = 'unknown';
    this._onOrientation = this._onOrientation.bind(this);
    this._onMotion = this._onMotion.bind(this);
  }

  static get needsPermission() {
    return typeof DeviceOrientationEvent !== 'undefined'
      && typeof DeviceOrientationEvent.requestPermission === 'function';
  }

  static get isAvailable() {
    return typeof DeviceOrientationEvent !== 'undefined';
  }

  // Must be called from a user gesture: iOS requires transient activation, and the whole
  // API is secure-context only, which is why this page is served over TLS.
  static async requestPermission() {
    if (!Sensors.needsPermission) return 'granted';
    try {
      const orientation = await DeviceOrientationEvent.requestPermission();
      // `devicemotion` is a separate grant from `deviceorientation` on iOS. Orientation
      // drives pointing; motion only supplies the stationary-bias estimator, so a refusal
      // here degrades drift correction rather than breaking the cursor.
      if (typeof DeviceMotionEvent !== 'undefined'
          && typeof DeviceMotionEvent.requestPermission === 'function') {
        try { await DeviceMotionEvent.requestPermission(); } catch { /* optional */ }
      }
      return orientation;
    } catch (error) {
      return 'denied';
    }
  }

  start() {
    if (this.started) return;   // guard: two code paths can reach here
    this.started = true;
    window.addEventListener('deviceorientation', this._onOrientation, { passive: true });
    window.addEventListener('devicemotion', this._onMotion, { passive: true });
  }

  stop() {
    this.started = false;
    window.removeEventListener('deviceorientation', this._onOrientation);
    window.removeEventListener('devicemotion', this._onMotion);
  }

  get isLive() {
    return performance.now() - this.lastSampleAt < 500;
  }

  _onOrientation(event) {
    if (event.alpha === null || event.beta === null || event.gamma === null) return;
    this.attitude = quatFromDeviceOrientation(event.alpha, event.beta, event.gamma);
    this.lastSampleAt = performance.now();
    this.sampleCount += 1;
    this.dispatchEvent(new Event('sample'));
  }

  _onMotion(event) {
    const rate = event.rotationRate;
    if (rate && rate.alpha !== null) {
      // rotationRate is in degrees/second, named by the axis each component turns about:
      // alpha about Z, beta about X, gamma about Y.
      // Stored as the raw [alpha, beta, gamma] triple, deliberately unmapped: which
      // component belongs to which device axis is a per-browser question that
      // GyroAxisResolver answers from measurement rather than from assumption.
      const toRad = Math.PI / 180;
      this.rawRate = [
        (rate.alpha || 0) * toRad,
        (rate.beta || 0) * toRad,
        (rate.gamma || 0) * toRad,
      ];
      this.rateSampleCount += 1;
      this.lastRateAt = performance.now();
    }
    const accel = event.accelerationIncludingGravity;
    if (accel && accel.x !== null) {
      const g = 9.80665;
      this.accelerationG = { x: (accel.x || 0) / g, y: (accel.y || 0) / g, z: (accel.z || 0) / g };
    }
  }

  // World "down" expressed in device coordinates.
  //
  // Derived from the orientation quaternion rather than from accelerationIncludingGravity,
  // for two reasons: the accelerometer reading is polluted by hand movement, and browsers
  // disagree about its sign (the W3C convention and Safari's have historically differed).
  // Gravity's direction depends only on beta and gamma, never on alpha, so this stays
  // completely free of the magnetometer.
  get gravityDown() {
    if (!this.attitude) return null;
    return quatRotate(quatConjugate(this.attitude), { x: 0, y: 0, z: -1 });
  }

  get hasRateStream() {
    return this.rawRate !== null && performance.now() - this.lastRateAt < 500;
  }
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

class App {
  constructor() {
    this.transport = new Transport();
    this.sensors = new Sensors();
    this.pipeline = new PointerPipeline();
    this.calibrator = new Calibrator();
    this.credentials = readPairingFragment();
    this.calibrating = false;
    this.sensorsAttached = false;
    // When locked, motion runs continuously instead of only while the pad is held.
    this.aimLocked = localStorage.getItem('airpoint.aimLocked') === 'yes';
    this.sendTimer = null;
    this.diagTimer = null;
    this.sentFrames = 0;
    this.lastSentDelta = { dx: 0, dy: 0 };
    this.usingRatePath = false;
    this.lastSensorReportAt = 0;
    this.axes = new GyroAxisResolver();
    this.previousGravity = null;
    this.lastGravityAt = null;

    this.pipeline.setActive(false);
    this._restoreSensitivity();
    this._wireTransport();
    this._wireUI();
  }

  start() {
    if (!Sensors.isAvailable) {
      showError('This browser does not expose motion sensors. Buttons, keyboard and media '
        + 'controls will still work, but pointing will not.');
    }
    this.transport.connect();
  }

  // --- Transport ---------------------------------------------------------

  _wireTransport() {
    this.transport.addEventListener('open', () => this._onOpen());
    this.transport.addEventListener('message', (event) => this._onMessage(event.detail));
    this.transport.addEventListener('close', () => this._onClose());
    this.transport.addEventListener('socketerror', () => {
      // A WebSocket failure at this point is almost always the untrusted certificate,
      // because Safari cannot show an interstitial for a wss:// connection.
      showError('Could not reach your Mac. If you have not accepted this Mac\'s certificate '
        + 'yet, reload this page and choose "visit this website" when Safari warns you. '
        + 'Otherwise, check that both devices are on the same Wi-Fi network.');
    });
    this.transport.addEventListener('fatal', (event) => showError(event.detail));
  }

  _onOpen() {
    $('connect-status').textContent = 'Authenticating…';
    this.transport.startPinging();
  }

  _onClose() {
    this._setLink('down', 'Reconnecting…');
  }

  async _onMessage(message) {
    switch (message.t) {
      case 'challenge':
        await this._authenticate(message.d.nonce);
        break;

      case 'pair_pending':
        $('connect-status').textContent = message.d.message || 'Approve on your Mac…';
        break;

      case 'welcome':
        this._onWelcome(message.d);
        break;

      case 'status':
        this._setLink(message.d.accessibility ? 'ok' : 'degraded',
          message.d.accessibility ? 'Connected' : 'Needs permission');
        break;

      case 'error':
        this._onError(message.d);
        break;
    }
  }

  async _authenticate(nonceB64Url) {
    const nonce = base64UrlToBytes(nonceB64Url);
    const id = deviceId();

    let keyBytes;
    let channel;
    if (this.credentials?.secretB64Url) {
      keyBytes = base64UrlToBytes(this.credentials.secretB64Url);
      channel = 'qr';
    } else if (this.typedCode) {
      keyBytes = new TextEncoder().encode(this.typedCode);
      channel = 'typed';
    } else {
      // No credential yet: ask for the six digits.
      $('connect-status').textContent = 'Pair this phone with your Mac';
      $('code-entry').classList.remove('is-hidden');
      return;
    }

    const proof = await pairingProof(keyBytes, nonce, id);
    this.transport.send('hello', {
      deviceId: id,
      deviceName: deviceName(),
      platform: 'web',
      clientVersion: CLIENT_VERSION,
      auth: { mode: 'code', proof, channel },
    });
  }

  _onWelcome(welcome) {
    $('screen-connect').classList.remove('is-visible');
    $('screen-remote').classList.add('is-visible');
    this._setLink(welcome.permissions?.accessibility ? 'ok' : 'degraded',
      welcome.permissions?.accessibility ? 'Connected' : 'Needs permission');

    if (welcome.permissions && welcome.permissions.accessibility === false) {
      toast('Grant Accessibility permission on the Mac');
    }
    this._startSendLoop();
    this._startDiagnostics();
    this._ensureMotion();
  }

  _onError(payload) {
    if (payload.code === 'rate_limited') return;   // expected under load; not user-facing

    if (payload.fatal) {
      this.transport.shouldReconnect = false;
      $('screen-remote').classList.remove('is-visible');
      $('screen-connect').classList.add('is-visible');
      $('connect-status').textContent = 'Not connected';
      if (payload.code === 'pair_rejected' || payload.code === 'too_many_attempts') {
        this.credentials = null;
        this.typedCode = null;
        $('code-entry').classList.remove('is-hidden');
      }
      showError(payload.message);
    } else {
      toast(payload.message);
    }
  }

  _setLink(state, text) {
    const dot = $('link-dot');
    dot.classList.toggle('is-degraded', state === 'degraded');
    dot.classList.toggle('is-down', state === 'down');
    $('link-text').textContent = text;
  }

  // --- Motion ------------------------------------------------------------

  async _ensureMotion() {
    if (!Sensors.isAvailable) return;
    if (Sensors.needsPermission && localStorage.getItem('airpoint.motionGranted') !== 'yes') {
      // Cannot prompt without a user gesture, so surface a button instead of failing quietly.
      $('screen-remote').classList.remove('is-visible');
      $('screen-connect').classList.add('is-visible');
      $('connect-status').textContent = 'Almost there';
      $('code-entry').classList.add('is-hidden');
      $('motion-gate').classList.remove('is-hidden');
      return;
    }
    this._attachSensors();
  }

  // iOS does not reliably carry a motion grant across page loads, so "we stored that it was
  // granted once" is not evidence that events will arrive. Attaching is therefore always
  // safe to retry, and the diagnostics loop offers a re-prompt when nothing shows up.
  _attachSensors() {
    if (this.sensorsAttached) {
      this.sensors.start();
      return;
    }
    this.sensorsAttached = true;
    this.sensors.start();
    this.sensors.addEventListener('sample', () => this._onSensorSample());
  }

  async _promptForMotion() {
    const state = await Sensors.requestPermission();
    if (state !== 'granted') {
      toast('Motion access was denied');
      localStorage.removeItem('airpoint.motionGranted');
      return false;
    }
    localStorage.setItem('airpoint.motionGranted', 'yes');
    this._attachSensors();
    return true;
  }

  _onSensorSample() {
    if (!this.sensors.attitude) return;

    if (this.calibrating) {
      const result = this.calibrator.add(this.sensors.rotationRate);
      if (result) this._finishCalibration(result);
      return;
    }

    const now = performance.now() / 1000;
    const gravityDown = this.sensors.gravityDown;

    if (this.sensors.hasRateStream && gravityDown) {
      this.pipeline.processRate(this.sensors.rotationRate, gravityDown, now);
      this.usingRatePath = true;
      this._maybeReportSensors();
      return;
    }

    // No gyroscope stream: fall back to differencing the orientation quaternion. Works,
    // but inherits the magnetometer's noise in yaw.
    this.usingRatePath = false;
    this.lastSensorReportAt = 0;
    this.axes = new GyroAxisResolver();
    this.previousGravity = null;
    this.lastGravityAt = null;
    this.pipeline.process({
      attitude: this.sensors.attitude,
      rotationRate: this.sensors.rotationRate,
      accelerationG: this.sensors.accelerationG,
      timestamp: now,
    });
  }

  // Periodically ships the raw sensor frame to the Mac, where it lands in the daemon log.
  //
  // Browsers and the specification disagree about sensor axis conventions, and no amount of
  // reasoning settles what a given phone reports — only measurement does. Sending it to the
  // desktop puts the numbers where someone debugging is already looking, instead of asking
  // them to read them off a phone screen while waving it about.
  _maybeReportSensors(omega) {
    const now = performance.now();
    if (now - this.lastSensorReportAt < 2000) return;
    const resolved = this.pipeline.lastResolved;
    if (!resolved) return;
    // Only report while genuinely moving; a still phone tells us nothing.
    if (Math.hypot(resolved.yaw, resolved.pitch) < 1e-4) return;
    this.lastSensorReportAt = now;

    const round = (v) => Math.round(v * 1000) / 1000;
    this.transport.send('calibration', {
      stage: 'sampling',
      gravity: [round(resolved.down.x), round(resolved.down.y), round(resolved.down.z)],
      rate: [round(omega.x), round(omega.y), round(omega.z)],
      resolved: [round(resolved.yaw), round(resolved.pitch)],
    });
  }

  _startDiagnostics() {
    clearInterval(this.diagTimer);
    let lastCount = 0;
    let lastAt = performance.now();
    this.diagTimer = setInterval(() => {
      const now = performance.now();
      const elapsed = (now - lastAt) / 1000;
      const hz = elapsed > 0 ? Math.round((this.sensors.sampleCount - lastCount) / elapsed) : 0;
      lastCount = this.sensors.sampleCount;
      lastAt = now;

      const el = $('diag');
      if (!el) return;

      let problem = null;
      if (!Sensors.isAvailable) problem = 'this browser exposes no motion sensors';
      else if (hz === 0) problem = 'no sensor data reaching the page';

      const d = this.lastSentDelta;
      el.textContent = problem
        ? `⚠ ${problem}`
        : `${this.usingRatePath ? 'gyro' : 'orient'} ${hz} Hz · `
          + `${this.axes.isResolved ? '' : 'axes:resolving · '}`
          + `clutch ${this.pipeline.isActive ? 'ON' : 'off'} · `
          + `Δ ${d.dx.toFixed(1)},${d.dy.toFixed(1)} · sent ${this.sentFrames}`;
      el.classList.toggle('is-bad', problem !== null);

      // Offer the remedy, not just the diagnosis. A permission prompt needs a user gesture,
      // so the only thing that can recover this state is a button the user can tap.
      const fix = $('diag-fix');
      if (fix) fix.classList.toggle('is-hidden', !(problem && Sensors.needsPermission));
    }, 500);
  }

  _startSendLoop() {
    // requestAnimationFrame rather than setInterval: a 16.67 ms timer drifts against the
    // display refresh, so sends land in irregular clumps and the cursor stutters even
    // though the average rate looks right. rAF is already aligned to real frames.
    this.sendLoopRunning = true;
    const tick = () => {
      if (!this.sendLoopRunning) return;
      requestAnimationFrame(tick);
      const delta = this.pipeline.drain(performance.now() / 1000);
      if (!delta) return;
      // Under backpressure, skip the send and keep accumulating rather than queueing.
      if (this.transport.isCongested) return;
      this.transport.send('pointer_move', {
        dx: Math.round(delta.dx * 100) / 100,
        dy: Math.round(delta.dy * 100) / 100,
      });
      this.lastSentDelta = delta;
      this.sentFrames += 1;
      this._updateLatency();
    };
    requestAnimationFrame(tick);
  }

  _updateLatency() {
    const latency = this.transport.latencyMs;
    if (latency === null) return;
    $('latency').textContent = `${latency} ms`;
    // High latency plus high gain causes overshoot oscillation: the user corrects for a
    // cursor position that is already stale. Back the gain off instead of letting it fight.
    const degraded = latency > 150;
    this.pipeline.tuning.sensitivity = this.baseSensitivity * (degraded ? 0.6 : 1);
    if (degraded) this._setLink('degraded', 'Slow network');
  }

  _startCalibration() {
    if (!this.sensors.isLive) {
      toast('No motion data — enable motion first');
      return;
    }
    this.calibrating = true;
    this.calibrator.start();
    this.transport.send('calibration', { stage: 'start' });
    toast('Hold the phone still…');
  }

  _finishCalibration(result) {
    this.calibrating = false;
    if (!result.ok) {
      this.transport.send('calibration', { stage: 'failed' });
      toast(result.reason);
      return;
    }
    this.pipeline.tuning.deadZoneRad = result.deadZoneRad;
    this.transport.send('calibration', {
      stage: 'complete',
      holdMs: result.holdMs,
      biasRadS: result.biasRadS,
      noiseRadS: result.noiseRadS,
    });
    this._recenter();
    toast('Calibrated — point at the screen');
    haptic(30);
  }

  _recenter() {
    // On the rate path there is no absolute reference to reset, but clearing the filter and
    // bias state is still the right response to "the cursor has wandered".
    if (this.sensors.attitude) this.pipeline.recenter(this.sensors.attitude);
    this.transport.send('recenter', { toCenter: true });
    haptic(20);
  }

  // --- UI ----------------------------------------------------------------

  _restoreSensitivity() {
    const stored = parseFloat(localStorage.getItem('airpoint.sensitivity'));
    this.baseSensitivity = Number.isFinite(stored) && stored >= 0.25 && stored <= 3 ? stored : 1;
    this.pipeline.tuning.sensitivity = this.baseSensitivity;
  }

  _wireUI() {
    // Pairing code entry
    $('code-submit').addEventListener('click', () => {
      const code = $('code-input').value.trim();
      if (!/^\d{6}$/.test(code)) {
        showError('The code is six digits.');
        return;
      }
      this.typedCode = code;
      $('connect-error').classList.add('is-hidden');
      $('code-entry').classList.add('is-hidden');
      $('connect-status').textContent = 'Approve on your Mac…';
      // Reconnect so the server issues a fresh nonce for this attempt.
      this.transport.shouldReconnect = true;
      if (this.transport.isOpen) this.transport.socket.close();
      else this.transport.connect();
    });

    $('diag-fix').addEventListener('click', async () => {
      haptic(12);
      if (await this._promptForMotion()) {
        toast('Motion enabled');
        setTimeout(() => this._startCalibration(), 400);
      }
    });

    $('enable-motion').addEventListener('click', async () => {
      const state = await Sensors.requestPermission();
      if (state !== 'granted') {
        showError('Motion access was denied. You can still use the media, keyboard and '
          + 'browser controls. To enable pointing later, reload this page and allow motion.');
        $('motion-gate').classList.add('is-hidden');
        $('screen-connect').classList.remove('is-visible');
        $('screen-remote').classList.add('is-visible');
        return;
      }
      localStorage.setItem('airpoint.motionGranted', 'yes');
      $('motion-gate').classList.add('is-hidden');
      $('screen-connect').classList.remove('is-visible');
      $('screen-remote').classList.add('is-visible');
      this._attachSensors();
      setTimeout(() => this._startCalibration(), 400);
    });

    $('disconnect').addEventListener('click', () => {
      this.transport.disconnect();
      this.sensors.stop();
      this.sendLoopRunning = false;
      $('screen-remote').classList.remove('is-visible');
      $('screen-connect').classList.add('is-visible');
      $('connect-status').textContent = 'Disconnected';
      $('motion-gate').classList.add('is-hidden');
    });

    // Tabs
    for (const tab of document.querySelectorAll('.tab')) {
      tab.addEventListener('click', () => {
        for (const other of document.querySelectorAll('.tab')) other.classList.remove('is-active');
        for (const pane of document.querySelectorAll('.pane')) pane.classList.remove('is-visible');
        tab.classList.add('is-active');
        $(`pane-${tab.dataset.pane}`).classList.add('is-visible');
        haptic(8);
      });
    }

    // Pointer controls
    for (const button of document.querySelectorAll('[data-action]')) {
      button.addEventListener('click', () => {
        haptic(12);
        switch (button.dataset.action) {
          case 'recenter':    this._recenter(); break;
          case 'calibrate':   this._startCalibration(); break;
          case 'right-click': this.transport.send('right_click', { clicks: 1 }); break;
        }
      });
    }

    const slider = $('sensitivity');
    slider.value = String(this.baseSensitivity);
    $('sensitivity-value').textContent = `${this.baseSensitivity.toFixed(2)}×`;
    slider.addEventListener('input', () => {
      this.baseSensitivity = parseFloat(slider.value);
      this.pipeline.tuning.sensitivity = this.baseSensitivity;
      $('sensitivity-value').textContent = `${this.baseSensitivity.toFixed(2)}×`;
      localStorage.setItem('airpoint.sensitivity', slider.value);
    });

    // Media, keys, browser
    for (const button of document.querySelectorAll('[data-media]')) {
      button.addEventListener('click', () => {
        haptic(12);
        const payload = { command: button.dataset.media };
        if (button.dataset.amount) payload.amount = Number(button.dataset.amount);
        this.transport.send('media_command', payload);
      });
    }
    for (const button of document.querySelectorAll('[data-key]')) {
      button.addEventListener('click', () => {
        haptic(10);
        this.transport.send('key_press', {
          key: this._keyName(button.dataset.key),
          mods: button.dataset.mods ? button.dataset.mods.split(',') : [],
          repeat: 1,
        });
      });
    }

    $('text-send').addEventListener('click', () => {
      const input = $('text-input');
      if (!input.value) return;
      this.transport.send('text_input', { text: input.value });
      input.value = '';
      haptic(15);
      toast('Sent');
    });

    $('address-go').addEventListener('click', () => {
      const input = $('address-input');
      if (!input.value) return;
      // Focus the address bar, then type. Cmd+L is the same in every Mac browser.
      this.transport.send('key_press', { key: 'l', mods: ['cmd'] });
      setTimeout(() => {
        this.transport.send('text_input', { text: input.value });
        setTimeout(() => this.transport.send('key_press', { key: 'Return', mods: [] }), 60);
      }, 120);
      input.value = '';
      haptic(15);
    });

    this._wireAimLock();
    this._wirePad();
    this._wireLifecycle();
  }

  _wireAimLock() {
    const button = $('aim-lock');
    const apply = () => {
      button.setAttribute('aria-pressed', String(this.aimLocked));
      button.textContent = this.aimLocked ? 'Aim: locked on — tap to unlock' : 'Aim: hold the pad';
      $('pad').classList.toggle('is-locked', this.aimLocked);
      $('pad-live').classList.toggle('is-hidden', !this.aimLocked);
      this.pipeline.setActive(this.aimLocked);
      if (this.aimLocked && this.sensors.attitude) {
        this.pipeline.recenter(this.sensors.attitude);
      }
      localStorage.setItem('airpoint.aimLocked', this.aimLocked ? 'yes' : 'no');
    };
    button.addEventListener('click', () => {
      this.aimLocked = !this.aimLocked;
      haptic(this.aimLocked ? [20, 40, 20] : 12);
      toast(this.aimLocked ? 'Aim locked — the phone now steers the cursor'
                           : 'Hold the pad to aim');
      apply();
    });
    apply();
  }

  // The protocol's key names are mostly literal; a few UI labels use friendlier aliases.
  _keyName(name) {
    const aliases = { bracketLeft: '[', bracketRight: ']' };
    return aliases[name] || name;
  }

  // --- The pad -----------------------------------------------------------

  // Gesture contract:
  //   finger down            -> clutch engaged, motion live
  //   lift within 350ms and <12px  -> left click
  //   hold 500ms                   -> drag begins (haptic), ends on lift
  //   move >12px vertically        -> scroll, motion suspended so the two do not fight
  //   two fingers, quick tap       -> right click
  //
  // Pointing comes from moving the *phone*, and the finger stays still, so finger travel
  // is free to mean "scroll" without ever conflicting with aiming.
  _wirePad() {
    const pad = $('pad');
    const TAP_MS = 350;
    const TAP_SLOP = 12;
    const HOLD_MS = 500;

    let startedAt = 0;
    let startX = 0, startY = 0;
    let lastY = 0, lastX = 0;
    let moved = false;
    let scrolling = false;
    let dragging = false;
    let holdTimer = null;
    let touchCount = 0;

    const engage = () => {
      if (this.aimLocked) return;   // already running; a touch must not re-seed it
      this.pipeline.setActive(true);
      pad.classList.add('is-engaged');
      $('pad-live').classList.remove('is-hidden');
      // Recentre on engage so "where I am aiming now" always maps to "where the cursor is
      // now". Without this the cursor jumps by however much the phone moved while idle.
      if (this.sensors.attitude) this.pipeline.recenter(this.sensors.attitude);
    };

    const release = () => {
      if (this.aimLocked) {
        pad.classList.remove('is-dragging');
        return;
      }
      this.pipeline.setActive(false);
      pad.classList.remove('is-engaged', 'is-dragging');
      $('pad-live').classList.add('is-hidden');
    };

    pad.addEventListener('touchstart', (event) => {
      event.preventDefault();
      touchCount = event.touches.length;
      if (touchCount > 1) {
        clearTimeout(holdTimer);
        return;
      }
      const touch = event.touches[0];
      startedAt = performance.now();
      startX = lastX = touch.clientX;
      startY = lastY = touch.clientY;
      moved = false;
      scrolling = false;
      dragging = false;
      engage();
      haptic(8);

      holdTimer = setTimeout(() => {
        if (moved) return;
        dragging = true;
        pad.classList.add('is-dragging');
        this.transport.send('drag_start', { button: 'left' });
        haptic([20, 40, 20]);
      }, HOLD_MS);
    }, { passive: false });

    pad.addEventListener('touchmove', (event) => {
      event.preventDefault();
      if (event.touches.length > 1) return;
      const touch = event.touches[0];
      const dx = touch.clientX - startX;
      const dy = touch.clientY - startY;

      if (!moved && Math.hypot(dx, dy) > TAP_SLOP) {
        moved = true;
        clearTimeout(holdTimer);
        if (!dragging) {
          // Finger travel means scroll. Suspend pointing so the cursor does not wander
          // while the user is scrolling.
          scrolling = true;
          this.pipeline.setActive(false);
          pad.classList.remove('is-engaged');
        }
      }

      if (scrolling) {
        const stepY = touch.clientY - lastY;
        const stepX = touch.clientX - lastX;
        // Natural direction: dragging the content up scrolls down.
        this.transport.send('scroll', {
          dx: Math.round(stepX * 2),
          dy: Math.round(stepY * 2),
          unit: 'px',
          momentum: false,
        });
      }
      lastX = touch.clientX;
      lastY = touch.clientY;
    }, { passive: false });

    const finish = (event) => {
      event.preventDefault();
      clearTimeout(holdTimer);
      const elapsed = performance.now() - startedAt;

      if (dragging) {
        this.transport.send('drag_end', { button: 'left' });
        haptic(15);
      } else if (touchCount > 1) {
        this.transport.send('right_click', { clicks: 1 });
        haptic([10, 30, 10]);
        toast('Right click');
      } else if (!moved && elapsed < TAP_MS) {
        this.transport.send('left_click', { clicks: 1 });
        haptic(15);
      }

      touchCount = 0;
      release();
    };

    pad.addEventListener('touchend', finish, { passive: false });
    pad.addEventListener('touchcancel', (event) => {
      // A cancelled touch is the OS taking over (a call, control centre). Treat it as a
      // release, never as a click, and make sure no drag is left hanging.
      clearTimeout(holdTimer);
      if (dragging) this.transport.send('drag_end', { button: 'left' });
      touchCount = 0;
      release();
      event.preventDefault();
    }, { passive: false });

    // Mouse fallback so the whole flow can be exercised in a desktop browser during
    // development, without a phone.
    pad.addEventListener('mousedown', () => { engage(); startedAt = performance.now(); });
    pad.addEventListener('mouseup', () => {
      if (performance.now() - startedAt < TAP_MS) this.transport.send('left_click', { clicks: 1 });
      release();
    });
    pad.addEventListener('mouseleave', release);
  }

  _wireLifecycle() {
    // The page is suspended when the phone locks or the user switches app. Sensor delivery
    // stops without warning, so freeze the pointer and reseed on return; otherwise the
    // first sample after resuming would describe minutes of accumulated rotation.
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        this.pipeline.setActive(false);
        this.pipeline.reset();
      } else if (this.sensors.attitude) {
        this.pipeline.recenter(this.sensors.attitude);
      }
    });

    window.addEventListener('orientationchange', () => {
      // Roll compensation makes the pipeline orientation-agnostic, but the reference
      // attitude was captured in the old grip, so re-seed it.
      if (this.sensors.attitude) this.pipeline.recenter(this.sensors.attitude);
    });

    // Stop the browser turning a double-tap into a zoom on the control surfaces.
    document.addEventListener('gesturestart', (event) => event.preventDefault());
    document.addEventListener('dblclick', (event) => event.preventDefault());
  }
}

const app = new App();
app.start();
