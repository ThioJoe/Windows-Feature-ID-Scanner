"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var Channel;
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
        function createCallbackMsg(context, funcName, result, iserror) {
            var msg = new CallbackMsg();
            msg.value.context = context;
            msg.value.result = (funcName === 'WinJS.xhr') ? { 'response': result.response, 'status': result.status } : result;
            msg.value.iserror = iserror;
            return msg;
        }
        Channel.createCallbackMsg = createCallbackMsg;
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
    class ContractHandler {
        constructor(rules) {
            this.rules = rules;
        }
        invokeFromString(callerUri, method, args) {
            try {
                this._verifyFunctionExists(method);
                this.checkIfPermissionAllowed(callerUri, method);
                return WinJS.Promise.as(this._executeFunctionByName(method, args, callerUri));
            }
            catch (e) {
                return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                    errorDispatch(e);
                });
            }
        }
        checkIfPermissionAllowed(callerUri, method) {
            var trimmedCallerUri = this._trimUri(callerUri);
            var isAllowed = false;
            var namespaces = method.split(".");
            for (var fn = ""; !isAllowed && namespaces.length > 0; namespaces.pop()) {
                var ns = namespaces.join('.') + fn;
                if (this.rules.hasOwnProperty(ns)) {
                    isAllowed = this._isAllowed(trimmedCallerUri, this.rules[ns]);
                }
                fn = ".*";
            }
            if (isAllowed === false) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NotAuthorizedApiAccess", JSON.stringify({
                    'callerUri': callerUri,
                    'trimmedCallerUri': trimmedCallerUri,
                    'method': method,
                    'isAllowed': isAllowed
                }));
                throw "NotAuthorizedApiAccess"; // Throw a string error instead of an Error object to avoid truncation in the callback layer
            }
        }
        _isAllowed(callerUri, allowedURIs) {
            var isAllowed = false;
            allowedURIs.forEach(function (uri) {
                if (uri === "*" || callerUri.toLowerCase() === uri.toLowerCase()) {
                    isAllowed = true;
                }
                else if (uri.lastIndexOf('*') === (uri.length - 1)) {
                    if (callerUri.toLowerCase().indexOf(uri.substr(0, uri.length - 1).toLowerCase(), 0) === 0) {
                        isAllowed = true;
                    }
                }
            });
            return isAllowed;
        }
        _trimUri(callerUri) {
            return callerUri.replace(/\/[^\/]+$/, "/"); // Remove the file name and parameters
        }
        _verifyFunctionExists(functionName) {
            let context = window;
            let namespaces = functionName.split(".");
            for (let i = 0; i < namespaces.length; i++) {
                context = context[namespaces[i]];
                if (context == null) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("ApiNonexistentOnClient", functionName);
                    throw "ApiNonexistentOnClient"; // Throw a string error instead of an Error object to avoid truncation in the callback layer
                }
            }
        }
        _executeFunctionByName(functionName, args, callerUri) {
            var context = window;
            var namespaces = functionName.split(".");
            var func = namespaces.pop();
            for (var i = 0; i < namespaces.length; i++) {
                context = context[namespaces[i]];
            }
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("PassCallerUriArgs")) {
                var instance = context[func];
                const metadata = instance.__metadata;
                if (metadata && metadata.requireCallerUri === true) {
                    args.unshift(callerUri);
                }
            }
            return context[func].apply(context, args);
        }
    }
    CloudExperienceHost.ContractHandler = ContractHandler;
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
        constructor(target, contractHandler) {
            this._target = null;
            this._connectedToTarget = false;
            this._contractHandler = null;
            this._listeners = null;
            this._callbackContext = null;
            this._scriptNotifyHandler = this._dispatchMessageFromScriptNotify.bind(this);
            this._maxPostDeadlockRetryCount = 5;
            this._listeners = new Object();
            this._callbackContext = new Object();
            if (target) {
                this._target = target;
            }
            if (contractHandler) {
                this._contractHandler = contractHandler;
            }
            this._initializeTarget();
        }
        _initializeTarget() {
            if (this._target) {
                this.connectToWebView();
            }
            else {
                window["CloudExperienceHost.Bridge.dispatchMessage"] = function (e) {
                    this._dispatchMessage(e);
                }.bind(this);
                window.addEventListener("error", this._onWebViewError.bind(this));
            }
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
            }
        }
        _windowExternalNotifyInternal(msg, retryCount) {
            setImmediate(() => {
                try {
                    window.external.notify(msg);
                    if (retryCount > 0) {
                        require(["legacy/telemetry"], (telemetry) => {
                            telemetry.AppTelemetry.getInstance().logCriticalEvent2("WebViewPossibleDeadlockAverted", JSON.stringify({
                                'retryCount': retryCount
                            }));
                        });
                    }
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
            if (this._target && this._target["invokeScriptAsync"]) {
                this._target["invokeScriptAsync"]("CloudExperienceHost.Bridge.dispatchMessage", msg).start();
            }
            else {
                this._windowExternalNotifyInternal(msg, 0);
            }
        }
        _invokeLocal(m) {
            let callerUri = this._target.src;
            this._contractHandler.invokeFromString(callerUri, m.value.name, m.value.args).done(function (result) {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("ValidateCallbackUri")) {
                    if (result instanceof CloudExperienceHost.BridgeHelpers.ResultMetadata) {
                        if (result.validateCallbackUri && (callerUri !== this._target.src)) {
                            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("CallbackUriValidationFailed", m.value.name);
                            return;
                        }
                        result = result.result;
                    }
                }
                if (m.value.context) {
                    this._callback(m, result, false);
                }
            }.bind(this), function (e) {
                if (m.value.context) {
                    this._callback(m, e, true);
                }
            }.bind(this));
        }
        _receivedEvent(e) {
            if (this._contractHandler && this._contractHandler.rules && this._contractHandler.rules.hasOwnProperty(e.value.name)) {
                this._contractHandler.checkIfPermissionAllowed(this._target.src, e.value.name);
            }
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
                this._callbackContext[m.value.context] = null;
                delete this._callbackContext[m.value.context];
            }
        }
        _dispatchMessageFromScriptNotify(notification) {
            this._dispatchMessage(notification.value);
        }
        _dispatchMessage(message) {
            var msg = Channel.parse(message);
            if (msg.type == Channel.MessageType.invoke) {
                this._invokeLocal(msg);
            }
            else if (msg.type == Channel.MessageType.event) {
                this._receivedEvent(msg);
            }
            else if (msg.type == Channel.MessageType.callback) {
                this._receivedResult(msg);
            }
        }
        _callback(m, result, iserror) {
            if (iserror && !!result && (typeof result.number === 'number')) {
                Object.defineProperty(result, 'number', { enumerable: true });
            }
            var msg = Channel.createCallbackMsg(m.value.context, m.value.name, result, iserror);
            this._postMessage(Channel.stringify(msg));
        }
        _permissionRequestedHandler(e) {
            if ((e.permissionRequest.type == "media") && CloudExperienceHostAPI.UtilStaticsCore.isWebcamPermissionAllowed(e.permissionRequest.uri)) {
                e.permissionRequest.allow();
            }
            else {
                e.permissionRequest.deny();
            }
        }
        invokeCallback(funcName, context, result, iserror) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                let msg = Channel.createInvokeMsg(funcName, null, context);
                this._callback(msg, result, iserror);
            }.bind(this));
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
                this._listeners[eventName][0] = listener;
            }
            else {
                this._listeners[eventName].push(listener);
            }
        }
        setContractHandler(contractHandler) {
            this._contractHandler = contractHandler;
        }
        disconnectFromWebView() {
            if (this._connectedToTarget) {
                this._target.removeEventListener("MSWebViewScriptNotify", this._scriptNotifyHandler);
                this._target.removeEventListener("MSWebViewPermissionRequested", this._permissionRequestedHandler);
                this._connectedToTarget = false;
            }
        }
        connectToWebView() {
            if (!this._connectedToTarget) {
                this._target.addEventListener("MSWebViewScriptNotify", this._scriptNotifyHandler);
                this._target.addEventListener("MSWebViewPermissionRequested", this._permissionRequestedHandler);
                this._connectedToTarget = true;
            }
        }
    }
    CloudExperienceHost.Bridge = Bridge;
})(CloudExperienceHost || (CloudExperienceHost = {}));
if ((typeof define === "function") && define.amd) {
    define(function () {
        return new CloudExperienceHost.Bridge();
    });
}
