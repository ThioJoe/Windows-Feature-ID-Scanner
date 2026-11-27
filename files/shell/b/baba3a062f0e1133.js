"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class Context {
    }
    CloudExperienceHost.Context = Context;
    class WebViewNavigatable {
    }
    CloudExperienceHost.WebViewNavigatable = WebViewNavigatable;
    class InvokeAPIHelper {
        invokeByName(apiName, args) {
            var namespaces = apiName.split(".");
            var func = namespaces.pop();
            var context = this._accessByNamespaces(namespaces);
            return context[func].apply(context, args);
        }
        accessByName(name) {
            var namespaces = name.split(".");
            return this._accessByNamespaces(namespaces);
        }
        _accessByNamespaces(namespaces) {
            var context = window;
            for (var i = 0; i < namespaces.length; i++) {
                context = context[namespaces[i]];
            }
            return context;
        }
    }
    CloudExperienceHost.InvokeAPIHelper = InvokeAPIHelper;
    var PagePropertiesEnum;
    (function (PagePropertiesEnum) {
        PagePropertiesEnum[PagePropertiesEnum["FeatureId"] = 0] = "FeatureId";
        PagePropertiesEnum[PagePropertiesEnum["FallbackPage"] = 1] = "FallbackPage";
    })(PagePropertiesEnum || (PagePropertiesEnum = {}));
    ;
    var PreloadCheckObjNameEnum;
    (function (PreloadCheckObjNameEnum) {
        PreloadCheckObjNameEnum[PreloadCheckObjNameEnum["FeatureId"] = 0] = "FeatureId";
        PreloadCheckObjNameEnum[PreloadCheckObjNameEnum["FallbackObjName"] = 1] = "FallbackObjName";
    })(PreloadCheckObjNameEnum || (PreloadCheckObjNameEnum = {}));
    ;
    var BackNavigationStatus;
    (function (BackNavigationStatus) {
        BackNavigationStatus[BackNavigationStatus["Unknown"] = 0] = "Unknown";
        BackNavigationStatus[BackNavigationStatus["Disabled"] = 1] = "Disabled";
        BackNavigationStatus[BackNavigationStatus["Enabled"] = 2] = "Enabled";
    })(BackNavigationStatus || (BackNavigationStatus = {}));
    ;
    const aboutBlankURI = "about:blank";
    class Navigator {
        constructor(view, contractHandler, navManager) {
            this._visitedNodeStack = [];
            this._backNavigationStatusForNextTransition = BackNavigationStatus.Unknown;
            this._currentNavigationId = 0;
            this._redirectForPostTicketInterrupt = false;
            this._listeners = new Object;
            this._view = view;
            this._contractHandler = contractHandler;
            this._view.addEventListener("MSWebViewNavigationStarting", this._navigationStarting.bind(this));
            this._view.addEventListener("MSWebViewNavigationCompleted", this._navigationCompleted.bind(this));
            this._invokeHelper = new InvokeAPIHelper();
            this._navigatePromiseFunc = null;
            this._navManager = navManager;
            this._navManager.registerNavigator(this);
            this._navigationInterruptExpected = false;
            this._navigationTimerPromise = null;
            this._headersMap = new Map();
        }
        _fireEvent(errorName, e) {
            var listeners = this._listeners[errorName];
            if (listeners) {
                listeners.map(function (listener) {
                    listener.call(this, e);
                }.bind(this));
            }
        }
        _fireErrorEvent(e) {
            this._fireEvent("Error", e);
        }
        _topOfVisitedNodeStack() {
            if (this._visitedNodeStack.length == 0) {
                return "";
            }
            else {
                return this._visitedNodeStack[this._visitedNodeStack.length - 1].cxid;
            }
        }
        _clearVisitedNodeStack() {
            while (this._visitedNodeStack.length != 0) {
                this._visitedNodeStack.pop();
            }
        }
        _navigationStarting(e) {
            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AADPinResetV2")) {
                let convertMsAppxWebNavigationToPrivateData = this._navMesh.getConvertMsAppxWebNavigationToPrivateData();
                if (convertMsAppxWebNavigationToPrivateData !== undefined) {
                    let navUri = new Windows.Foundation.Uri(e.uri);
                    if ((navUri.schemeName === "ms-appx-web") && (navUri.host === convertMsAppxWebNavigationToPrivateData.hostToInterrupt)) {
                        let payload = (navUri.query !== "") ? navUri.query : navUri.fragment;
                        if ((convertMsAppxWebNavigationToPrivateData.privateKeyName !== undefined) && (payload !== "")) {
                            CloudExperienceHost.Storage.PrivateData.addItem(convertMsAppxWebNavigationToPrivateData.privateKeyName, payload);
                        }
                        e.preventDefault();
                        this.setNavigationInterruptExpected();
                        this._navigateToCurrentNode().done();
                        return;
                    }
                }
            }
            if (this._navMesh.getRestrictNavigationToAllowList() && (e.uri !== aboutBlankURI) && (this._currentNode.cxid !== this._navMesh.getErrorNodeName())) {
                let blockedNavOutstanding = (CloudExperienceHost.Storage.VolatileSharableData.getItem("NavigationAccessPolicyValues", "blockedNavigationInstanceOutstanding") === true); // boolify the result in case it was undefined
                if (blockedNavOutstanding) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationBlockedHandlingInProgress", JSON.stringify({
                        uri: CloudExperienceHost.UriHelper.RemovePIIFromUri(e.uri)
                    }));
                    e.preventDefault();
                }
                else if (!CloudExperienceHostAPI.UtilStaticsCore.isWebSignInNavigationAllowed(e.uri)) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationBlocked", JSON.stringify({
                        uri: CloudExperienceHost.UriHelper.RemovePIIFromUri(e.uri)
                    }));
                    e.preventDefault();
                    CloudExperienceHost.Storage.VolatileSharableData.addItem("NavigationAccessPolicyValues", "blockedNavigationInstanceOutstanding", true);
                    CloudExperienceHost.Storage.VolatileSharableData.addItem("NavigationAccessPolicyValues", "blockedNavigationUri", CloudExperienceHost.UriHelper.RemovePIIFromUri(e.uri));
                    let err = new WebViewNavigatable();
                    err.webErrorStatus = Windows.Web.WebErrorStatus.operationCanceled;
                    err.isSuccess = false;
                    err.uri = e.uri;
                    this._navigationCompleted(err);
                }
            }
        }
        _navigationCompleted(e) {
            this._stopNavigationTimer();
            if (e.uri == aboutBlankURI) {
                Debug.assert(this._clearWebViewCompletion, "_clearWebViewCompletion should be defined before navigating to about:blank");
                if (this._clearWebViewCompletion) {
                    let localClearWebViewCompletion = this._clearWebViewCompletion;
                    this._clearWebViewCompletion = null;
                    localClearWebViewCompletion();
                }
                return;
            }
            if (e.isSuccess === true) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationSucceed", JSON.stringify({
                    webErrorStatus: e.webErrorStatus,
                    uri: CloudExperienceHost.UriHelper.RemovePIIFromUri(e.uri)
                }));
                this._fireEvent("NavigationCompleted", this._currentNode);
                if (this._navMesh.isBackstackForBackNavigationSupported()) {
                    this._navManager.setWebAppBackNavigationAvailability(this._visitedNodeStack.length != 0);
                }
                this._navManager.setDisableBackNavigation(false);
                if (this._navMesh.isCloseToExitCxhSupported()) {
                    this._navManager.setExitCxhAvailability(true);
                }
            }
            else if (!this._navigationInterruptExpected) {
                this._redirectForPostTicketInterrupt = false; // Clear redirect state on navigation failure
                var hasInternetAccess = CloudExperienceHost.Environment.hasInternetAccess();
                var navigationBlocked = this._navMesh.getRestrictNavigationToAllowList() &&
                    (CloudExperienceHost.Storage.VolatileSharableData.getItem("NavigationAccessPolicyValues", "blockedNavigationInstanceOutstanding") === true); // boolify the result in case it was undefined
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationFailed", JSON.stringify({
                    webErrorStatus: e.webErrorStatus,
                    uri: CloudExperienceHost.UriHelper.RemovePIIFromUri(e.uri),
                    hasInternetAccess: hasInternetAccess,
                    isServerOffline: !navigationBlocked
                }));
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("IsNetworkConnected_NavigationFailed", hasInternetAccess);
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NetworkConnectivityLevel_NavigationFailed", CloudExperienceHost.Wireless.getConnectivityLevel());
                this.clearWebView();
                if (!navigationBlocked) {
                    let failedNavCxid = this._currentNode.cxid;
                    var offlineID = this._currentNode.offlineID;
                    let reconnectHandlerCxid = this.getNavMesh().getReconnectHandlerCxid();
                    if (reconnectHandlerCxid && this._isInplaceResumeNeeded()) {
                        CloudExperienceHost.Storage.VolatileSharableData.addItem("InPlaceResumeValues", "volatileResumeCxid", this._currentNode.cxid); // Store the resume cxid in memory
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("ReconnectHandled", reconnectHandlerCxid);
                        this._currentNode = this._navMesh.getNode(reconnectHandlerCxid);
                    }
                    else if (offlineID) {
                        this._currentNode = this._navMesh.getNode(offlineID);
                    }
                    try {
                        CloudExperienceHostAPI.UtilStaticsCore.indicateNetworkReprobe();
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("indicateNetworkReprobeSuccess");
                    }
                    catch (ex) {
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("indicateNetworkReprobeFailed", CloudExperienceHost.GetJsonFromError(ex));
                    }
                    if (this._currentNode && (this._currentNode.cxid !== failedNavCxid)) {
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.AppResult.fail);
                        this._navigateToCurrentNode().done();
                        return;
                    }
                }
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.AppResult.fail);
                this._fireErrorEvent(new CloudExperienceHost.NavigationError(e.webErrorStatus, e.uri, this._currentNode));
            }
            else {
                this._redirectForPostTicketInterrupt = false; // Clear redirect state on navigation failure
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("ExpectedNavigationInterruptOccurred");
            }
            this._navigationInterruptExpected = false;
        }
        _getEncoding() {
            var encoding = Windows.Storage.Streams.UnicodeEncoding.utf8;
            if (this._currentNode.encoding) {
                switch (this._currentNode.encoding.toLowerCase()) {
                    case "utf8":
                        encoding = Windows.Storage.Streams.UnicodeEncoding.utf8;
                        break;
                    case "utf16le":
                        encoding = Windows.Storage.Streams.UnicodeEncoding.utf16LE;
                        break;
                    case "utf16be":
                        encoding = Windows.Storage.Streams.UnicodeEncoding.utf16BE;
                        break;
                    default:
                        encoding = Windows.Storage.Streams.UnicodeEncoding.utf8;
                        break;
                }
            }
            return encoding;
        }
        _createHttpRequestMessage(httpMethod, url, queryString) {
            var qs = "";
            if (queryString) {
                if (url.indexOf('?') === -1) {
                    qs = '?';
                }
                else {
                    qs = '&';
                }
                qs = qs + queryString;
            }
            var uri = new Windows.Foundation.Uri(url + qs);
            return new Windows.Web.Http.HttpRequestMessage(httpMethod, uri);
        }
        _getQueryString() {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                if (this._currentNode.queryStringBuilder) {
                    this._contractHandler.invokeFromString(this.evaluateOverridableStringPropertyValue(this._currentNode.url, ""), this._currentNode.queryStringBuilder, null).then(function (result) {
                        completeDispatch(result);
                    }.bind(this), errorDispatch.bind(this));
                }
                else {
                    completeDispatch(null);
                }
            }.bind(this));
        }
        _appendHttpHeaderWithFallback(httpRequestMessage, name, value) {
            try {
                httpRequestMessage.headers.append(name, value);
            }
            catch (e) {
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("HeaderAppendFailure", CloudExperienceHost.GetJsonFromError(e));
                httpRequestMessage.headers.append(name, "???");
            }
        }
        _appendCustomHeaders(httpRequestMessage, contextHeaders) {
            this._appendHttpHeaderWithFallback(httpRequestMessage, "hostApp", "CloudExperienceHost");
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-hostAppVersion", CloudExperienceHost.getVersion().toString());
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-osVersionInfo", JSON.stringify(CloudExperienceHostAPI.Environment.osVersionInfo));
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-msaBinaryVersion", CloudExperienceHostAPI.Environment.msaBinaryVersion);
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-osPlatform", CloudExperienceHost.Environment.getPlatform());
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-preferredLanguage", CloudExperienceHost.Globalization.Language.getPreferredLang());
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-region", CloudExperienceHost.Globalization.GeographicRegion.getCode().toLowerCase());
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-isRTL", (CloudExperienceHost.Globalization.Language.getReadingDirection() === "rtl").toString());
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-cxid", this._currentNode.cxid);
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-identityClientBinaryVersion", CloudExperienceHostAPI.Environment.identityClientBinaryVersion);
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("Feature_ExpeditedUpdatePILess")) {
                this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-osRevision", JSON.stringify(CloudExperienceHostAPI.Environment.osRevision));
            }
            this._headersMap.forEach(function (item, key, mapObj) {
                this._appendHttpHeaderWithFallback(httpRequestMessage, key, item);
            }.bind(this));
            if (CloudExperienceHost.Environment.getPlatform() === CloudExperienceHost.TargetPlatform.DESKTOP) {
                var themeColors = CloudExperienceHost.Styling.getThemeColors();
                var cxhColors = "";
                Object.keys(themeColors).forEach(function (colorKey) {
                    cxhColors += colorKey + "=" + themeColors[colorKey] + ";";
                });
                this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-colors", cxhColors);
            }
            var context = CloudExperienceHost.getContext();
            for (var key in context) {
                if (context[key]) {
                    this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-" + key, context[key]);
                }
            }
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-tailoredExperiencesEnabled", CloudExperienceHostAPI.ContentDeliveryManagerHelpers.tailoredExperiencesEnabled.toString());
            let scenarioCustomHeaders = this._navMesh.getScenarioCustomHeaders();
            if (scenarioCustomHeaders.length > 0) {
                scenarioCustomHeaders = scenarioCustomHeaders.map(function (ele) { return ele.toLowerCase(); }); // Convert the custom headers array to lowercase for case-insensitive comparisons
                let daysSinceFirstLogonHeaderName = "cxh-daysSinceFirstLogon";
                if (scenarioCustomHeaders.indexOf(daysSinceFirstLogonHeaderName.toLowerCase()) > -1) {
                    let daysSinceFirstLogonRef = CloudExperienceHostAPI.UtilStaticsCore.daysSinceFirstLogon;
                    if (daysSinceFirstLogonRef != null) {
                        this._appendHttpHeaderWithFallback(httpRequestMessage, daysSinceFirstLogonHeaderName, daysSinceFirstLogonRef.toString());
                    }
                }
                let daysSinceFirstLogonOnCurrentInstallationHeaderName = "cxh-daysSinceFirstLogonOnCurrentInstallation";
                if (scenarioCustomHeaders.indexOf(daysSinceFirstLogonOnCurrentInstallationHeaderName.toLowerCase()) > -1) {
                    let daysSinceFirstLogonOnCurrentInstallationRef = CloudExperienceHostAPI.UtilStaticsCore.daysSinceFirstLogonOnCurrentInstallation;
                    if (daysSinceFirstLogonOnCurrentInstallationRef != null) {
                        this._appendHttpHeaderWithFallback(httpRequestMessage, daysSinceFirstLogonOnCurrentInstallationHeaderName, daysSinceFirstLogonOnCurrentInstallationRef.toString());
                    }
                }
                let oobeNetworkStateHeaderName = "cxh-oobeNetworkState";
                if (scenarioCustomHeaders.indexOf(oobeNetworkStateHeaderName.toLowerCase()) > -1) {
                    let oobeNetworkStateRef = CloudExperienceHostAPI.UtilStaticsCore.oobeNetworkState;
                    if (oobeNetworkStateRef != null) {
                        this._appendHttpHeaderWithFallback(httpRequestMessage, oobeNetworkStateHeaderName, oobeNetworkStateRef.toString());
                    }
                }
                let scoobeLaunchInstanceHeaderName = "cxh-scoobeLaunchInstance";
                if (scenarioCustomHeaders.indexOf(scoobeLaunchInstanceHeaderName.toLowerCase()) > -1) {
                    let scoobeLaunchInstanceObj = CloudExperienceHost.ScoobeContextHelper.tryGetScoobeLaunchInstance();
                    if (scoobeLaunchInstanceObj.succeeded) {
                        this._appendHttpHeaderWithFallback(httpRequestMessage, scoobeLaunchInstanceHeaderName, scoobeLaunchInstanceObj.scoobeLaunchInstance.toString());
                    }
                }
            }
            this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-intraWebAppVisibility", (this._currentNode.intraWebAppVisibility == null) ? "true" : this._currentNode.intraWebAppVisibility.toString());
            if (this._currentNode.needCustomHeaders) {
                let perNodeCustomHeaders = this._currentNode.needCustomHeaders.map(function (ele) { return ele.toLowerCase(); }); // Convert the custom headers array to lowercase for case-insensitive comparisons
                let windowsProductKeyHeaderName = "cxh-windowsProductKey";
                if (perNodeCustomHeaders.indexOf(windowsProductKeyHeaderName.toLowerCase()) > -1) {
                    this._appendHttpHeaderWithFallback(httpRequestMessage, windowsProductKeyHeaderName, CloudExperienceHostAPI.UtilStaticsCore.productActivationId);
                }
                let windowsProductKeyFiveByFiveHeaderName = "cxh-windowsProductKeyFiveByFive";
                if (perNodeCustomHeaders.indexOf(windowsProductKeyFiveByFiveHeaderName.toLowerCase()) > -1) {
                    this._appendHttpHeaderWithFallback(httpRequestMessage, windowsProductKeyFiveByFiveHeaderName, CloudExperienceHostAPI.UtilStaticsCore.windowsProductKey);
                }
                let windowsTelemetryLevelHeaderName = "cxh-windowsTelemetryLevel";
                if (perNodeCustomHeaders.indexOf(windowsTelemetryLevelHeaderName.toLowerCase()) > -1) {
                    this._appendHttpHeaderWithFallback(httpRequestMessage, windowsTelemetryLevelHeaderName, CloudExperienceHostAPI.OobeSettingsManagerStaticsCore.getTelemetryLevel().toString());
                }
            }
            if (CloudExperienceHost.Telemetry.WebAppTelemetry != null) {
                this._appendHttpHeaderWithFallback(httpRequestMessage, "client-request-id", CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().getId());
                this._appendHttpHeaderWithFallback(httpRequestMessage, "cxh-correlationId", CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().getId());
            }
            if (typeof (contextHeaders) !== 'undefined' && contextHeaders !== null) {
                for (var iterator = contextHeaders.first(); iterator.hasCurrent; iterator.moveNext()) {
                    if (!httpRequestMessage.headers.hasKey(iterator.current.key)) {
                        this._appendHttpHeaderWithFallback(httpRequestMessage, iterator.current.key, iterator.current.value);
                    }
                }
            }
        }
        _addDataToRequest(httpRequestMessage, key, value) {
            if (httpRequestMessage.method === Windows.Web.Http.HttpMethod.get) {
                if (!key) {
                    throw new CloudExperienceHost.InvalidArgumentError("key cannot be empty for GET request");
                }
                this._appendHttpHeaderWithFallback(httpRequestMessage, key, value);
            }
            else {
                var content = !!key ? (key + "=" + value) : value;
                var contentType = this._currentNode.contentType || "application/x-www-form-urlencoded";
                httpRequestMessage.content = new Windows.Web.Http.HttpStringContent(content, this._getEncoding(), contentType);
            }
        }
        _initializeRequest(httpRequestMessage) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                this._appendCustomHeaders(httpRequestMessage);
                if (this._currentNode.initialize) {
                    this._contractHandler.invokeFromString(this.evaluateOverridableStringPropertyValue(this._currentNode.url, ""), this._currentNode.initialize.getData, null).then(function (result) {
                        if (result !== null && result !== "") {
                            this._addDataToRequest(httpRequestMessage, this._currentNode.initialize.key, result);
                        }
                        completeDispatch(httpRequestMessage);
                    }.bind(this), errorDispatch.bind(this));
                }
                else {
                    completeDispatch(httpRequestMessage);
                }
            }.bind(this));
        }
        _startLauncher(LauncherClass, completeDispatch) {
            try {
                let launcherInstance = new LauncherClass();
                let expectedCurrentCxid = this._currentNode.cxid;
                let expectedNavigationId = this._currentNavigationId;
                if (launcherInstance.launchAsyncWithNavigationCompletedCallback) {
                    var launcherNavigationCompletedFunc = function (e) {
                        this._navigationCompleted(e);
                    }.bind(this);
                    var launchArguments = null;
                    if (this._currentNode.hostedApplicationLaunchArguments) {
                        launchArguments = this._invokeHelper.invokeByName(this._currentNode.hostedApplicationLaunchArguments, null);
                        this._clearVisitedNodeStack();
                    }
                    launcherInstance.launchAsyncWithNavigationCompletedCallback(this._currentNode, launchArguments, launcherNavigationCompletedFunc).done((appResult) => {
                        if (this._currentNavigationId === expectedNavigationId) {
                            this._fireEvent("Done", appResult);
                        }
                        else {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("LauncherLateNavigationIgnored", JSON.stringify({
                                launcherCxid: expectedCurrentCxid, currentCxid: this._currentNode.cxid,
                                expectedNavigationId: expectedNavigationId, currentNavigationId: this._currentNavigationId
                            }));
                        }
                    });
                }
                else {
                    this._fireEvent("NavigationCompleted", this._currentNode);
                    launcherInstance.launchAsync(this._currentNode).done((appResult) => {
                        if (this._currentNavigationId === expectedNavigationId) {
                            this._fireEvent("Done", appResult);
                        }
                        else {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("LauncherLateNavigationIgnored", JSON.stringify({
                                launcherCxid: expectedCurrentCxid, currentCxid: this._currentNode.cxid,
                                expectedNavigationId: expectedNavigationId, currentNavigationId: this._currentNavigationId
                            }));
                        }
                    });
                }
                completeDispatch();
            }
            catch (e) {
                completeDispatch();
                this._fireEvent("Done", CloudExperienceHost.AppResult.fail);
            }
        }
        _startNavigationTimer() {
            let timeout = 90000; // 90 seconds
            if (this._currentNode.navigationTimeout) {
                timeout = this._currentNode.navigationTimeout;
            }
            this._stopNavigationTimer();
            this._navigationTimerPromise = WinJS.Promise.timeout(timeout).then(() => {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationTimedout");
                this._view.stop();
                let e = new WebViewNavigatable();
                e.webErrorStatus = Windows.Web.WebErrorStatus.timeout;
                e.isSuccess = false;
                e.uri = this.evaluateOverridableStringPropertyValue(this._currentNode.url, "");
                this._navigationCompleted(e);
            }, (err) => {
                Debug.log(err);
            });
        }
        _stopNavigationTimer() {
            if (this._navigationTimerPromise) {
                this._navigationTimerPromise.cancel();
                this._navigationTimerPromise = null;
            }
        }
        _navigatePromiseImpl(completeDispatch, errorDispatch) {
            if (this._currentNode == null) {
                this._fireEvent("Done", CloudExperienceHost.AppResult.success);
            }
            else if (this._currentNode && this._currentNode.launcher) {
                this._fireEvent("NavigationStarting", this._currentNode);
                this.navigateByLauncher(this._currentNode.launcher, completeDispatch);
            }
            else {
                this._fireEvent("NavigationStarting", this._currentNode);
                this._nextNode = null;
                this._getQueryString()
                    .then(function (qs) {
                    var httpMethod = ((this._currentNode.httpMethod === 'post') ? Windows.Web.Http.HttpMethod.post : Windows.Web.Http.HttpMethod.get);
                    var targetUri = this.evaluateOverridableStringPropertyValue(this._currentNode.url, "");
                    if (this._currentNode.urlPathParam) {
                        var pathParamName = this._currentNode.urlPathParam;
                        var fragment = this._navMesh.getUriArguments().getFirstValueByName(pathParamName); // throws if not exists
                        var winUri = new Windows.Foundation.Uri(targetUri, fragment);
                        targetUri = winUri.absoluteCanonicalUri;
                    }
                    return this._createHttpRequestMessage(httpMethod, targetUri, qs);
                }.bind(this))
                    .then(function (httpRequestMessage) {
                    return this._initializeRequest(httpRequestMessage);
                }.bind(this))
                    .then(function (httpRequestMessage) {
                    var allowlist = [
                        'requestUri',
                        'method',
                        'headers',
                        'cxh-osVersionInfo',
                        'platformId',
                        'majorVersion',
                        'minorVersion',
                        'buildNumber',
                        'cxh-msaBinaryVersion',
                        'hostApp',
                        'client-request-id',
                        'cxh-protocol',
                        'cxh-cxid',
                        'cxh-preferredLanguage',
                        'cxh-region',
                        'cxh-identityClientBinaryVersion',
                        'cxh-correlationId',
                        'cxh-machineModel',
                        'cxh-manufacturer',
                        'cxh-osPlatform',
                        'cxh-personality',
                        'cxh-platform',
                        'cxh-deviceForm',
                        'cxh-windowsProductId',
                        'cxh-edition',
                        'cxh-isRTL',
                        'cxh-colors',
                        'cxh-host',
                        'cxh-hostAppVersion',
                        'cxh-capabilities',
                        'cxh-launchSurface',
                        'cxh-windowsTelemetryLevel',
                        'cxh-windowsFlightData',
                        'cxh-tailoredExperiencesEnabled',
                        'cxh-daysSinceFirstLogon',
                        'cxh-daysSinceFirstLogonOnCurrentInstallation',
                        'cxh-oobeNetworkState',
                        'cxh-scoobeLaunchInstance',
                        'cxh-intraWebAppVisibility',
                        'cxh-osRevision'
                    ];
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationStarted", JSON.stringify({
                        requestUri: httpRequestMessage.requestUri, method: httpRequestMessage.method, headers: httpRequestMessage.headers
                    }, allowlist));
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("IsNetworkConnected_NavigationStarted", CloudExperienceHost.Environment.hasInternetAccess());
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NetworkConnectivityLevel_NavigationStarted", CloudExperienceHost.Wireless.getConnectivityLevel());
                    this._startNavigationTimer();
                    this._view.navigateWithHttpRequestMessage(httpRequestMessage);
                    completeDispatch();
                }.bind(this))
                    .then(null, function (err) {
                    this._fireErrorEvent(new CloudExperienceHost.NavigationError(err.number, this.evaluateOverridableStringPropertyValue(this._currentNode.url, ""), this._currentNode, "An error occurred preparing to navigate to node '" + this._currentNode.cxid + "': " + err.message));
                    completeDispatch();
                }.bind(this));
            }
        }
        _getSignInIdentityProviderShortName() {
            let name = "none";
            switch (CloudExperienceHost.IUserManager.getInstance().getSignInIdentityProvider()) {
                case CloudExperienceHostAPI.SignInIdentityProviders.local:
                    name = "local";
                    break;
                case CloudExperienceHostAPI.SignInIdentityProviders.msa:
                    name = "msa";
                    break;
                case CloudExperienceHostAPI.SignInIdentityProviders.aad:
                    name = "aad";
                    break;
                default:
                    break;
            }
            return name;
        }
        _isSignInIdentityProviderInList(providerList) {
            let result = false;
            let providerName = this._getSignInIdentityProviderShortName();
            for (let i = 0; !result && (i < providerList.length); i++) {
                result = (providerName === providerList[i].toLowerCase());
            }
            return result;
        }
        _navigateToCurrentNode() {
            this._stopNavigationTimer();
            if (!this._navigationInterruptExpected) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().start(this._currentNode ? this._currentNode.cxid : "null");
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("IsNetworkConnected_WebAppActivityStarted", CloudExperienceHost.Environment.hasInternetAccess());
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NetworkConnectivityLevel_WebAppActivityStarted", CloudExperienceHost.Wireless.getConnectivityLevel());
            }
            this._currentNavigationId++;
            var navigatePromiseFunc = this._navigatePromiseFunc ? this._navigatePromiseFunc : this._navigatePromiseImpl.bind(this);
            if (this._currentNode) {
                let skipPromise = WinJS.Promise.as(false);
                var appResult = CloudExperienceHost.AppResult.success;
                try {
                    let skip = false;
                    let skipListJson = CloudExperienceHost.Storage.SharableData.getValue("skipList_" + CloudExperienceHost.getContext().experienceName);
                    if (skipListJson) {
                        let skipList = JSON.parse(skipListJson);
                        if (Array.isArray(skipList)) {
                            skipList.forEach(function (skipCxid) {
                                if (this._currentNode.cxid && (typeof (skipCxid) === "string") && (skipCxid.toLowerCase() === this._currentNode.cxid.toLowerCase())) {
                                    skip = true;
                                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("DisabledBySkipList", this._currentNode.cxid);
                                }
                            });
                        }
                    }
                    if (!skip && (this._currentNode.requiredFeatureName && !CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled(this._currentNode.requiredFeatureName))) {
                        skip = true;
                    }
                    if (!skip && (this._currentNode.requiredDisabledFeatureName && CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled(this._currentNode.requiredDisabledFeatureName))) {
                        skip = true;
                    }
                    if (!skip && this._currentNode.supportedSignInIdentityProviders) {
                        skip = !this._isSignInIdentityProviderInList(this._currentNode.supportedSignInIdentityProviders);
                    }
                    if (!skip && (this._currentNode.internetRequired && !CloudExperienceHost.Environment.hasInternetAccess())) {
                        let reconnectHandlerCxid = this.getNavMesh().getReconnectHandlerCxid();
                        if (reconnectHandlerCxid && this._isInplaceResumeNeeded()) {
                            CloudExperienceHost.Storage.VolatileSharableData.addItem("InPlaceResumeValues", "volatileResumeCxid", this._currentNode.cxid); // Store the resume cxid in memory
                            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("ReconnectHandled", reconnectHandlerCxid);
                            appResult = reconnectHandlerCxid;
                        }
                        else {
                            appResult = CloudExperienceHost.AppResult.offline;
                        }
                        skip = true;
                    }
                    if (!skip && this._currentNode.preloadCheck) {
                        let skipInterface = this._invokeHelper.accessByName(this._currentNode.preloadCheck);
                        if (skipInterface.getShouldSkipAsync) {
                            Debug.assert(skipInterface.shouldSkip === undefined, "Preload interface should only specify one of shouldSkip or shouldSkipAsync");
                            skipPromise = skipInterface.getShouldSkipAsync();
                        }
                        else if (skipInterface.shouldSkip !== undefined) {
                            skipPromise = WinJS.Promise.as(skipInterface.shouldSkip);
                        }
                        else {
                            Debug.break("Invalid preloadCheck value provided");
                        }
                    }
                    else {
                        skipPromise = WinJS.Promise.as(skip);
                    }
                }
                catch (e) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PreloadCheckError", JSON.stringify({ cxid: this._currentNode.cxid, preloadCheck: this._currentNode.preloadCheck, error: CloudExperienceHost.GetJsonFromError(e) }));
                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("PreloadCheckErrorHandling")) {
                        skipPromise = WinJS.Promise.as(!!this._currentNode.preloadCheckSkipOnFailure);
                    }
                }
                skipPromise = skipPromise.then(null, (e) => {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PreloadCheckAsyncError", JSON.stringify({ cxid: this._currentNode.cxid, preloadCheck: this._currentNode.preloadCheck, error: CloudExperienceHost.GetJsonFromError(e) }));
                    return WinJS.Promise.as(!!this._currentNode.preloadCheckSkipOnFailure);
                });
                return skipPromise.then((skip) => {
                    if (skip === true) {
                        if (this.evaluateOverridableBooleanPropertyValue(this._currentNode.disableBackNavigationToNode, false)) {
                            this._clearVisitedNodeStack();
                        }
                        if (this._currentNode.preloadSkipID && (appResult != CloudExperienceHost.AppResult.offline)) {
                            appResult = CloudExperienceHost.AppResult.preloadSkip;
                        }
                        if (this._navMesh.blockEarlyExit() && this._currentNode.canExitCxh && this._currentNode.skipExitsCxh) {
                            appResult = CloudExperienceHost.AppResult.exitCxhSuccess;
                        }
                        this._nextNode = this._getNext(appResult);
                        if (this._nextNode) {
                            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(appResult);
                            this._currentNode = this._nextNode;
                            this._resumeNode = this._currentNode;
                            this._navigateToCurrentNode().done();
                        }
                        else {
                            this._fireEvent("Done", appResult);
                        }
                    }
                    else {
                        this._clearBackstackIfReturnFromCurrentNodeDisallowed();
                        return new WinJS.Promise(navigatePromiseFunc);
                    }
                });
            }
            else {
                this._clearBackstackIfReturnFromCurrentNodeDisallowed();
                return new WinJS.Promise(navigatePromiseFunc);
            }
        }
        _getNext(appResult) {
            var node;
            if (this._currentNode) {
                switch (appResult) {
                    case CloudExperienceHost.AppResult.success:
                        node = this._navMesh.getNode(this._currentNode.successID);
                        if (this._currentNode.disableBackNavigationToNodeOnSuccess &&
                            (this._backNavigationStatusForNextTransition !== BackNavigationStatus.Unknown)) {
                            this._backNavigationStatusForNextTransition = BackNavigationStatus.Disabled;
                        }
                        if (this._navMesh.checkpointsEnabled() && this._currentNode.checkpointOnSuccess) {
                            CloudExperienceHost.Storage.SharableData.addValue("resumeCXHId", this._currentNode.successID);
                        }
                        break;
                    case CloudExperienceHost.AppResult.fail:
                        node = this._navMesh.getNode(this._currentNode.failID);
                        break;
                    case CloudExperienceHost.AppResult.error:
                        if (this._currentNode.disableErrorPageOnFailure && this._currentNode.failID) {
                            node = this._navMesh.getNode(this._currentNode.failID);
                        }
                        else {
                            node = this._navMesh.getErrorNode();
                        }
                        break;
                    case CloudExperienceHost.AppResult.cancel:
                        node = this._navMesh.getNode(this._currentNode.cancelID);
                        break;
                    case CloudExperienceHost.AppResult.abort:
                        node = this._navMesh.getNode(this._currentNode.abortID);
                        break;
                    case CloudExperienceHost.AppResult.offline:
                        node = this._navMesh.getNode(this._currentNode.offlineID);
                        break;
                    case CloudExperienceHost.AppResult.preloadSkip:
                        node = this._navMesh.getNode(this._currentNode.preloadSkipID);
                        break;
                    case CloudExperienceHost.AppResult.action1:
                        node = this._navMesh.getNode(this._currentNode.action1ID);
                        break;
                    case CloudExperienceHost.AppResult.action2:
                        node = this._navMesh.getNode(this._currentNode.action2ID);
                        break;
                    case CloudExperienceHost.AppResult.action3:
                        node = this._navMesh.getNode(this._currentNode.action3ID);
                        break;
                    case CloudExperienceHost.AppResult.exitCxhFailure:
                    case CloudExperienceHost.AppResult.exitCxhSuccess:
                        node = this._navMesh.getNode(this._currentNode.exitID);
                        break;
                    default:
                        {
                            node = this._navMesh.getNode(appResult);
                            if (!node) {
                                node = this._navMesh.getNode(this._currentNode.failID);
                            }
                            break;
                        }
                }
            }
            return node;
        }
        _clearBackstackIfReturnFromCurrentNodeDisallowed() {
            if (this._currentNode && this._currentNode.disableBackNavigationFromNode) {
                this._clearVisitedNodeStack();
            }
        }
        _isInplaceResumeNeeded() {
            if (this._currentNode.skipReconnectHandler) {
                return false;
            }
            if (CloudExperienceHostAPI.UtilStaticsCore.hideWireless) {
                return false;
            }
            if (CloudExperienceHostAPI.UtilStaticsCore.getLicensingPolicyValue("OOBE-Reconnect-Network") == 1) {
                return true;
            }
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeNetworkReconnect")) {
                if (CloudExperienceHost.Storage.SharableData.getValue("retailDemoEnabled") || !CloudExperienceHostAPI.UtilStaticsCore.disabledSkipNetwork) {
                    return false;
                }
                let reconnectLimit = 5; // Default to 5 to align with number of CXH/Explorer crashes before we go to recovery OOBE
                let variantObj = CloudExperienceHost.FeatureStaging.tryGetFeatureVariant("OobeNetworkReconnect");
                if (variantObj.result && (variantObj.value == "UseCustomReconnectLimit")) {
                    let variantDataObj = CloudExperienceHost.FeatureStaging.tryGetFeatureVariantData("OobeNetworkReconnect");
                    if (variantDataObj.result) {
                        reconnectLimit = variantDataObj.value;
                    }
                }
                let reconnectionHandledCount = CloudExperienceHost.Storage.VolatileSharableData.getItem("InPlaceResumeValues", "reconnectionHandledCount");
                reconnectionHandledCount = reconnectionHandledCount ? reconnectionHandledCount : 0;
                if (reconnectionHandledCount < reconnectLimit) {
                    return true;
                }
                else {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("ReconnectLimitReached", reconnectLimit.toString());
                    return false;
                }
            }
            return false;
        }
        navigateByLauncher(launcher, completeDispatch) {
            try {
                var launcherStrings = launcher.split(":");
                var launcherType = launcherStrings[0];
                var launcherName = launcherStrings[1];
                switch (launcherType) {
                    case "winrt":
                        {
                            this._startLauncher(AppObjectFactory.getInstance().getObjectFromString(launcherName), completeDispatch);
                            break;
                        }
                    case "js":
                        {
                            require(["appLaunchers/" + launcherName], (LauncherClass) => {
                                this._startLauncher(LauncherClass, completeDispatch);
                            });
                            break;
                        }
                }
            }
            catch (e) {
                completeDispatch();
                this._fireEvent("Done", CloudExperienceHost.AppResult.fail);
            }
        }
        getCurrentNode() {
            return this._currentNode;
        }
        getDiagnosticsNode() {
            return this._navMesh.getDiagnosticsNode();
        }
        setNavigatePromiseFunc(func) {
            this._navigatePromiseFunc = func;
        }
        addEventListener(type, listener) {
            if (!this._listeners.hasOwnProperty(type)) {
                this._listeners[type] = new Array();
            }
            this._listeners[type].push(listener);
        }
        setHeaderParams(headerParams) {
            let headerString = headerParams.split(',');
            for (let i = 0; i < headerString.length; i++) {
                let headers = headerString[i].split('|');
                this._headersMap.set(headers[0], headers[1]);
            }
        }
        navigate(navMesh, experience, cxid) {
            this._navMesh = navMesh;
            if (cxid) {
                this._currentNode = this._navMesh.getNode(cxid);
            }
            else {
                var cxidstart = CloudExperienceHost.ExperienceDescription.GetStart(experience);
                this._currentNode = (cxidstart != "") ? this._navMesh.getNode(cxidstart) : this._navMesh.getStart();
            }
            if (!this._resumeNode) {
                this._resumeNode = this._currentNode;
            }
            return this._navigateToCurrentNode();
        }
        evaluateBackNavigationStatusForNextTransition() {
            if (this._currentNode.cxid !== this._navMesh.getErrorNodeName()) {
                if (this.evaluateOverridableBooleanPropertyValue(this._currentNode.disableBackNavigationToNode, false)) {
                    this._backNavigationStatusForNextTransition = BackNavigationStatus.Disabled;
                }
                else {
                    this._backNavigationStatusForNextTransition = BackNavigationStatus.Enabled;
                }
            }
        }
        resetBackNavigationStatusForNextTransition() {
            this._backNavigationStatusForNextTransition = BackNavigationStatus.Unknown;
        }
        goToPreviousVisitedNode() {
            CloudExperienceHostAPI.Speech.SpeechSynthesis.stop();
            CloudExperienceHostAPI.Speech.SpeechRecognition.stop();
            if (this._navMesh.isBackstackForBackNavigationSupported() && (this._visitedNodeStack.length != 0)) {
                var backNode = this._visitedNodeStack.pop();
                if (backNode) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.InternalAppResult.navigateWithBackstack);
                    this._currentNode = backNode;
                }
                this._navigateToCurrentNode().done();
            }
        }
        addCurrentNodeToTopOfBackstack() {
            if (this._navMesh.isBackstackForBackNavigationSupported() && this._currentNode &&
                (this._topOfVisitedNodeStack() !== this._currentNode.cxid)) {
                this._visitedNodeStack.push(this._currentNode);
                return true;
            }
            return false;
        }
        updateVisitedStack() {
            if (this._navMesh.isBackstackForBackNavigationSupported() &&
                (this._topOfVisitedNodeStack() != this._currentNode.cxid)) {
                if (this._backNavigationStatusForNextTransition === BackNavigationStatus.Disabled) {
                    this._clearVisitedNodeStack();
                }
                else if (this._backNavigationStatusForNextTransition === BackNavigationStatus.Enabled) {
                    this._visitedNodeStack.push(this._currentNode);
                }
                this.resetBackNavigationStatusForNextTransition();
            }
        }
        clearWebView() {
            return new WinJS.Promise((completeDispatch /*, errorDispatch, progressDispatch */) => {
                Debug.assert(!this._clearWebViewCompletion, "_clearWebViewCompletion should not be defined");
                if (this._view.src == aboutBlankURI) {
                    completeDispatch();
                }
                else {
                    let httpRequestMessage = new Windows.Web.Http.HttpRequestMessage(Windows.Web.Http.HttpMethod.get, new Windows.Foundation.Uri(aboutBlankURI));
                    this._clearWebViewCompletion = completeDispatch;
                    this._view.navigateWithHttpRequestMessage(httpRequestMessage);
                }
            });
        }
        redirect(e, contextHeaders) {
            var httpMethod = (e.httpMethod.toUpperCase() === "POST") ? Windows.Web.Http.HttpMethod.post : Windows.Web.Http.HttpMethod.get;
            var httpRequestMessage = this._createHttpRequestMessage(httpMethod, e.url, null);
            this._appendCustomHeaders(httpRequestMessage, contextHeaders);
            if (e.value) {
                this._addDataToRequest(httpRequestMessage, e.key, e.value);
            }
            this._startNavigationTimer();
            this._view.navigateWithHttpRequestMessage(httpRequestMessage);
        }
        goBack() {
            if (!this._navMesh.isBackstackForBackNavigationSupported() && this._currentNode) {
                var backNode = this._navMesh.getNode(this._currentNode.backID);
                if (backNode) {
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.InternalAppResult.back);
                    this._currentNode = backNode;
                }
                this._navigateToCurrentNode().done();
            }
        }
        skipCurrentApp(node) {
            if (node) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.AppResult.fail);
                if (this.evaluateOverridableBooleanPropertyValue(node.disableBackNavigationToNode, false)) {
                    this._backNavigationStatusForNextTransition = BackNavigationStatus.Disabled;
                }
                this._nextNode = this._navMesh.getNode(node.failID);
                this.goNext();
            }
        }
        navigateToNode(node) {
            if (node) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.AppResult.cancel);
                if (this.evaluateOverridableBooleanPropertyValue(node.disableBackNavigationToNode, false)) {
                    this._backNavigationStatusForNextTransition = BackNavigationStatus.Disabled;
                }
                this._nextNode = node;
                this.goNext();
            }
        }
        goNext() {
            this.updateVisitedStack();
            this._currentNode = this._nextNode;
            if (this._currentNode) {
                if (!this._resumeNode || (this._currentNode !== this._navMesh.getErrorNode())) {
                    this._resumeNode = this._currentNode;
                }
            }
            this._navigateToCurrentNode().done();
        }
        loadIdentityProvider(signInIdentityProvider) {
            var id;
            switch (signInIdentityProvider) {
                case CloudExperienceHost.SignInIdentityProviders.Local:
                    id = 'Local';
                    break;
                case CloudExperienceHost.SignInIdentityProviders.MSA:
                    id = 'MSA';
                    break;
                case CloudExperienceHost.SignInIdentityProviders.AAD:
                    id = 'AAD';
                    break;
                default:
                    throw new CloudExperienceHost.InvalidArgumentError(signInIdentityProvider);
                    break;
            }
            var inclusive = (this.getNavMesh()) ? (this.getNavMesh().getInclusive() != 0) : false;
            if (inclusive) {
                id = 'Oobe' + id;
            }
            var provider = this._navMesh.getNode(id);
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(CloudExperienceHost.AppResult.abort);
            this.updateVisitedStack();
            if (provider) {
                this._currentNode = provider;
            }
            else {
                this._currentNode = this._navMesh.getNode(this._currentNode.abortID);
            }
            this._navigateToCurrentNode().done();
        }
        getNavMesh() {
            return this._navMesh;
        }
        getResumeNode() {
            return this._resumeNode;
        }
        webAppDone(appResult) {
            Debug.assert(!this._navigationTimerPromise, "_navigationTimerPromise should be null here. Adding a safeguard to call stopNavigationTimer");
            this._stopNavigationTimer();
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().stop(appResult);
            this._nextNode = this._getNext(appResult);
            let navDecision = { result: appResult, currentNode: this._currentNode };
            this._fireEvent("AppResultDetermined", navDecision);
            return (this._nextNode ? true : false);
        }
        setNavigationInterruptExpected() {
            this._navigationInterruptExpected = true;
        }
        getRedirectForPostTicketInterrupt() {
            return this._redirectForPostTicketInterrupt;
        }
        setRedirectForPostTicketInterrupt(redirectForPostTicketInterrupt) {
            this._redirectForPostTicketInterrupt = redirectForPostTicketInterrupt;
        }
        evaluateOverridableStringPropertyValue(propertyObject, defaultValue) {
            let propertyValue = defaultValue;
            if (propertyObject != null) {
                if (typeof (propertyObject) !== "string") {
                    propertyValue = this.getNavMesh().evaluateOverridableValue(propertyObject);
                }
                else {
                    propertyValue = propertyObject;
                }
            }
            return propertyValue;
        }
        evaluateOverridableBooleanPropertyValue(propertyObject, defaultValue) {
            let propertyValue = defaultValue;
            if (propertyObject != null) {
                if (typeof (propertyObject) !== "boolean") {
                    propertyValue = this.getNavMesh().evaluateOverridableValue(propertyObject);
                }
                else {
                    propertyValue = propertyObject;
                }
            }
            return propertyValue;
        }
    }
    CloudExperienceHost.Navigator = Navigator;
})(CloudExperienceHost || (CloudExperienceHost = {}));
if ((typeof define === "function") && define.amd) {
    define(function () {
        return CloudExperienceHost.Navigator;
    });
}
