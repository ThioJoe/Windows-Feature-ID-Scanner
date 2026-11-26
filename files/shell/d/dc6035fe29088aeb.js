"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    var Telemetry;
    (function (Telemetry) {
        class AppTelemetry {
            constructor() {
                this._appActivity = null;
                this._appActivityRequired = null;
                if (!AppTelemetry._allowInstantiation) {
                    throw new Error("Error: Instantiation failed: Use getInstance() instead of new.");
                }
                this._appActivity = new Microsoft.CloudExperienceHost.AppActivity();
                this._appActivityRequired = new Microsoft.CloudExperienceHost.AppActivityRequired();
            }
            static getInstance() {
                if (AppTelemetry._instance === null) {
                    AppTelemetry._allowInstantiation = true;
                    AppTelemetry._instance = new AppTelemetry();
                    AppTelemetry._allowInstantiation = false;
                }
                return AppTelemetry._instance;
            }
            start(source, experience, correlationId) {
                this._appActivity.start(source, experience, correlationId);
                this._appActivityRequired.start(source, experience);
                try {
                    CloudExperienceHostAPI.EventLogging.appActivityStart(source, experience);
                }
                catch (e) {
                }
            }
            stop(appResult) {
                this._appActivity.stop(appResult);
                this._appActivityRequired.stop(appResult);
                try {
                    CloudExperienceHostAPI.EventLogging.appActivityStop(appResult);
                }
                catch (e) {
                }
            }
            expectedReboot() {
                this._appActivityRequired.expectedReboot();
            }
            getId() {
                return this._appActivity.getId();
            }
            appCheckpoint() {
                this._appActivity.appCheckpoint();
            }
            logCriticalEvent2(eventName, eventValue) {
                this._appActivity.logCriticalEvent2(eventName, eventValue);
                this._logEventInternal(eventName, eventValue);
            }
            logEvent(...params) {
                var func = "logEvent" + params.length;
                this._appActivity[func].apply(this._appActivity, params);
                if (params.length == 1) {
                    this._logEventInternal(params[0]);
                }
                else {
                    this._logEventInternal(params[0], params[1]);
                }
            }
            _logEventInternal(...params) {
                var func = "appEvent" + params.length;
                try {
                    CloudExperienceHostAPI.EventLogging[func].apply(undefined, params);
                }
                catch (e) {
                }
            }
            static logChromeEvent(...params) {
                var self = AppTelemetry.getInstance();
                var func = "logChromeEvent" + params.length;
                self._appActivity[func].apply(self._appActivity, params);
            }
        }
        AppTelemetry._instance = null;
        Telemetry.AppTelemetry = AppTelemetry;
        class WebAppTelemetry {
            constructor() {
                this._webAppActivity = null;
                if (!WebAppTelemetry._allowInstantiation) {
                    throw new Error("Error: Instantiation failed: Use getInstance() instead of new.");
                }
            }
            static getInstance() {
                if (WebAppTelemetry._instance === null) {
                    WebAppTelemetry._allowInstantiation = true;
                    WebAppTelemetry._instance = new WebAppTelemetry();
                    WebAppTelemetry._allowInstantiation = false;
                }
                return WebAppTelemetry._instance;
            }
            start(cxid, activityId) {
                if (this._webAppActivity) {
                    this.stop(CloudExperienceHost.AppResult.fail);
                }
                if (activityId) {
                    this._webAppActivity = new Microsoft.CloudExperienceHost.WebAppActivity(activityId);
                }
                else {
                    this._webAppActivity = new Microsoft.CloudExperienceHost.WebAppActivity(AppTelemetry.getInstance().getId());
                }
                this._webAppActivity.start(cxid);
                try {
                    CloudExperienceHostAPI.EventLogging.webAppActivityStart(cxid);
                }
                catch (e) {
                }
            }
            stop(appResult) {
                if (!this._webAppActivity) {
                    AppTelemetry.getInstance().logCriticalEvent2("NoActiveWebAppRunning", "StopCalled");
                    return;
                }
                this._webAppActivity.stop(appResult);
                this._webAppActivity = null;
                try {
                    CloudExperienceHostAPI.EventLogging.webAppActivityStop(appResult);
                }
                catch (e) {
                }
            }
            isStarted() {
                return (this._webAppActivity != null);
            }
            getId() {
                return this._webAppActivity.getId();
            }
            logUserInteractionEvent(...params) {
                this._logEventInternal("logUserInteractionEvent", params);
            }
            logEvent(...params) {
                this._logEventInternal("logEvent", params);
            }
            _logEventInternal(eventType, params) {
                if (!this._webAppActivity) {
                    AppTelemetry.getInstance().logCriticalEvent2("NoActiveWebAppRunning", JSON.stringify(params));
                    return;
                }
                var func = eventType + params.length;
                this._webAppActivity[func].apply(this._webAppActivity, params);
                func = "webAppEvent" + params.length;
                try {
                    CloudExperienceHostAPI.EventLogging[func].apply(undefined, params);
                }
                catch (e) {
                }
            }
        }
        WebAppTelemetry._instance = null;
        Telemetry.WebAppTelemetry = WebAppTelemetry;
        function getId() {
            return WebAppTelemetry.getInstance().getId();
        }
        Telemetry.getId = getId;
        function logEvent(...params) {
            var webAppTelemetry = WebAppTelemetry.getInstance();
            webAppTelemetry.logEvent.apply(webAppTelemetry, params);
        }
        Telemetry.logEvent = logEvent;
        function safeLogEvent(eventName, eventValue) {
            if (!eventName || typeof eventName !== "string") {
                throw Error("Cannot log an event without an event name or an event name of an invalid type.");
            }
            if (/\s/.test(eventName)) {
                throw Error("Event name cannot contain whitespace.");
            }
            if (eventValue == undefined) {
                logEvent(eventName);
            }
            else {
                logEvent(eventName, JSON.stringify(eventValue));
            }
        }
        Telemetry.safeLogEvent = safeLogEvent;
        function logUserInteractionEvent(...params) {
            var webAppTelemetry = WebAppTelemetry.getInstance();
            webAppTelemetry.logUserInteractionEvent.apply(webAppTelemetry, params);
        }
        Telemetry.logUserInteractionEvent = logUserInteractionEvent;
        function oobeHealthEvent(healthEvent, errorCode) {
            CloudExperienceHostAPI.EventLogging.oobeHealthEvent(healthEvent, errorCode);
        }
        Telemetry.oobeHealthEvent = oobeHealthEvent;
        function commitUserIntentAsync(intentKey, intentValue) {
            return CloudExperienceHostAPI.UserIntentRecordCore.setUserIntentAndTimestampAsync(intentKey, intentValue);
        }
        Telemetry.commitUserIntentAsync = commitUserIntentAsync;
        function commitIntentPropertyDWORDAsync(intentKey, intentProperty, intentPropertyValue) {
            return CloudExperienceHostAPI.UserIntentRecordCore.setIntentPropertyDWORDAsync(intentKey, intentProperty, intentPropertyValue);
        }
        Telemetry.commitIntentPropertyDWORDAsync = commitIntentPropertyDWORDAsync;
        function commitIntentPropertyBOOLAsync(intentKey, intentProperty, intentPropertyValue) {
            return CloudExperienceHostAPI.UserIntentRecordCore.setIntentPropertyDWORDAsync(intentKey, intentProperty, intentPropertyValue ? 1 : 0);
        }
        Telemetry.commitIntentPropertyBOOLAsync = commitIntentPropertyBOOLAsync;
        class IntentPropertyItem {
            constructor(intentProperty, intentPropertyValue) {
                this.intentProperty = intentProperty;
                this.intentPropertyValue = intentPropertyValue;
            }
        }
        Telemetry.IntentPropertyItem = IntentPropertyItem;
        function commitUserIntentAndIntentPropertyValuesAsync(intentKey, intentValue, intentPropertyDWORDArr, intentPropertyBOOLArr) {
            let setUserIntentAndTimestampPromise = commitUserIntentAsync(intentKey, intentValue);
            let setIntentPropertyDWORDPromises;
            setIntentPropertyDWORDPromises = (intentPropertyDWORDArr == null) ? new Array() : intentPropertyDWORDArr.map((intentPropertyItem) => {
                return commitIntentPropertyDWORDAsync(intentKey, intentPropertyItem.intentProperty, intentPropertyItem.intentPropertyValue);
            });
            let setIntentPropertyDWORDsPromise = WinJS.Promise.join(setIntentPropertyDWORDPromises);
            let setIntentPropertyBOOLPromises;
            setIntentPropertyBOOLPromises = (intentPropertyBOOLArr == null) ? new Array() : intentPropertyBOOLArr.map((intentPropertyItem) => {
                return commitIntentPropertyBOOLAsync(intentKey, intentPropertyItem.intentProperty, intentPropertyItem.intentPropertyValue);
            });
            let setIntentPropertyBOOLsPromise = WinJS.Promise.join(setIntentPropertyBOOLPromises);
            return WinJS.Promise.join({ setUserIntentAndTimestampPromise: setUserIntentAndTimestampPromise, setIntentPropertyDWORDsPromise: setIntentPropertyDWORDsPromise,
                setIntentPropertyBOOLsPromise: setIntentPropertyBOOLsPromise });
        }
        Telemetry.commitUserIntentAndIntentPropertyValuesAsync = commitUserIntentAndIntentPropertyValuesAsync;
        function commitUserIntentAndBuildAsync(intentKey, intentValue) {
            let intentPropertyDWORDArr = new Array();
            intentPropertyDWORDArr.push(new IntentPropertyItem("OSBuildNumber", CloudExperienceHostAPI.Environment.osVersionInfo.buildNumber));
            return commitUserIntentAndIntentPropertyValuesAsync(intentKey, intentValue, intentPropertyDWORDArr);
        }
        Telemetry.commitUserIntentAndBuildAsync = commitUserIntentAndBuildAsync;
        function tryGetIntentPropertyDWORDAsync(intentKey, intentProperty) {
            return CloudExperienceHostAPI.UserIntentRecordCore.tryGetIntentPropertyDWORDAsync(intentKey, intentProperty).then(function (result) {
                var userIntentRecordResultObj = {};
                userIntentRecordResultObj.succeeded = result.succeeded;
                userIntentRecordResultObj.value = result.value;
                return JSON.stringify(userIntentRecordResultObj);
            });
        }
        Telemetry.tryGetIntentPropertyDWORDAsync = tryGetIntentPropertyDWORDAsync;
        function setMachineFirstSignInSettingsAsync(experienceProperty, experiencePropertyValue) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch*/) {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("FirstSignInSettings")) {
                    CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setMachineFirstSignInSettingsAsyncStarted_propValue", JSON.stringify({ experienceProperty, experiencePropertyValue }));
                    CloudExperienceHostAPI.FirstSignInSettingsManagerStatics.setMachineFirstSignInSettingsAsync(experienceProperty, experiencePropertyValue).then(() => {
                        CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setMachineFirstSignInSettingsAsyncSucceeded");
                        completeDispatch();
                    }, (err) => {
                        CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setMachineFirstSignInSettingsAsyncFailure", CloudExperienceHost.GetJsonFromError(err));
                        errorDispatch(err);
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setMachineFirstSignInSettingsAsyncFailure", "ApiNonexistentOnClient");
                    errorDispatch("ApiNonexistentOnClient");
                }
            });
        }
        Telemetry.setMachineFirstSignInSettingsAsync = setMachineFirstSignInSettingsAsync;
        function setUserFirstSignInSettingsAsync(experienceProperty, experiencePropertyValue) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch*/) {
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("FirstSignInSettings")) {
                    CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setUserFirstSignInSettingsAsyncStarted_propValue", JSON.stringify({ experienceProperty, experiencePropertyValue }));
                    CloudExperienceHostAPI.FirstSignInSettingsManagerStatics.setUserFirstSignInSettingsAsync(experienceProperty, experiencePropertyValue).then(() => {
                        CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setUserFirstSignInSettingsAsyncSucceeded");
                        completeDispatch();
                    }, (err) => {
                        CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setUserFirstSignInSettingsAsyncFailure", CloudExperienceHost.GetJsonFromError(err));
                        errorDispatch(err);
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("FirstSignInSettings_setUserFirstSignInSettingsAsyncFailure", "ApiNonexistentOnClient");
                    errorDispatch("ApiNonexistentOnClient");
                }
            });
        }
        Telemetry.setUserFirstSignInSettingsAsync = setUserFirstSignInSettingsAsync;
    })(Telemetry = CloudExperienceHost.Telemetry || (CloudExperienceHost.Telemetry = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));
if ((typeof define === "function") && define.amd) {
    define(function () {
        return {
            AppTelemetry: CloudExperienceHost.Telemetry.AppTelemetry,
            WebAppResult: CloudExperienceHost.Telemetry.WebAppTelemetry
        };
    });
}
