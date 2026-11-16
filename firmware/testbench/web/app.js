(() => {
  'use strict';

  const SETTINGS = Object.freeze({
    pollMilliseconds: 1000,
    requestTimeoutMilliseconds: 12000,
    staleFrameSeconds: 3,
    defaultSoakSeconds: 60,
    maximumVisibleEvents: 100,
    wifi: Object.freeze({ maxSsidBytes: 32, minPassphraseBytes: 8, maxPassphraseBytes: 63, pskBytes: 64 }),
    localeStorageKey: 'spectrulenpor.testbench.locale',
    reportFilename: 'spectrulenpor-testbench-report.json',
    endpoints: Object.freeze({
      localization: '/api/localization', config: '/api/config', state: '/api/state',
      frame: '/api/frame.jpg', action: '/api/action', report: '/api/report',
    }),
  });
  const PROFILES = Object.freeze({
    smoke: { label: 'tbProfileSmoke', description: 'tbProfileSmokeHint' },
    full: { label: 'tbProfileFull', description: 'tbProfileFullHint', destructive: true },
    'mobile-flow': { label: 'tbProfileMobileFlow', description: 'tbProfileMobileFlowHint' },
    'missing-ap': { label: 'tbProfileMissingAp', description: 'tbProfileMissingApHint', destructive: true },
    soak: { label: 'tbProfileSoak', description: 'tbProfileSoakHint' },
  });
  const PHASES = Object.freeze({
    disconnected: { label: 'tbPhaseDisconnected', guidance: 'tbGuideDisconnected', step: 0 },
    ble_setup: { label: 'tbPhaseBleSetup', guidance: 'tbGuideBleSetup', step: 0 },
    paired: { label: 'tbPhasePaired', guidance: 'tbGuidePaired', step: 1, tone: 'good' },
    provisioned: { label: 'tbPhaseProvisioned', guidance: 'tbGuideProvisioned', step: 2, tone: 'good' },
    rebooting: { label: 'tbPhaseRebooting', guidance: 'tbGuideRebooting', step: 2, tone: 'warning' },
    wifi_ready: { label: 'tbPhaseWifiReady', guidance: 'tbGuideWifiReady', step: 3, tone: 'good' },
    streaming: { label: 'tbPhaseStreaming', guidance: 'tbGuideStreaming', step: 4, tone: 'good' },
    paused: { label: 'tbPhasePaused', guidance: 'tbGuidePaused', step: 4 },
    error: { label: 'tbPhaseError', guidance: 'tbGuideError', step: -1, tone: 'error' },
  });
  const STATUSES = Object.freeze({
    queued: ['tbStatusQueued', 'warning'], running: ['tbStatusRunning', 'warning'],
    pending: ['tbStatusQueued', 'warning'], started: ['tbStatusStarted', 'warning'],
    passed: ['tbStatusPassed', 'good'], success: ['tbStatusSuccess', 'good'],
    ok: ['tbStatusSuccess', 'good'], completed: ['tbStatusCompleted', 'good'],
    complete: ['tbStatusCompleted', 'good'], succeeded: ['tbStatusCompleted', 'good'],
    failed: ['tbStatusFailed', 'error'], failure: ['tbStatusFailed', 'error'],
    error: ['tbStatusFailed', 'error'], rejected: ['tbStatusRejected', 'error'],
    cancelled: ['tbStatusCancelled', ''], canceled: ['tbStatusCancelled', ''],
    cancelling: ['tbStatusCancelling', 'warning'], skipped: ['tbStatusSkipped', 'warning'],
    unverified: ['tbStatusUnverified', 'warning'], warning: ['tbStatusWarning', 'warning'],
    ready: ['tbStatusReady', 'good'], idle: ['tbStatusIdle', ''],
  });
  const ACTION_LABELS = Object.freeze({
    connect: 'tbConnect', setup: 'tbSaveAndReboot', reboot: 'tbRebootOnly',
    attach: 'tbAttach', stream: 'tbStreamOperation', single: 'tbSingleFrame',
    flash: 'tbFlashOperation', disconnect: 'tbDisconnect', test: 'tbRunTests', cancel: 'tbCancelRun',
  });
  const ACTIVE_JOB_STATUSES = new Set(['queued', 'pending', 'running', 'cancelling']);
  const $ = (id) => document.getElementById(id);
  let dictionary = Object.create(null);
  let locale = initialLocale();
  let localizationReady = false;
  let localizationGeneration = 0;
  let config = null;
  let configPromise = null;
  let state = null;
  let statePromise = null;
  let backendAvailable = false;
  let actionPending = false;
  let cancellationPending = false;
  let reportPending = false;
  let flashRequested = false;
  let connectionIdentity = null;
  let pollTimer = null;
  let stopped = false;
  let lastFrameSequence = null;
  let frameRequest = null;
  let frameUrl = null;
  let displayedFrame = null;
  let displayedFrameAt = 0;
  let previewReady = false;
  let frameUnavailable = false;
  let confirmationProfile = null;
  let notice = null;
  let recordsSignature = '';
  let eventsSignature = '';
  let reportedErrorSignature = '';

  function initialLocale() {
    try {
      const saved = localStorage.getItem(SETTINGS.localeStorageKey);
      if (saved === 'en' || saved === 'ar') return saved;
    } catch { /* Preferences are optional when storage is unavailable. */ }
    return navigator.language?.startsWith('ar') ? 'ar' : 'en';
  }

  function t(key) {
    return typeof dictionary[key] === 'string' && dictionary[key].trim() ? dictionary[key] : key;
  }

  function setText(element, value) {
    const text = String(value ?? '');
    if (element.textContent !== text) element.textContent = text;
  }

  function numeric(value, decimals = 0) {
    if (typeof value !== 'number' || !Number.isFinite(value)) return t('tbUnknownValue');
    return new Intl.NumberFormat(`${locale}-u-nu-latn`, {
      minimumFractionDigits: decimals, maximumFractionDigits: decimals,
    }).format(value);
  }

  function translatedData(value) {
    if (value == null || value === '') return t('tbUnknownValue');
    if (typeof value === 'string') return Object.hasOwn(dictionary, value) ? t(value) : value;
    return JSON.stringify(redactData(value));
  }

  function redactData(value) {
    if (Array.isArray(value)) return value.map(redactData);
    if (value && typeof value === 'object') {
      const result = Object.create(null);
      for (const [key, entry] of Object.entries(value)) {
        result[key] = /password|passphrase|psk|credential|secret|token/i.test(key) ? t('tbRedacted') : redactData(entry);
      }
      return result;
    }
    return value;
  }

  class ApiFailure extends Error {
    constructor(key, code = '') {
      super(key);
      this.key = key;
      this.code = code;
    }
  }

  async function request(url, options = {}, responseType = 'json') {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), SETTINGS.requestTimeoutMilliseconds);
    const abort = () => controller.abort();
    if (options.signal) {
      if (options.signal.aborted) controller.abort();
      options.signal.addEventListener('abort', abort, { once: true });
    }
    try {
      const response = await fetch(url, {
        ...options, signal: controller.signal, cache: 'no-store', credentials: 'same-origin',
        headers: { Accept: responseType === 'frame' ? 'image/jpeg' : 'application/json', ...options.headers },
      });
      if (!response.ok) {
        let problem = null;
        try { problem = await response.json(); } catch { /* An unavailable server may return no JSON. */ }
        throw new ApiFailure(problem?.error?.message_key || 'tbRequestFailed', problem?.error?.code || `HTTP_${response.status}`);
      }
      if (response.status === 204) return null;
      try {
        return responseType === 'frame'
          ? { blob: await response.blob(), sequence: response.headers.get('X-Frame-Sequence') }
          : await response.json();
      }
      catch { throw new ApiFailure('tbInvalidResponse', 'INVALID_RESPONSE'); }
    } catch (error) {
      if (error instanceof ApiFailure) throw error;
      throw new ApiFailure('tbBackendUnavailable', controller.signal.aborted ? 'REQUEST_TIMEOUT' : 'BACKEND_UNAVAILABLE');
    } finally {
      window.clearTimeout(timeout);
      options.signal?.removeEventListener('abort', abort);
    }
  }

  function showNotice(key, code = '', tone = 'error') {
    notice = { key, code, tone };
    renderNotice();
  }

  function renderNotice() {
    $('notice').hidden = !notice;
    if (!notice) return;
    $('notice').classList.toggle('notice-error', notice.tone === 'error');
    setText($('notice-message'), t(notice.key));
    setText($('notice-code'), notice.code);
    $('notice-code').hidden = !notice.code;
  }

  function applyLocalization() {
    document.documentElement.lang = locale;
    document.documentElement.dir = locale === 'ar' ? 'rtl' : 'ltr';
    document.title = t('tbDocumentTitle');
    for (const element of document.querySelectorAll('[data-i18n]')) setText(element, t(element.dataset.i18n));
    for (const [attribute, dataset] of [['aria-label', 'i18nAria'], ['alt', 'i18nAlt'], ['title', 'i18nTitle']]) {
      for (const element of document.querySelectorAll(`[data-${dataset.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}]`)) {
        element.setAttribute(attribute, t(element.dataset[dataset]));
      }
    }
    for (const button of document.querySelectorAll('[data-locale]')) button.setAttribute('aria-pressed', String(button.dataset.locale === locale));
    recordsSignature = '';
    eventsSignature = '';
    render();
  }

  async function loadLocalization(nextLocale) {
    const generation = ++localizationGeneration;
    try {
      const result = await request(`${SETTINGS.endpoints.localization}?locale=${nextLocale}`);
      if (!result || typeof result !== 'object' || Array.isArray(result) || typeof result.tbDashboardTitle !== 'string') {
        throw new ApiFailure('tbLocalizationUnavailable', 'INVALID_LOCALIZATION');
      }
      if (generation !== localizationGeneration || stopped) return;
      dictionary = result;
      locale = nextLocale;
      localizationReady = true;
      try { localStorage.setItem(SETTINGS.localeStorageKey, locale); } catch { /* Never persist session data or credentials. */ }
      applyLocalization();
    } catch (error) {
      if (generation !== localizationGeneration || stopped) return;
      showNotice(localizationReady ? 'tbLocalizationUnavailable' : 'tbBackendUnavailable', error.code);
      if (!localizationReady) applyLocalization();
    }
  }

  async function loadConfig() {
    if (configPromise) return configPromise;
    configPromise = (async () => {
      try {
        const result = await request(SETTINGS.endpoints.config);
        if (!result || typeof result.csrf_token !== 'string' || !result.csrf_token) throw new ApiFailure('tbConfigurationUnavailable', 'INVALID_CONFIG');
        config = result;
        if (!$('adapter').value) $('adapter').value = typeof result.adapter === 'string' ? result.adapter : '';
        $('uart').value = typeof result.uart === 'string' ? result.uart : '';
        const available = Array.isArray(result.profiles) ? result.profiles : [];
        for (const option of $('test-profile').options) {
          const enabled = available.some((profile) => (typeof profile === 'string' ? profile : profile?.id) === option.value);
          option.disabled = !enabled;
          option.hidden = !enabled;
        }
        const options = Array.from($('test-profile').options).filter((option) => !option.disabled);
        if ($('test-profile').selectedOptions[0]?.disabled) $('test-profile').value = options[0]?.value || '';
      } catch (error) {
        showNotice(error.key || 'tbConfigurationUnavailable', error.code);
      } finally {
        configPromise = null;
        render();
      }
    })();
    return configPromise;
  }

  async function refreshState() {
    if (statePromise) return statePromise;
    statePromise = (async () => {
      try {
        const result = await request(SETTINGS.endpoints.state);
        if (!result || typeof result.phase !== 'string' || typeof result.busy !== 'boolean') throw new ApiFailure('tbInvalidResponse', 'INVALID_STATE');
        if (stopped) return;
        state = result;
        backendAvailable = true;
        const identity = `${state.transport || ''}:${state.esp_mac || state.ip || ''}`;
        if (identity !== connectionIdentity) {
          connectionIdentity = identity;
          flashRequested = false;
        }
        if (state.error) {
          const signature = JSON.stringify(state.error);
          if (signature !== reportedErrorSignature) showNotice(state.error.message_key || 'tbActionRejected', state.error.code);
          reportedErrorSignature = signature;
        } else reportedErrorSignature = '';
        render();
        updateFrame();
      } catch {
        if (!stopped) { backendAvailable = false; render(); }
      } finally { statePromise = null; }
    })();
    return statePromise;
  }

  async function poll() {
    if (stopped) return;
    const recovery = [];
    if (!localizationReady) recovery.push(loadLocalization(locale));
    if (!config) recovery.push(loadConfig());
    await Promise.allSettled([refreshState(), ...recovery]);
    if (!stopped) pollTimer = window.setTimeout(poll, SETTINGS.pollMilliseconds);
  }

  function isBusy() { return actionPending || Boolean(state?.busy); }
  function isReady() { return localizationReady && backendAvailable && config && state; }
  function hasMediaTransport() { return Boolean(state?.connected || state?.transport === 'udp'); }

  function setChip(element, key, tone = '') {
    setText(element, t(key));
    element.dataset.tone = tone;
  }

  function renderControls() {
    const ready = isReady();
    const busy = isBusy();
    const disabled = !ready || busy;
    const bleConnected = state?.connected && state?.transport === 'ble';
    const setupReady = bleConnected && ['ble_setup', 'paired'].includes(state?.phase);
    for (const element of document.querySelectorAll('[data-mutation]')) element.disabled = disabled;
    $('connect-button').disabled = disabled || Boolean(state?.connected || state?.transport === 'udp');
    $('setup-button').disabled = disabled || !setupReady;
    $('reboot-button').disabled = disabled || !bleConnected || state?.phase !== 'provisioned';
    $('attach-button').disabled = disabled || Boolean(bleConnected);
    for (const id of ['stream-button', 'single-button', 'flash-button']) $(id).disabled = disabled || !hasMediaTransport();
    $('disconnect-button').disabled = disabled || !hasMediaTransport();
    const profile = $('test-profile').value;
    $('run-button').disabled = disabled || !Object.hasOwn(PROFILES, profile) || Boolean($('test-profile').selectedOptions[0]?.disabled);
    $('cancel-button').disabled = !ready || cancellationPending || !(busy || ACTIVE_JOB_STATUSES.has(state?.job?.status));
    $('busy-status').hidden = !busy && !cancellationPending;
    $('workspace').setAttribute('aria-busy', String(busy));
    $('manual-wifi').hidden = $('wifi-from-nm').checked;
    $('password').disabled = disabled || $('wifi-from-nm').checked;
    $('ssid').disabled = disabled || $('wifi-from-nm').checked;
    $('duration-field').hidden = profile !== 'soak';
    $('profile-warning').hidden = !PROFILES[profile]?.destructive;
    setText($('profile-description'), t(PROFILES[profile]?.description || 'tbNoProfiles'));
    const streaming = state?.phase === 'streaming';
    setText($('stream-label'), t(streaming ? 'tbPauseStream' : 'tbStartStream'));
    $('stream-icon').setAttribute('href', streaming ? '#icon-pause' : '#icon-play');
    setText($('flash-label'), t(flashRequested ? 'tbDisableFlash' : 'tbEnableFlash'));
    $('flash-button').setAttribute('aria-pressed', String(flashRequested));
    $('flash-button').title = t('tbFlashCommandHint');
    $('download-report').disabled = !ready || reportPending;
    $('view-report').disabled = !ready || reportPending;
    setText($('view-report'), t(reportPending ? 'tbReportLoading' : 'tbViewReport'));
    $('confirm-run').disabled = disabled || !$('confirm-fresh').checked || !$('confirm-configuration').checked;
  }

  function renderPreview() {
    const latest = state?.frame;
    const sameFrame = displayedFrame && latest?.sequence === displayedFrame.sequence;
    const frame = sameFrame && backendAvailable ? latest : displayedFrame;
    const age = sameFrame && backendAvailable ? frame?.age_seconds : typeof frame?.age_seconds === 'number' ? frame.age_seconds + (performance.now() - displayedFrameAt) / 1000 : null;
    const hasFrame = previewReady && Boolean(frameUrl);
    const stale = hasFrame && (!backendAvailable || frameUnavailable || !sameFrame || typeof age !== 'number' || age > SETTINGS.staleFrameSeconds);
    const paused = state?.phase === 'paused';
    $('preview-image').hidden = !hasFrame;
    $('preview-empty').hidden = hasFrame;
    $('frame-overlay').hidden = !hasFrame;
    $('viewfinder').classList.toggle('stale', stale);
    $('stale-overlay').hidden = !hasFrame || (!stale && !paused);
    setText($('stale-message'), t(stale ? 'tbFrameStaleHint' : 'tbFramePausedHint'));
    if (!hasFrame) setChip($('preview-status'), 'tbPreviewEmpty');
    else if (stale) setChip($('preview-status'), 'tbPreviewStale', 'warning');
    else if (paused) setChip($('preview-status'), 'tbPreviewPaused');
    else if (state?.phase === 'streaming') setChip($('preview-status'), 'tbPreviewLive', 'good');
    else setChip($('preview-status'), 'tbPreviewReady');
    setText($('frame-sequence'), numeric(frame?.sequence));
    setText($('frame-resolution'), typeof frame?.width === 'number' && typeof frame?.height === 'number' ? `${numeric(frame.width)} × ${numeric(frame.height)}` : t('tbUnknownValue'));
    setText($('frame-age'), numeric(age, 1));
    setText($('frame-bytes'), numeric(frame?.bytes));
    setText($('transport-value'), state?.transport ? state.transport.toUpperCase() : t('tbNoTransport'));
    setText($('metric-fps'), numeric(state?.metrics?.received_fps, 1));
    setText($('metric-frames'), numeric(state?.metrics?.frames));
    setText($('metric-incomplete'), numeric(state?.metrics?.incomplete_frames));
    setText($('metric-datagrams'), numeric(state?.metrics?.datagrams));
  }

  async function updateFrame() {
    const sequence = state?.frame?.sequence;
    if (sequence == null) {
      lastFrameSequence = null;
      frameRequest?.abort();
      frameRequest = null;
      if (frameUrl) URL.revokeObjectURL(frameUrl);
      frameUrl = null;
      displayedFrame = null;
      previewReady = false;
      frameUnavailable = false;
      renderPreview();
      return;
    }
    if (sequence === lastFrameSequence || !backendAvailable) return;
    lastFrameSequence = sequence;
    frameRequest?.abort();
    const controller = new AbortController();
    frameRequest = controller;
    try {
      const result = await request(`${SETTINGS.endpoints.frame}?sequence=${encodeURIComponent(sequence)}`, { signal: controller.signal }, 'frame');
      if (controller.signal.aborted || stopped || state?.frame?.sequence !== sequence) return;
      if (result?.sequence != null && result.sequence !== String(sequence)) {
        frameUnavailable = true;
        renderPreview();
        return;
      }
      const blob = result?.blob;
      if (!blob || !blob.size || !blob.type.toLowerCase().startsWith('image/jpeg')) {
        frameUnavailable = true;
        renderPreview();
        return;
      }
      const nextUrl = URL.createObjectURL(blob);
      const image = new Image();
      image.onload = () => {
        if (controller.signal.aborted || stopped || state?.frame?.sequence !== sequence) { URL.revokeObjectURL(nextUrl); return; }
        if (frameUrl) URL.revokeObjectURL(frameUrl);
        frameUrl = nextUrl;
        displayedFrame = { ...state.frame };
        displayedFrameAt = performance.now();
        $('preview-image').src = nextUrl;
        previewReady = true;
        frameUnavailable = false;
        renderPreview();
      };
      image.onerror = () => { URL.revokeObjectURL(nextUrl); if (!controller.signal.aborted && !stopped) { frameUnavailable = true; renderPreview(); } };
      image.src = nextUrl;
    } catch {
      if (!controller.signal.aborted && !stopped) { frameUnavailable = true; renderPreview(); }
    } finally { if (frameRequest === controller) frameRequest = null; }
  }

  function renderJob() {
    const job = state?.job;
    const records = Array.isArray(job?.records) ? job.records : [];
    const status = job ? STATUSES[job.status] || ['tbStatusUnknown', ''] : ['tbStatusIdle', ''];
    setChip($('job-status'), ...status);
    $('run-progress').hidden = !job;
    setText($('job-profile'), job ? t(PROFILES[job.profile]?.label || ACTION_LABELS[job.profile] || 'tbProfileUnknown') : '');
    setText($('job-id'), job?.id || '');
    setText($('record-count'), numeric(records.length));
    if (job && ACTIVE_JOB_STATUSES.has(job.status)) $('job-progress').removeAttribute('value');
    else { $('job-progress').max = Math.max(1, records.length); $('job-progress').value = records.length; }
    $('results-empty').hidden = records.length > 0;
    $('results-wrap').hidden = records.length === 0;
    const signature = JSON.stringify(records);
    if (signature !== recordsSignature) {
      recordsSignature = signature;
      const fragment = document.createDocumentFragment();
      for (const record of records) {
        const row = document.createElement('tr');
        const name = document.createElement('td');
        name.dir = 'auto';
        setText(name, translatedData(record.name));
        const outcome = document.createElement('td');
        const badge = document.createElement('span');
        badge.className = 'result-status';
        const [key, tone] = record.ok === true ? ['tbStatusPassed', 'good'] : record.ok === false ? ['tbStatusFailed', 'error'] : ['tbStatusUnverified', 'warning'];
        setChip(badge, key, tone);
        outcome.append(badge);
        const duration = document.createElement('td');
        duration.className = 'result-duration';
        duration.dir = 'ltr';
        setText(duration, typeof record.seconds === 'number' ? `${numeric(record.seconds, 2)} ${t('tbSecondsUnit')}` : t('tbUnknownValue'));
        const details = document.createElement('td');
        details.dir = 'auto';
        if (record.code) {
          const code = document.createElement('code');
          code.className = 'result-code';
          code.dir = 'ltr';
          setText(code, record.code);
          details.append(code);
        }
        const detail = document.createElement('span');
        setText(detail, record.details == null ? '' : translatedData(record.details));
        details.append(detail);
        row.append(name, outcome, duration, details);
        fragment.append(row);
      }
      $('results-body').replaceChildren(fragment);
    }
    $('job-error').hidden = !job?.error;
    if (job?.error) {
      setText($('job-error-message'), t(typeof job.error === 'object' ? job.error.message_key || 'tbTestFailed' : 'tbTestFailed'));
      setText($('job-error-code'), typeof job.error === 'object' ? job.error.code || '' : job.error);
    }
  }

  function renderEvents() {
    const events = Array.isArray(state?.events) ? state.events : [];
    setText($('event-count'), numeric(events.length));
    $('events-empty').hidden = events.length > 0;
    const recent = events.slice(-SETTINGS.maximumVisibleEvents).reverse();
    const signature = JSON.stringify(recent);
    if (eventsSignature === signature) return;
    eventsSignature = signature;
    const fragment = document.createDocumentFragment();
    for (const event of recent) {
      const item = document.createElement('li');
      const time = document.createElement('time');
      time.dir = 'ltr';
      const date = typeof event.timestamp === 'number' ? new Date(event.timestamp * 1000) : new Date(event.timestamp);
      if (event.timestamp != null && Number.isFinite(date.getTime())) {
        time.dateTime = date.toISOString();
        time.title = date.toLocaleString(locale);
        setText(time, new Intl.DateTimeFormat(`${locale}-u-nu-latn`, { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(date));
      } else setText(time, translatedData(event.timestamp));
      const body = document.createElement('span');
      body.className = 'event-operation';
      body.dir = 'auto';
      setText(body, ACTION_LABELS[event.operation] ? t(ACTION_LABELS[event.operation]) : translatedData(event.operation));
      if (event.code || event.details) {
        const detail = document.createElement('span');
        detail.className = 'event-detail';
        detail.dir = 'auto';
        setText(detail, [event.code, event.details ? translatedData(event.details) : ''].filter(Boolean).join(' · '));
        body.append(detail);
      }
      const outcome = document.createElement('span');
      outcome.className = 'event-outcome';
      const [key, tone] = STATUSES[event.outcome] || ['tbStatusUnknown', ''];
      setChip(outcome, key, tone);
      item.append(time, body, outcome);
      fragment.append(item);
    }
    $('event-list').replaceChildren(fragment);
  }

  function render() {
    const phase = PHASES[state?.phase] || { label: 'tbPhaseUnknown', guidance: 'tbGuideUnknown', step: -1 };
    setChip($('phase-status'), phase.label, phase.tone);
    setText($('phase-guidance'), t(phase.guidance));
    for (const step of document.querySelectorAll('[data-step]')) {
      const index = Number(step.dataset.step);
      step.classList.toggle('complete', phase.step > index);
      if (phase.step === index) step.setAttribute('aria-current', 'step');
      else step.removeAttribute('aria-current');
    }
    setText($('connection-status'), t(backendAvailable ? 'tbBackendConnected' : 'tbBackendUnavailable'));
    $('connection-dot').classList.toggle('online', backendAvailable);
    $('connection-dot').classList.toggle('offline', !backendAvailable);
    $('offline-banner').hidden = backendAvailable;
    setText($('device-mac'), translatedData(state?.esp_mac));
    setText($('device-hostname'), translatedData(state?.esp_hostname));
    setText($('active-ip'), translatedData(state?.ip));
    setText($('local-listener'), config?.port != null ? `${location.hostname}:${config.port}` : t('tbUnknownValue'));
    setText($('uart-status'), t(state?.capabilities?.uart ? 'tbUartAvailable' : 'tbUartUnavailable'));
    renderControls();
    renderPreview();
    renderJob();
    renderEvents();
    renderNotice();
  }

  async function sendAction(action, params = {}) {
    const cancelling = action === 'cancel';
    if (!isReady() || (!cancelling && isBusy()) || (cancelling && cancellationPending)) return false;
    if (cancelling) cancellationPending = true;
    else actionPending = true;
    renderControls();
    try {
      await request(SETTINGS.endpoints.action, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Testbench-Token': config.csrf_token },
        body: JSON.stringify({ action, params }),
      });
      if (action === 'flash') flashRequested = Boolean(params.enabled);
      if (action === 'disconnect') flashRequested = false;
      showNotice(cancelling ? 'tbCancellationRequested' : 'tbActionQueued', '', 'info');
      await refreshState();
      return true;
    } catch (error) {
      showNotice(error.key || 'tbActionRejected', error.code);
      if (error.code === 'HTTP_403' || /CSRF|TOKEN/i.test(error.code || '')) config = null;
      return false;
    } finally {
      if (cancelling) cancellationPending = false;
      else actionPending = false;
      renderControls();
    }
  }

  function invalidInput(id, key) {
    $(id).setAttribute('aria-invalid', 'true');
    $(id).setAttribute('aria-describedby', 'notice-message');
    showNotice(key);
    $(id).focus();
  }

  function validIpv4(value) {
    const parts = value.split('.');
    return parts.length === 4 && parts.every((part) => /^(0|[1-9]\d{0,2})$/.test(part) && Number(part) <= 255);
  }

  function closeConfirmation() {
    $('confirmation-dialog').close();
    confirmationProfile = null;
    $('confirm-fresh').checked = false;
    $('confirm-configuration').checked = false;
    $('confirm-run').disabled = true;
  }

  function wifiParams() {
    const password = $('password').value;
    $('password').value = '';
    if ($('wifi-from-nm').checked) return { wifi_from_nm: true };
    const ssid = $('ssid').value;
    const encoder = new TextEncoder();
    const ssidBytes = encoder.encode(ssid).length;
    if (!ssidBytes || ssidBytes > SETTINGS.wifi.maxSsidBytes || ssid.includes('\0')) {
      invalidInput('ssid', 'tbInvalidSsid');
      return null;
    }
    const passBytes = encoder.encode(password).length;
    const passphrase = passBytes >= SETTINGS.wifi.minPassphraseBytes && passBytes <= SETTINGS.wifi.maxPassphraseBytes;
    const psk = passBytes === SETTINGS.wifi.pskBytes && /^[0-9a-fA-F]+$/.test(password);
    if (password.includes('\0') || (passBytes && !passphrase && !psk)) {
      invalidInput('password', 'tbErrorInvalidWifi');
      return null;
    }
    return { ssid, password };
  }

  async function startTest(profile, confirmed = false) {
    const params = { profile };
    if (PROFILES[profile]?.destructive) {
      if (!confirmed) return;
      params.confirm_configuration = true;
    }
    if (profile === 'soak') {
      const duration = Number($('soak-duration').value);
      if (!Number.isSafeInteger(duration) || duration <= 0) { invalidInput('soak-duration', 'tbInvalidDuration'); return; }
      params.duration_seconds = duration;
    }
    if (profile === 'full' || profile === 'mobile-flow') {
      const wifi = wifiParams();
      if (!wifi) return;
      Object.assign(params, wifi);
      if (profile === 'mobile-flow' && !config?.uart) {
        const ip = $('device-ip').value.trim();
        if (!validIpv4(ip)) { invalidInput('device-ip', 'tbInvalidIp'); return; }
        params.ip = ip;
      }
    }
    await sendAction('test', params);
  }

  async function fetchReport(download) {
    if (reportPending || !isReady()) return;
    reportPending = true;
    renderControls();
    try {
      const report = await request(SETTINGS.endpoints.report);
      if (report == null) throw new ApiFailure('tbReportUnavailable', 'NO_REPORT');
      const json = JSON.stringify(redactData(report), null, 2);
      if (download) {
        const url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
        const anchor = document.createElement('a');
        anchor.href = url;
        anchor.download = SETTINGS.reportFilename;
        document.body.append(anchor);
        anchor.click();
        anchor.remove();
        window.setTimeout(() => URL.revokeObjectURL(url), SETTINGS.pollMilliseconds);
      } else {
        setText($('report-json'), json);
        $('report-content').hidden = false;
        $('report-json').focus();
      }
    } catch (error) { showNotice(error.key || 'tbReportUnavailable', error.code); }
    finally { reportPending = false; renderControls(); }
  }

  function bindEvents() {
    for (const button of document.querySelectorAll('[data-locale]')) button.addEventListener('click', () => loadLocalization(button.dataset.locale));
    $('dismiss-notice').addEventListener('click', () => { notice = null; renderNotice(); });
    $('wifi-from-nm').addEventListener('change', () => { $('password').value = ''; renderControls(); });
    for (const input of document.querySelectorAll('input')) input.addEventListener('input', () => input.removeAttribute('aria-invalid'));
    $('connect-form').addEventListener('submit', (event) => {
      event.preventDefault();
      const adapter = $('adapter').value.trim();
      void sendAction('connect', adapter ? { adapter } : {});
    });
    $('setup-form').addEventListener('submit', (event) => {
      event.preventDefault();
      const params = wifiParams();
      if (params) void sendAction('setup', params);
    });
    $('reboot-button').addEventListener('click', () => { void sendAction('reboot'); });
    $('attach-form').addEventListener('submit', (event) => {
      event.preventDefault();
      const ip = $('device-ip').value.trim();
      if (!validIpv4(ip)) { invalidInput('device-ip', 'tbInvalidIp'); return; }
      void sendAction('attach', { ip });
    });
    $('stream-button').addEventListener('click', () => { void sendAction('stream', { enabled: state?.phase !== 'streaming' }); });
    $('single-button').addEventListener('click', () => { void sendAction('single'); });
    $('flash-button').addEventListener('click', () => { void sendAction('flash', { enabled: !flashRequested }); });
    $('disconnect-button').addEventListener('click', () => { void sendAction('disconnect'); });
    $('cancel-button').addEventListener('click', () => { void sendAction('cancel'); });
    $('test-profile').addEventListener('change', renderControls);
    $('test-form').addEventListener('submit', (event) => {
      event.preventDefault();
      if ($('run-button').disabled) return;
      const profile = $('test-profile').value;
      if (!Object.hasOwn(PROFILES, profile)) return;
      if (PROFILES[profile].destructive) {
        confirmationProfile = profile;
        $('confirm-fresh').checked = false;
        $('confirm-configuration').checked = false;
        setText($('confirm-profile'), t(PROFILES[profile].label));
        renderControls();
        $('confirmation-dialog').showModal();
        $('close-confirmation').focus();
      } else void startTest(profile);
    });
    for (const id of ['confirm-fresh', 'confirm-configuration']) $(id).addEventListener('change', renderControls);
    for (const id of ['close-confirmation', 'cancel-confirmation']) $(id).addEventListener('click', closeConfirmation);
    $('confirmation-dialog').addEventListener('cancel', (event) => { event.preventDefault(); closeConfirmation(); });
    $('confirmation-form').addEventListener('submit', (event) => {
      event.preventDefault();
      if ($('confirm-run').disabled || !confirmationProfile) return;
      const profile = confirmationProfile;
      closeConfirmation();
      void startTest(profile, true);
    });
    $('view-report').addEventListener('click', () => { void fetchReport(false); });
    $('download-report').addEventListener('click', () => { void fetchReport(true); });
    $('close-report').addEventListener('click', () => { $('report-content').hidden = true; $('view-report').focus(); });
    window.addEventListener('pagehide', () => {
      stopped = true;
      window.clearTimeout(pollTimer);
      frameRequest?.abort();
      if (frameUrl) URL.revokeObjectURL(frameUrl);
      $('password').value = '';
      config = null;
    });
    window.addEventListener('pageshow', (event) => {
      if (event.persisted) {
        stopped = false;
        lastFrameSequence = null;
        frameUrl = null;
        displayedFrame = null;
        previewReady = false;
        void poll();
      }
    });
  }

  $('soak-duration').value = String(SETTINGS.defaultSoakSeconds);
  bindEvents();
  applyLocalization();
  void poll();
})();
