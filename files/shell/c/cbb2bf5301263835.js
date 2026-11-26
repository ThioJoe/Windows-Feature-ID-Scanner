"use strict";
// Copyright (C) Microsoft Corporation. All rights reserved.
// Drives the Ookla Speedtest Web SDK 2.x headlessly and forwards normalized signals to native.
//
// Contract with SpeedTestInProcEngineHost:
//   IN:  window.__nativeConfig = { mode, apiKey, sdkBaseUrl }
//   OUT: chrome.webview.postMessage(JSON.stringify({ signal, ... })) via __safePostMessage.
//        Terminal signals set terminal:true so native can close the host.
//        Raw SDK speeds stay bytes/sec; *_Mbps siblings are added for UI and telemetry.
//
//   SDK callback args are flattened into those bodies:
//     onStarting({ guid })                 -> { signal, guid }
//     onProgress(stage, result, progress)  -> { signal, stage, speedMbps, progress, ... }
//     onStageFinished(stage, result)       -> { signal, stage, speedMbps, serverName, serverCountry, measuredServerCount, ... }
//     onError/onFailed(key, message, data) -> { signal, errorKey, errorMessage, errorData }
//     onStageFailed(errorData)             -> { signal, errorKey, errorMessage, errorData }
//
// SDK quirks native relies on: sortServers() may throw or reject; connection-class failures can
// surface only through onFailed; latency may arrive as an object rather than a number.
(function () {
    'use strict';
    var safePost = (typeof window.__safePostMessage === 'function')
        ? window.__safePostMessage
        : null;
    // The key appears in SDK error text across several fields; redacting the serialized form covers
    // all of them. Snapshotted so a later mutation of __nativeConfig cannot switch redaction off.
    // Best-effort only: any script in this document can call chrome.webview.postMessage directly and
    // never reach post(). Native validates and re-sanitizes on its own; it is the trust boundary.
    var apiKeySecret = (window.__nativeConfig && window.__nativeConfig.apiKey) || '';
    // Also matched URL-encoded: the key rides in api_key=... and reaches post() via SDK error text.
    var apiKeySecretEncoded = encodeURIComponent(apiKeySecret);
    function redactSecrets(json) {
        if (!apiKeySecret) {
            return json;
        }
        var redacted = json.split(apiKeySecret).join('[redacted]');
        if (apiKeySecretEncoded !== apiKeySecret) {
            redacted = redacted.split(apiKeySecretEncoded).join('[redacted]');
        }
        return redacted;
    }
    function post(obj) {
        if (!safePost) {
            return;
        }
        try {
            safePost(redactSecrets(JSON.stringify(obj)));
        }
        catch (e) {
            // Static payload so a serialization fault still reports something; a dead channel must
            // not unwind the shim.
            try {
                safePost('{"signal":"shim-error","where":"post","message":"stringify-failed"}');
            }
            catch (e2) { }
        }
    }
    // SDK exposes speed/bandwidth in bytes/sec; native UI and ISP plans use Mbps.
    // Add *_Mbps siblings without mutating raw fields to preserve telemetry and avoid double-conversion.
    function bpsToMbps(bps) {
        return (typeof bps === 'number' && isFinite(bps)) ? (bps * 8) / 1e6 : null;
    }
    function attachMbps(msg) {
        if (!msg) {
            return;
        }
        if (typeof msg.bandwidth === 'number') {
            msg.bandwidthMbps = bpsToMbps(msg.bandwidth);
        }
        if (typeof msg.speed === 'number') {
            msg.speedMbps = bpsToMbps(msg.speed);
        }
        if (msg.download && typeof msg.download === 'object') {
            if (typeof msg.download.bandwidth === 'number') {
                msg.download.bandwidthMbps = bpsToMbps(msg.download.bandwidth);
            }
            if (typeof msg.download.speed === 'number') {
                msg.download.speedMbps = bpsToMbps(msg.download.speed);
            }
        }
        if (msg.upload && typeof msg.upload === 'object') {
            if (typeof msg.upload.bandwidth === 'number') {
                msg.upload.bandwidthMbps = bpsToMbps(msg.upload.bandwidth);
            }
            if (typeof msg.upload.speed === 'number') {
                msg.upload.speedMbps = bpsToMbps(msg.upload.speed);
            }
        }
    }
    // SDK 2.x may emit latency as an object; native scans for a flat number, so collapse it.
    function flattenLatency(msg) {
        if (!msg || msg.latency === undefined || msg.latency === null) {
            return;
        }
        var lat = msg.latency;
        if (typeof lat === 'object') {
            var v = (typeof lat.iqm === 'number') ? lat.iqm
                : (typeof lat.min === 'number') ? lat.min
                    : (typeof lat.value === 'number') ? lat.value
                        : null;
            if (typeof v === 'number' && isFinite(v)) {
                msg.latency = v;
            }
            else {
                delete msg.latency;
            }
        }
    }
    var cfg = window.__nativeConfig || {};
    var mode = (cfg.mode || 'full').toLowerCase();
    var hasKey = !!(cfg.apiKey && cfg.apiKey.length > 0);
    // https to match the secure page; an http fallback would be blocked as mixed content.
    var sdkBaseUrl = cfg.sdkBaseUrl || 'https://windows.speedtestcustom.com';
    // Guarded with typeof so a failed engine-module-shim load posts a signal, not a ReferenceError.
    if (typeof module === 'undefined' || !module || !module.exports) {
        post({ signal: 'shim-error', where: 'sdk-load', message: 'module.exports missing' });
        return;
    }
    var sdk = module.exports;
    var EngineApi = sdk.EngineApi;
    if (!EngineApi) {
        post({ signal: 'shim-error', where: 'sdk-load',
            message: 'EngineApi missing from module.exports' });
        return;
    }
    post({ signal: 'sdk-loaded', hasEngineApi: typeof EngineApi === 'object' });
    if (mode === 'load-only') {
        return;
    }
    // Wire signals before configure/startTest; native consumes flattened positional args.
    // Stage signals use (stage, result?, progress?); onError/onFailed use (errorKey, errorMessage, errorData).
    var sortedServerCountryById = null;
    // Set once a terminal signal is seen: stopTest() throws if the engine already stopped.
    // Relies on native building a fresh host, and so a fresh context, per run.
    var runEnded = false;
    // Set on the first stop request: native issues one on cancel and another as the host is dropped.
    var stopRequested = false;
    // Aborts an in-flight run before the host is dropped; the SDK answers via onCanceled.
    // Non-writable for the same reason as the message bridge: third-party code shares this global.
    var nativeStopTest = function () {
        if (runEnded) {
            return;
        }
        var repeat = stopRequested;
        stopRequested = true;
        // Probed before use: a provider that dropped stopTest would otherwise report a stop failure.
        if (typeof EngineApi.stopTest !== 'function') {
            if (!repeat) {
                post({ signal: 'shim-warning', where: 'stop-test-missing', message: 'EngineApi.stopTest is not a function' });
            }
            return;
        }
        try {
            EngineApi.stopTest();
        }
        catch (e) {
            // A refusal after we already asked is the expected race, decided on our own state not the SDK text.
            if (!repeat) {
                post({ signal: 'shim-warning', where: 'stop-test', message: String(e && e.message) });
            }
        }
    };
    try {
        Object.defineProperty(window, '__nativeStopTest', {
            value: nativeStopTest, writable: false, configurable: false, enumerable: false
        });
    }
    catch (e) {
        // Not writable: an overwritable hook would let the bundle choose what native's stop request runs.
        post({ signal: 'shim-warning', where: 'stop-test-install', message: String(e && e.message) });
    }
    function wireGeneric(name, isTerminal, optional) {
        var sig = EngineApi[name];
        if (!sig || typeof sig.add !== 'function') {
            // Optional signals: absence is a provider SDK version, not a fault to attribute.
            if (!optional) {
                post({ signal: 'shim-warning', where: 'wire',
                    message: 'EngineApi.' + name + ' missing or not a Signal' });
            }
            return;
        }
        sig.add(function () {
            // Saving is bookkeeping; native consumes only measurement-stage lifecycle signals.
            if (arguments[0] === 'save' &&
                (name === 'onStageStarted' || name === 'onProgress' ||
                    name === 'onStageFinished' || name === 'onStageCanceled')) {
                return;
            }
            var msg = { signal: name };
            if (isTerminal) {
                runEnded = true;
            }
            if (arguments.length > 0) {
                var a0 = arguments[0];
                var a1 = arguments.length >= 2 ? arguments[1] : undefined;
                var a2 = arguments.length >= 3 ? arguments[2] : undefined;
                // SDK signals are not uniform, so each native-facing shape is mapped explicitly.
                if (name === 'onError') {
                    msg.errorKey = typeof a0 === 'string' ? a0 : null;
                    if (typeof a1 === 'string') {
                        msg.errorMessage = a1;
                    }
                    if (a2 !== undefined) {
                        msg.errorData = a2;
                    }
                }
                else if (name === 'onFailed') {
                    // SDK 2.x onFailed matches onError's 3-argument shape.
                    msg.errorKey = typeof a0 === 'string' ? a0 : null;
                    if (typeof a1 === 'string') {
                        msg.errorMessage = a1;
                    }
                    if (a2 !== undefined) {
                        msg.errorData = a2;
                    }
                }
                else if (name === 'onStageFailed') {
                    // SDK 2.x sends one errorData object; generic stage handling would drop it.
                    if (a0 && typeof a0 === 'object') {
                        msg.errorKey = a0.key || null;
                        msg.errorMessage = a0.message || null;
                        msg.errorData = a0;
                    }
                }
                else if (name === 'onStarting') {
                    // One object, {guid}; the generic path reads a0 as a stage and would drop it.
                    if (a0 && typeof a0 === 'object' && typeof a0.guid === 'string') {
                        msg.guid = a0.guid;
                    }
                }
                else if (name === 'onResultSaved') {
                    var savedId = (a0 && typeof a0 === 'object') ? a0.resultId : a0;
                    msg.resultId = typeof savedId === 'string' ? savedId : null;
                }
                else if (name === 'onServersSorted') {
                    // SDK 2.x wraps servers in {serverList}; accept bare arrays defensively.
                    var serverList = (a0 && Array.isArray(a0.serverList))
                        ? a0.serverList
                        : (Array.isArray(a0) ? a0 : []);
                    msg.totalServers = serverList.length;
                    // Country is pass-through from the server-list endpoint, not an SDK contract,
                    // so absence is normal.
                    sortedServerCountryById = {};
                    for (var i = 0; i < serverList.length; ++i) {
                        var sortedServer = serverList[i];
                        if (sortedServer && sortedServer.id !== undefined && sortedServer.id !== null) {
                            var country = sortedServer.cc || sortedServer.countryCode || sortedServer.country;
                            if (country) {
                                sortedServerCountryById[String(sortedServer.id)] = country;
                            }
                        }
                    }
                    // Downsample because engine stdout logging truncates around 4096 wchar; native only needs diagnostics.
                    msg.value = serverList.slice(0, 3).map(function (s) {
                        return s ? {
                            id: s.id,
                            name: s.name,
                            country: s.country,
                            sponsor: s.sponsor
                        } : null;
                    });
                }
                else if (name === 'onStageFinished') {
                    // servers[] arrives only on the throughput stages and names what actually
                    // moved bytes. Name, country and count are lifted out for the native detail
                    // trace; the raw array is dropped, taking coordinates, hostnames and ports.
                    if (typeof a0 === 'string') {
                        msg.stage = a0;
                    }
                    // The save stage nests servers[] inside testResult, below this exclusion.
                    if (a1 && typeof a1 === 'object' && a0 !== 'save') {
                        try {
                            for (var stageKey in a1) {
                                if (Object.prototype.hasOwnProperty.call(a1, stageKey) && stageKey !== 'servers') {
                                    msg[stageKey] = a1[stageKey];
                                }
                            }
                            var measured = (Array.isArray(a1.servers)) ? a1.servers : [];
                            if (measured.length > 0) {
                                var measuredServer = measured[0];
                                if (measuredServer && typeof measuredServer === 'object') {
                                    if (measuredServer.name) {
                                        msg.serverName = measuredServer.name;
                                    }
                                    if (measuredServer.id !== undefined && measuredServer.id !== null &&
                                        sortedServerCountryById) {
                                        var measuredCountry = sortedServerCountryById[String(measuredServer.id)];
                                        if (measuredCountry) {
                                            msg.serverCountry = measuredCountry;
                                        }
                                    }
                                }
                                // A future numServers change would otherwise surface only as a
                                // quietly wrong attribution.
                                msg.measuredServerCount = measured.length;
                            }
                        }
                        catch (e) {
                            msg.payloadError = String(e && e.message);
                        }
                    }
                    if (typeof a2 === 'number') {
                        msg.progress = a2;
                    }
                }
                else {
                    if (typeof a0 === 'string') {
                        msg.stage = a0;
                    }
                    if (a1 && typeof a1 === 'object') {
                        try {
                            for (var payloadKey in a1) {
                                // servers[] rides along on onProgress too.
                                if (Object.prototype.hasOwnProperty.call(a1, payloadKey) && payloadKey !== 'servers') {
                                    msg[payloadKey] = a1[payloadKey];
                                }
                            }
                        }
                        catch (e) {
                            msg.payloadError = String(e && e.message);
                        }
                    }
                    if (typeof a2 === 'number') {
                        msg.progress = a2;
                    }
                }
            }
            if (name === 'onResultSaved' && !msg.resultId) {
                post({ signal: 'shim-warning', where: 'result-save', message: 'missing-result-id' });
            }
            if (isTerminal) {
                msg.terminal = true;
            }
            attachMbps(msg);
            flattenLatency(msg);
            post(msg);
        });
    }
    wireGeneric('onServersSorted', false);
    wireGeneric('onStarting', false, true);
    wireGeneric('onStarted', false);
    wireGeneric('onStageStarted', false);
    wireGeneric('onProgress', false);
    wireGeneric('onStageFinished', false);
    // A failed save can still raise onResultSaved without an ID; onFinished ends the measurement.
    wireGeneric('onResultSaved', false);
    wireGeneric('onFinished', true);
    wireGeneric('onError', false); // not necessarily terminal
    wireGeneric('onStageFailed', false);
    wireGeneric('onStageCanceled', false);
    wireGeneric('onFailed', true);
    wireGeneric('onCanceled', true);
    // The SDK's save request has no timeout and onFinished waits for it; abort it after 5 s (harmless once done).
    var saveUrl = String(sdkBaseUrl).replace(/\/+$/, '') + '/report';
    var xhrOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        xhrOpen.apply(this, arguments);
        if (method === 'POST' && String(url).indexOf(saveUrl) === 0) {
            var save = this;
            setTimeout(function () { save.abort(); }, 5000);
        }
    };
    // Persist completed tests with the provider for result lookup and support correlation.
    // maxAttempts defaults to 1; 2 gives the server sort one retry, and more only lengthens startup.
    try {
        var engineOptions = {
            apiKey: cfg.apiKey || '',
            sdkBaseUrl: sdkBaseUrl,
            saveResults: true,
            stagesList: ['latency', 'download', 'upload', 'save'],
            serverSelection: { maxAttempts: 2 }
        };
        EngineApi.configure(engineOptions);
        post({ signal: 'configured', sdkBaseUrl: sdkBaseUrl, hasKey: hasKey, saveResults: engineOptions.saveResults, stagesList: engineOptions.stagesList,
            serverSelectionMaxAttempts: engineOptions.serverSelection.maxAttempts });
    }
    catch (e) {
        post({ signal: 'shim-error', where: 'configure',
            message: String(e && e.message) });
        return;
    }
    // Asks the provider directly rather than inferring a refusal from a failed discovery run.
    // advance() is in a finally on every path: it alone starts discovery.
    //
    // Retries only status 0: with no headers a CORS-stripped refusal is indistinguishable from
    // a transient DNS, TLS or proxy failure. Every other outcome is settled on the first attempt.
    var keyProbeMaxAttempts = 2;
    var keyProbeBudgetMs = 3000;
    function validateKeyThen(proceed) {
        var moved = false;
        var advance = function () { if (!moved) {
            moved = true;
            proceed();
        } };
        // attempt is 1-based; a throw here is caught below and always advances.
        function sendProbe(attempt) {
            try {
                var validateUrl = String(sdkBaseUrl).replace(/\/+$/, '') +
                    '/api/js/validate-api-key?api_key=' + encodeURIComponent(cfg.apiKey || '');
                var probe = new XMLHttpRequest();
                probe.open('GET', validateUrl, true);
                // Half the 3s budget per attempt, so one retry cannot double the pre-run wait.
                probe.timeout = keyProbeBudgetMs / keyProbeMaxAttempts;
                probe.onload = function () {
                    try {
                        if (probe.status >= 200 && probe.status <= 299) {
                            return;
                        }
                        // Provider's own fault, so the run proceeds and the SDK's attempts apply.
                        if (probe.status >= 500) {
                            post({ signal: 'shim-warning', where: 'api-key-validation', message: 'server-error' });
                            return;
                        }
                        // Only 4xx answers for this client; 1xx/3xx attribute nothing either way.
                        if (probe.status < 400) {
                            return;
                        }
                        post({ signal: 'provider-refused', where: 'onload', httpStatus: probe.status, terminal: true });
                    }
                    finally {
                        advance();
                    }
                };
                probe.onerror = function () {
                    // Status 0 with no headers, so a CORS-less refusal is indistinguishable from DNS
                    // or TLS failure. Only the 4xx path above can name the provider.
                    if (attempt < keyProbeMaxAttempts) {
                        // The retry owns advance(); a throw here must still release it.
                        try {
                            post({ signal: 'shim-warning', where: 'api-key-validation', message: 'unreachable-retrying' });
                            sendProbe(attempt + 1);
                        }
                        catch (e) {
                            advance();
                        }
                        return;
                    }
                    try {
                        post({ signal: 'provider-unreachable', where: 'onerror', httpStatus: 0, terminal: true });
                    }
                    finally {
                        advance();
                    }
                };
                probe.ontimeout = function () {
                    try {
                        // Says nothing either way; let the run proceed and fail on its own terms.
                        post({ signal: 'shim-warning', where: 'api-key-validation', message: 'timeout' });
                    }
                    finally {
                        advance();
                    }
                };
                probe.send();
            }
            catch (e) {
                try {
                    post({ signal: 'shim-warning', where: 'api-key-validation', message: 'probe-threw' });
                }
                finally {
                    advance();
                }
            }
        }
        sendProbe(1);
    }
    // Prewarm validates GDPR-safe SDK initialization without starting a test.
    if (mode === 'prewarm') {
        post({ signal: 'prewarm-complete' });
        return;
    }
    // Full mode uses sortServers -> onServersSorted -> startTest so native can distinguish fetch failures from test failures.
    var startedTest = false;
    function beginDiscovery() {
        try {
            EngineApi.onServersSorted.add(function (payload) {
                if (startedTest) {
                    return;
                }
                startedTest = true;
                // SDK 2.x wraps the selected list in payload.serverList.
                var servers = (payload && Array.isArray(payload.serverList))
                    ? payload.serverList
                    : (Array.isArray(payload) ? payload : []);
                if (servers.length === 0) {
                    post({ signal: 'shim-error', where: 'onServersSorted',
                        message: 'empty server list',
                        payloadShape: payload ? Object.keys(payload).join(',') : 'null' });
                    return;
                }
                try {
                    var result = EngineApi.startTest(servers);
                    post({ signal: 'test-started',
                        serverCount: servers.length });
                    if (result && typeof result.catch === 'function') {
                        result.catch(function (e) {
                            post({ signal: 'shim-error', where: 'startTest-async',
                                message: String(e && e.message),
                                code: (e && (e.code || e.key)) || null });
                        });
                    }
                }
                catch (e) {
                    post({ signal: 'shim-error', where: 'startTest',
                        message: String(e && e.message) });
                }
            });
            // sortServers() can throw synchronously or reject asynchronously; report both to native.
            var sortP = EngineApi.sortServers();
            post({ signal: 'sort-servers-issued' });
            if (sortP && typeof sortP.catch === 'function') {
                sortP.catch(function (e) {
                    post({ signal: 'shim-error', where: 'sortServers-async',
                        message: String(e && e.message),
                        code: (e && (e.code || e.key)) || null });
                });
            }
        }
        catch (e) {
            post({ signal: 'shim-error', where: 'sortServers',
                message: String(e && e.message) });
        }
    }
    validateKeyThen(beginDiscovery);
})();
