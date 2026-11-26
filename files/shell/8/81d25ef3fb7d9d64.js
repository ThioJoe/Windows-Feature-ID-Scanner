"use strict";
// Copyright (C) Microsoft Corporation. All rights reserved.
// CommonJS shim for the Ookla bundle; installs a non-writable chrome.webview bridge before third-party code runs.
var module = { exports: {} };
var exports = module.exports;
(function () {
    if (!(window.chrome && window.chrome.webview &&
        typeof window.chrome.webview.postMessage === 'function')) {
        return;
    }
    var boundPostMessage = window.chrome.webview.postMessage.bind(window.chrome.webview);
    try {
        Object.defineProperty(window, '__safePostMessage', {
            value: function (msg) { boundPostMessage(msg); },
            writable: false, configurable: false, enumerable: false
        });
    }
    catch (e) {
        // Unreachable on the fresh global this runs on; defence in depth. Wrapped like the freezes
        // below because a refused assignment throws under strict mode and would skip them.
        try {
            window.__safePostMessage = function (msg) { boundPostMessage(msg); };
        }
        catch (e2) { }
    }
    try {
        Object.freeze(window.chrome.webview);
    }
    catch (e) { } // best-effort
    try {
        Object.freeze(window.chrome);
    }
    catch (e) { } // best-effort
})();
