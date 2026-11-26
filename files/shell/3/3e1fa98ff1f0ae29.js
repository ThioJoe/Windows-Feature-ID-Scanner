//
// Copyright (C) Microsoft. All rights reserved.
//
/// <disable>JS2085.EnableStrictMode</disable>
"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    let Channel;
    (function (Channel) {
        Channel.MessageType = {
            invoke: 'invoke',
            event: 'event',
            callback: 'callback',
        };
        class Message {
            constructor(t) {
                this.type = t;
                this.value = new Object;
            }
        }
        Channel.Message = Message;
        class EventMsg extends Message {
            constructor() {
                super(Channel.MessageType.event);
            }
        }
        Channel.EventMsg = EventMsg;
        class InvokeMsg extends Message {
            constructor() {
                super(Channel.MessageType.invoke);
            }
        }
        Channel.InvokeMsg = InvokeMsg;
        class CallbackMsg extends Message {
            constructor() {
                super(Channel.MessageType.callback);
            }
        }
        Channel.CallbackMsg = CallbackMsg;
        function createInvokeMsg(funcName, args, context) {
            var msg = new InvokeMsg();
            msg.value.name = funcName;
            msg.value.args = args;
            msg.value.context = context;
            return msg;
        }
        Channel.createInvokeMsg = createInvokeMsg;
        function createEventMsg(eventName, data) {
            var msg = new EventMsg();
            msg.value.name = eventName;
            if (data) {
                msg.value.data = data;
            }
            return msg;
        }
        Channel.createEventMsg = createEventMsg;
        function stringify(msg) {
            return JSON.stringify(msg);
        }
        Channel.stringify = stringify;
        function parse(msg) {
            var m = JSON.parse(msg);
            return m;
        }
        Channel.parse = parse;
    })(Channel || (Channel = {}));
    class CallbackContext {
        constructor(completeDispatch, errorDispatch) {
            this._completeDispatch = completeDispatch;
            this._errorDispatch = errorDispatch;
        }
        complete(result) {
            this._completeDispatch(result);
        }
        error(e) {
            this._errorDispatch(e);
        }
    }
    class Bridge {
        constructor() {
            this._listeners = null;
            this._callbackContext = null;
            this._maxPostDeadlockRetryCount = 5;
            this._listeners = new Object();
            this._callbackContext = new Object();
            this._initializeTarget();
        }
        _initializeTarget() {
            window["CloudExperienceHost.Bridge.dispatchMessage"] = function (e) {
                this._dispatchMessage(e);
            }.bind(this);
            window.addEventListener("error", this._onWebViewError.bind(this));
        }
        _onWebViewError(e) {
            try {
                let eventData = {
                    sourceUrl: window.location.href,
                    detail: {
                        lineno: e.lineno,
                        colno: e.colno,
                        filename: e.filename,
                        message: e.message,
                        error: e.error,
                        number: e.number,
                    },
                };
                this.fireEvent("CloudExperienceHost.unhandledException", eventData);
            }
            catch (ex) {
                // For now leave this as best effort.
                // In the future consider sending an event that tells us how often we fail to serialize here (if ever).
            }
        }
        _windowExternalNotifyInternal(msg, retryCount) {
            // http://osgvsowi/10958387 To avoid hitting a known edgehtml deadlock and having window.external.notify calls dropped
            // (the RS2 workaround for the deadlock in edgehtml), the Bridge component should never call window.external.notify synchronously.
            // In case we still hit the deadlock, we retry a set number of times and then bail out
            setTimeout(() => {
                try {
                    window.external.notify(msg);
                    // We log the count of retries to understand the distribution and change _maxPostDeadlockRetryCount in future if required
                    /*if (retryCount > 0) {
                        require(["legacy/telemetry"], (telemetry) => {
                            telemetry.AppTelemetry.getInstance().logCriticalEvent2("WebViewPossibleDeadlockAverted", JSON.stringify({
                                'retryCount': retryCount
                            }));
                        });
                    }*/
                }
                catch (e) {
                    if ((e.number == -2147023765 /* error: ERROR_POSSIBLE_DEADLOCK 0x8007046B */) && (retryCount < this._maxPostDeadlockRetryCount)) {
                        retryCount++;
                        this._windowExternalNotifyInternal(msg, retryCount);
                    }
                    else {
                        this._onWebViewError(e);
                    }
                }
            });
        }
        _postMessage(msg) {
            this._windowExternalNotifyInternal(msg, 0);
        }
        _receivedEvent(e) {
            var listeners = this._listeners[e.value.name];
            if (listeners) {
                listeners.map(function (listener) {
                    listener.call(this, e.value.data);
                }.bind(this));
            }
        }
        _receivedResult(m) {
            var callback = this._callbackContext[m.value.context];
            if (callback) {
                if (m.value.iserror) {
                    callback.error(m.value.result);
                }
                else {
                    callback.complete(m.value.result);
                }
                //Cleaning
                this._callbackContext[m.value.context] = null;
                delete this._callbackContext[m.value.context];
            }
        }
        _dispatchMessage(message) {
            var msg = Channel.parse(message);
            /*if (msg.type == Channel.MessageType.invoke) {
                this._invokeLocal(msg);
            } else */ if (msg.type == Channel.MessageType.event) {
                this._receivedEvent(msg);
            }
            else if (msg.type == Channel.MessageType.callback) {
                this._receivedResult(msg);
            }
        }
        invoke(funcName, arg1, arg2, arg3, arg4) {
            var args = Array.prototype.slice.call(arguments).splice(1);
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                var uniqueid = Math.random().toString(16).slice(2); // The random number generator is seeded automatically when JavaScript is first loaded.
                var context = funcName + '_' + uniqueid; // Create unique index 'funcName_12a47668b64f34'
                this._callbackContext[context] = new CallbackContext(completeDispatch, errorDispatch);
                var msg = Channel.createInvokeMsg(funcName, args, context);
                this._postMessage(Channel.stringify(msg));
            }.bind(this));
        }
        fireEvent(eventName, data) {
            var msg = Channel.createEventMsg(eventName, data);
            this._postMessage(Channel.stringify(msg));
        }
        addEventListener(eventName, listener) {
            if (!this._listeners.hasOwnProperty(eventName)) {
                this._listeners[eventName] = new Array();
            }
            if ((eventName === "CloudExperienceHost.backButtonClicked") && (this._listeners[eventName].length > 0)) {
                // MSA app adds a new event listener for every new panel, this causes multiple callbacks executed
                // when back button is clicked on. This is a scoped fix to ensure their pages are not broken.
                this._listeners[eventName][0] = listener;
            }
            else {
                this._listeners[eventName].push(listener);
            }
        }
    }
    CloudExperienceHost.Bridge = Bridge;
})(CloudExperienceHost || (CloudExperienceHost = {}));
// Expose bridge to be loaded by requirejs as a singleton object
if ((typeof define === "function") && define.amd) {
    define(function () {
        return new CloudExperienceHost.Bridge();
    });
}
//# sourceMappingURL=bridge.js.map