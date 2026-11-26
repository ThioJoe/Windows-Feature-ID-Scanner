"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class AppManager {
        constructor() {
            this._appView = null;
            this._description = null;
            this._correlationId = null;
            this._targetedContentId = null;
            this._targetedContentPath = null;
            this._launchSurface = null;
            this._windowsFlightData = null;
            this._bridge = null;
            this._navigator = null;
            this._currentNode = null;
            this._pendingNode = null;
            this._hasNotifiedFirstVisible = false;
            this._processingWebAppTerminationMessage = false;
            this._ticketRequestId = null;
            this._resultsOperation = null;
            this._msaUIHandler = null;
            this._visibilityTimer = null;
            this._showProgressWhenPageIsBusyTimer = null;
            this._appResult = CloudExperienceHost.AppResult.fail;
            this._machineModel = null;
            this._manufacturer = null;
            this._platform = null;
            this._deviceForm = null;
            this._windowsProductId = "0"; // valid default value meaning non-specified product
            this._edition = null;
            this._discoveryNavMesh = null;
            this._scenario = null;
            this._failFromCxh = "CXHInternalFail";
            this._readyToNavigate = false;
            this._cxhReadyToClose = false;
            this._errorAppFailedNavigationAttemptsCount = 0;
            this._errorAppFailedNavigationMaxAttemptsAllowed = 5;
            this._narratorInstruction = null;
            this._endIntroVideoTimer = null;
            this._introVideoElement = null;
            this._videoWrapperElement = null;
            WinJS.Namespace.define("CloudExperienceHost", {
                getVersion: this._getVersion.bind(this),
                getContext: this._getContext.bind(this),
                getCurrentNode: function () { return this._currentNode; }.bind(this),
                fail: function () {
                    this._appResult = CloudExperienceHost.AppResult.fail;
                    this._close();
                }.bind(this),
                cancel: function () {
                    this._appResult = CloudExperienceHost.AppResult.cancel;
                    this._close();
                }.bind(this),
                getNavMesh: this.getDiscoveryNavMesh.bind(this),
                getNavManager: this.getNavManager.bind(this),
                getWindowsFlightDataAsync: this._getWindowsFlightDataAsync.bind(this)
            });
        }
        initialize(args) {
            try {
                CloudExperienceHostAPI.AppExtensionsManager.addUdkPackageToProcessPackageGraph();
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AddUdkPackageToProcessPackageGraphSucceeded");
            }
            catch (ex) {
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AddUdkPackageToProcessPackageGraphFailed", CloudExperienceHost.GetJsonFromError(ex));
            }
            Windows.Networking.Connectivity.NetworkInformation.onnetworkstatuschanged = this._onNetworkStatusChanged.bind(this);
            this._machineModel = CloudExperienceHost.Environment.getMachineModel();
            this._manufacturer = CloudExperienceHost.Environment.getManufacturer();
            this._platform = CloudExperienceHost.Environment.getPlatform();
            this._deviceForm = CloudExperienceHost.Environment.getDeviceForm();
            this._windowsProductId = CloudExperienceHost.Environment.getWindowsProductId();
            this._edition = CloudExperienceHost.Environment.getEdition();
            this._setScenario(args);
            this._setDescription(this._scenario);
            let validReboot = CloudExperienceHost.Storage.SharableData.getValue("shouldRebootForOOBE");
            if (validReboot) {
                CloudExperienceHost.Storage.SharableData.removeValue("shouldRebootForOOBE");
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("AppResuming", CloudExperienceHost.Storage.SharableData.getValue("resumeCXHId"));
            }
            else {
                CloudExperienceHost.Storage.SharableData.addValue("OOBEResumeEnabled", false);
            }
            let navMeshPromise = CloudExperienceHost.Discovery.getNavMesh(this._description).then((navMesh) => {
                this._discoveryNavMesh = navMesh;
                if (!validReboot) {
                    let videoSrc = navMesh.getIntroVideoPath();
                    if (videoSrc !== "") {
                        this._initializeIntroVideo(videoSrc);
                    }
                }
                if (navMesh.getInclusive() != 0) {
                    let speechDisabled = navMesh.getSpeechDisabled();
                    return AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Speech.SpeechRecognitionController").enableAsync(CloudExperienceHost.Cortana.isCortanaSupported() && !speechDisabled).then(() => { }, (error) => { });
                }
            });
            let flightDataPromise = this._getWindowsFlightDataAsync();
            return WinJS.Promise.join({ navMeshPromise: navMeshPromise, flightDataPromise: flightDataPromise });
        }
        setAppViewManager(view) {
            this._appView = view;
        }
        setNavManager(navManager) {
            this._navManager = navManager;
        }
        getNavManager() {
            return this._navManager;
        }
        static getGlobalBridgeInstance() {
            return this._globalBridgeInstance;
        }
        getDiscoveryNavMesh() {
            return this._discoveryNavMesh;
        }
        start(args) {
            this._start(false);
        }
        resume(args) {
            this._start(true);
        }
        checkpoint() {
        }
        restart(scenario) {
            if (scenario) {
                this._scenario = scenario;
                this._setDescription(this._scenario);
                CloudExperienceHost.Discovery.getNavMesh(this._description).then(function (navMesh) {
                    this._discoveryNavMesh = navMesh;
                    this._navigate();
                }.bind(this));
            }
            else {
                this._navigate();
            }
        }
        _onNetworkStatusChanged(eventArgs) {
            let connectionProfile = Windows.Networking.Connectivity.NetworkInformation.getInternetConnectionProfile();
            let connectivityLevel = connectionProfile ? connectionProfile.getNetworkConnectivityLevel() : -1; // Use -1 to indicate null/undefined connectionProfile
            /* No check for InternetAccess because if we were previously in constrainedInternetAccess,
             * we assume that user resolved the captive portal and "CaptivePortalConnect" breadcrumb still holds true.
             * We are ignoring the case of user connecting Ethernet cable after attempting to connect to captive portal network, as this is unlikely */
            if (connectivityLevel == Windows.Networking.Connectivity.NetworkConnectivityLevel.constrainedInternetAccess) {
                CloudExperienceHost.Storage.VolatileSharableData.addItem("NetworkingValues", "CaptivePortalConnect", true);
            }
            else if (connectivityLevel != Windows.Networking.Connectivity.NetworkConnectivityLevel.internetAccess) {
                CloudExperienceHost.Storage.VolatileSharableData.removeItem("NetworkingValues", "CaptivePortalConnect");
            }
        }
        _initializeIntroVideo(videoSrc) {
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("StartToInitializeIntroVideo");
            let videoWrapperElement = document.createElement('div');
            videoWrapperElement.setAttribute('class', 'introvideo-wrapper');
            let introVideoElement = document.createElement('video');
            let mediaElement = introVideoElement;
            if (!mediaElement.canPlayType || !mediaElement.canPlayType("video/mp4")) {
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("CannotPlayVideoType");
                return;
            }
            introVideoElement.setAttribute('class', 'introvideo-container');
            introVideoElement.src = videoSrc;
            videoWrapperElement.appendChild(introVideoElement);
            document.body.appendChild(videoWrapperElement);
            this._setRootElementDisplayed(false);
            const onError = () => {
                this._setRootElementDisplayed(true);
                videoWrapperElement.style.display = "none";
                introVideoElement.removeEventListener("error", onError);
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("IntroVideoError");
            };
            introVideoElement.addEventListener("error", onError);
            const onEnded = () => {
                this._removeIntroVideoWrapper(videoWrapperElement);
                this._stopPlayIntrovideoTimer();
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("EndToPlayIntroVideo");
                introVideoElement.removeEventListener('ended', onEnded);
            };
            introVideoElement.addEventListener('ended', onEnded);
            this._videoWrapperElement = videoWrapperElement;
            this._introVideoElement = introVideoElement;
        }
        _removeIntroVideoWrapper(videoWrapperElement) {
            let controlsContainer = document.getElementsByClassName("Container");
            if (controlsContainer.length > 0) {
                controlsContainer[0].classList.add('intro');
            }
            this._setRootElementDisplayed(true);
            videoWrapperElement.style.display = "none";
        }
        _extractExceptionLogData(data) {
            return {
                exp: CloudExperienceHost.ExperienceDescription.getExperience(this._description),
                cxid: this._currentNode && this._currentNode.cxid,
                pendingCxid: this._pendingNode && this._pendingNode.cxid,
                sourceUrl: data && data.errorUrl,
                colno: data && (data.colno || data.errorCharacter),
                lineno: data && (data.lineno || data.errorLine),
                filename: data && (data.filename || (data.error && data.error.filename)),
                errorCode: data && (data.number || (data.exception && (data.exception.number || data.exception.code)) || (data.error && data.error.number) || data.errorCode || 0),
                message: data && (data.message || data.errorMessage || (data.error && data.error.message) || (data.exception && data.exception.message) || null),
                stack: data && (data.stack || (data.exception && (data.exception.stack || data.exception.message)) || (data.error && ((data.error.stack) || (data.error.error && data.error.error.stack))) || "empty").split("  at ").join(""),
            };
        }
        _startIntroVideoPlayback() {
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("StartToPlayIntroVideo");
            this._introVideoElement.play();
            AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").onFirstOOBEWebAppVisible();
            let videoDuration = (this._introVideoElement.duration && (this._introVideoElement.duration > 0)) ? this._introVideoElement.duration : 5; // default to be 5s if failed to get the video duration
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("IntroVideoDuration", videoDuration);
            this._startPlayIntroVideoTimer(this._videoWrapperElement, videoDuration);
        }
        _playIntroVideoIfLoaded() {
            if (this._introVideoElement.readyState == HTMLMediaElement.HAVE_ENOUGH_DATA) {
                this._startIntroVideoPlayback();
            }
            else {
                const onLoadedData = () => {
                    if (this._introVideoElement.readyState == HTMLMediaElement.HAVE_ENOUGH_DATA) {
                        this._introVideoElement.removeEventListener("loadeddata", onLoadedData);
                        this._startIntroVideoPlayback();
                    }
                };
                this._introVideoElement.addEventListener("loadeddata", onLoadedData);
                if (this._introVideoElement.readyState == HTMLMediaElement.HAVE_ENOUGH_DATA) {
                    this._introVideoElement.removeEventListener("loadeddata", onLoadedData);
                    this._startIntroVideoPlayback();
                }
            }
        }
        onUnhandledException(e) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                try {
                    Debug.break("Unhandled exception caught by AppManager");
                    let logData = this._extractExceptionLogData(e.detail);
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("UnhandledException", JSON.stringify(logData));
                    if (!this._cxhReadyToClose) {
                        if (this._platform === CloudExperienceHost.TargetPlatform.XBOX) {
                            this._appResult = this._failFromCxh;
                            this._close();
                        }
                        else {
                            if (this._isInclusiveNavMesh()) {
                                this._tryLoadInclusiveErrorApp(e);
                            }
                            else {
                                let shouldShowAccountErrorPageOnFailurebyDefault = CloudExperienceHost.getContext() && (CloudExperienceHost.getContext().host.toLowerCase() === "frx") &&
                                    (CloudExperienceHost.Environment.getPlatform() === CloudExperienceHost.TargetPlatform.DESKTOP);
                                this._loadErrorPage(this._currentNode ? this._currentNode.showAccountErrorPageOnFailure : shouldShowAccountErrorPageOnFailurebyDefault).done(completeDispatch, errorDispatch);
                            }
                        }
                    }
                }
                catch (error) {
                    this._crashCxh(error);
                }
            }.bind(this));
        }
        _crashCxh(error) {
            AppManager.prototype.onUnhandledException = () => {
                return null;
            };
            throw error;
        }
        _resetErrorPageNavigationFailureCount() {
            this._errorAppFailedNavigationAttemptsCount = 0;
        }
        _navigateHelper(navigateCallback, onSuccessCallback, onErrorCallback) {
            if (navigateCallback) {
                this._appView.showProgress().then(() => {
                    this._appView.resetFooterFocus();
                    try {
                        if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("GamepadLegendEnabled")) {
                            this._appView.setGamepadLegendDisplayOverrideForB(null);
                        }
                    }
                    catch (ex) {
                    }
                }).then(() => {
                    navigateCallback();
                }).done(() => {
                    if (onSuccessCallback) {
                        onSuccessCallback();
                    }
                }, (error) => {
                    if (error) {
                        if (!onErrorCallback) {
                            this.onUnhandledException(error);
                        }
                        else {
                            onErrorCallback(error);
                        }
                    }
                });
            }
        }
        _tryLoadInclusiveErrorApp(e) {
            if (this._errorAppFailedNavigationAttemptsCount < this._errorAppFailedNavigationMaxAttemptsAllowed) {
                this._loadInclusiveErrorAppOrSkipToNext();
            }
            else {
                let resumeNode = this._navigator.getResumeNode();
                if (resumeNode.failID) {
                    this._navigateHelper(() => {
                        this._processingWebAppTerminationMessage = false;
                        this._navigator.navigate(this._navigator.getNavMesh(), this._description, resumeNode.failID);
                    }, () => {
                        this._resetErrorPageNavigationFailureCount();
                    }, (err) => {
                        this._crashCxh(err);
                    });
                }
                else {
                    this._crashCxh(e);
                }
            }
        }
        _onWebViewUnhandledException(e) {
            try {
                Debug.break("Unhandled exception from WebView received by AppManager");
                if (e.detail && e.detail.number && (e.detail.number == -2147023765 /* error: ERROR_POSSIBLE_DEADLOCK 0x8007046B */)) {
                    this.onUnhandledException(e);
                }
                else {
                    let logData = this._extractExceptionLogData(e.detail);
                    logData.sourceUrl = CloudExperienceHost.UriHelper.RemovePIIFromUri(e.sourceUrl);
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("WebViewUnhandledException", JSON.stringify(logData));
                }
            }
            catch (ex) {
            }
        }
        _onReportTargetedContentInteraction(interaction) {
            try {
                if (this._targetedContentId && this._targetedContentPath) {
                    Windows.Services.TargetedContent.TargetedContentContainer.getAsync(this._targetedContentId).then((result) => {
                        if (result.availability !== Windows.Services.TargetedContent.TargetedContentAvailability.none) {
                            let content = result.selectSingleObject(this._targetedContentPath);
                            if (content) {
                                content.item.reportInteraction(interaction);
                            }
                        }
                    }, (err) => {
                        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("TargetedContentContainer", CloudExperienceHost.GetJsonFromError(err));
                    });
                }
            }
            catch (ex) {
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("TargetedContentContainer", CloudExperienceHost.GetJsonFromError(ex));
            }
        }
        _start(resumed) {
            if (this._description) {
                var stateManager = CloudExperienceHost.StateManager.getInstance();
                var cxid = (resumed && stateManager.isValid(this._scenario)) ? stateManager.getNextCXID() : null;
                stateManager.setSource(this._scenario);
                this._navigate(cxid);
            }
            else {
                window.close();
            }
        }
        _getVersion() {
            return 1;
        }
        _setScenario(args) {
            var scenario = null;
            switch (args.detail.kind) {
                case Windows.ApplicationModel.Activation.ActivationKind.launch:
                    scenario = args.detail.arguments; /* WebUILaunchActivatedEventArgs */
                    this._resultsOperation = this._getResultOperationForXbox();
                    break;
                case Windows.ApplicationModel.Activation.ActivationKind.protocol:
                    scenario = args.detail.uri.absoluteCanonicalUri; /* WebUIProtocolActivatedEventArgs */
                    if (args.detail.uri.schemeName.toLowerCase() === "ms-device-enrollment") {
                        if (args.detail.uri.absoluteCanonicalUri.toLowerCase().indexOf("ms-device-enrollment:?mode=mdm") === 0) {
                            scenario = scenario.replace("ms-device-enrollment:", "ms-cxh://mosetMDMconnecttowork/");
                        }
                        else if (args.detail.uri.absoluteCanonicalUri.toLowerCase().indexOf("ms-device-enrollment:?mode=awa") === 0 ||
                            args.detail.uri.absoluteCanonicalUri.toLowerCase().indexOf("ms-device-enrollment:?mode=aadj") === 0) {
                            scenario = scenario.replace("ms-device-enrollment:", "ms-cxh://MOSET/CONNECTTOWORK");
                        }
                        else {
                            scenario = "ms-cxh://";
                        }
                    }
                    else if (args.detail.uri.schemeName.toLowerCase() === "ms-cxh-test") {
                        scenario = scenario.replace("ms-cxh-test://", "ms-cxh://");
                    }
                    this._resultsOperation = this._getResultOperationForXbox();
                    break;
                case Windows.ApplicationModel.Activation.ActivationKind.protocolForResults:
                    scenario = args.detail.uri.absoluteUri; /* WebUIProtocolActivatedEventArgs */
                    this._resultsOperation = args.detail.protocolForResultsOperation;
                    break;
                case Windows.ApplicationModel.Activation.ActivationKind.componentUI:
                    scenario = args.detail.arguments; /* WebUILaunchActivatedEventArgs */
                    this._resultsOperation = this._getResultOperationForXbox();
                    break;
                default:
                    throw new Error(CloudExperienceHost.ErrorNames.ActivationNotSupported);
                    break;
            }
            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("BlockRestrictedFlows")) {
                const BLOCKED_COMMANDS_GLOBAL = [
                    "LOCALONLY"
                ];
                const BLOCKED_COMMANDS_OOBE = [
                    "SETADDLOCALONLY",
                    "SETSQSALOCALONLY",
                    "SETADDNEWUSER",
                    "INCLUSIVETEST",
                    "TEST",
                    "CLOUDNAVMESHTEST",
                    "LITETEST"
                ];
                if ((scenario !== null) && (typeof scenario === "string") && scenario.toLowerCase().startsWith("ms-cxh:")) {
                    try {
                        const expDesc = CloudExperienceHost.ExperienceDescription.Create(scenario);
                        const experienceName = CloudExperienceHost.ExperienceDescription.getExperience(expDesc);
                        const experienceNameUpper = experienceName ? experienceName.toUpperCase() : "";
                        if (BLOCKED_COMMANDS_GLOBAL.indexOf(experienceNameUpper) >= 0) {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("ScenarioBlocked", scenario);
                            scenario = null;
                        }
                        else if ((Windows.System.Profile.SystemSetupInfo.outOfBoxExperienceState !== Windows.System.Profile.SystemOutOfBoxExperienceState.completed) && (BLOCKED_COMMANDS_OOBE.indexOf(experienceNameUpper) >= 0)) {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("ScenarioBlockedDuringOOBE", scenario);
                            scenario = null;
                        }
                    }
                    catch (e) {
                        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("ScenarioBlockParseError", JSON.stringify({
                            error: e && e.toString(),
                            scenario
                        }));
                    }
                }
            }
            if (!scenario || (scenario.length === 0)) {
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("CloseCXHDueToEmptyScenario");
                WinJS.Application.stop();
                window.close();
            }
            this._scenario = scenario;
        }
        _setDescription(scenario) {
            if (scenario) {
                this._description = CloudExperienceHost.ExperienceDescription.Create(scenario);
                if (this._description) {
                    this._correlationId = CloudExperienceHost.ExperienceDescription.GetCorrelationId(this._description);
                    this._targetedContentId = CloudExperienceHost.ExperienceDescription.GetTargetedContentId(this._description);
                    this._targetedContentPath = CloudExperienceHost.ExperienceDescription.GetTargetedContentPath(this._description);
                    this._launchSurface = CloudExperienceHost.ExperienceDescription.GetLaunchSurface(this._description);
                    CloudExperienceHost.Rewards.setShouldReportRewards(CloudExperienceHost.ExperienceDescription.GetShouldReportRewards(this._description));
                }
            }
        }
        _getContext() {
            if (this._description) {
                let context = new CloudExperienceHost.Context();
                context.source = this._description.source;
                context.protocol = this._description.protocol;
                context.host = this._description.host;
                context.machineModel = this._machineModel;
                context.manufacturer = this._manufacturer;
                context.platform = this._platform;
                context.deviceForm = this._deviceForm;
                context.windowsProductId = this._windowsProductId;
                context.edition = this._edition;
                context.launchSurface = this._launchSurface;
                context.windowsFlightData = this._windowsFlightData;
                let currentNode = (this._navigator && this._navigator.getCurrentNode()) ? this._navigator.getCurrentNode() : undefined;
                let inclusiveFromNode = currentNode ? currentNode.speechCapableOverride : undefined;
                let inclusiveFromMesh = (this._navigator && this._navigator.getNavMesh()) ? this._navigator.getNavMesh().getInclusive() : 0;
                let inclusive = (inclusiveFromNode === undefined) ? inclusiveFromMesh : ((inclusiveFromNode === true) ? 1 : 0);
                let isCloudPolicyEnforced = CloudExperienceHostAPI.Environment.isCloudPolicyEnforced ? 1 : 0;
                let nodeCapabilities = (currentNode && currentNode.nodeCapabilities) ? JSON.stringify(currentNode.nodeCapabilities) : undefined;
                context.capabilities = JSON.stringify({
                    "PrivatePropertyBag": 1,
                    "PasswordlessConnect": 1,
                    "Inclusive": inclusive,
                    "IsCloudPolicyEnforced": isCloudPolicyEnforced,
                    "PasswordlessSelfConnect": 1,
                    "VisibilityTimerCancelledByShowProgress": true,
                    "NodeCapabilities": nodeCapabilities,
                    "GetTokenSilently": 1
                });
                if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("RequestRawDA")) {
                    const identityCapabilities = JSON.parse(CloudExperienceHostAPI.Environment.identityCapabilities);
                    const existingCapabilities = JSON.parse(context.capabilities);
                    context.capabilities = JSON.stringify(Object.assign({}, existingCapabilities, identityCapabilities));
                }
                context.experienceName = CloudExperienceHost.ExperienceDescription.getExperience(this._description);
                let discoveryMesh = this.getDiscoveryNavMesh();
                context.personality = discoveryMesh ? discoveryMesh.getPersonality() : CloudExperienceHost.TargetPersonality.Unspecified;
                return context;
            }
            else {
                return null;
            }
        }
        _getWindowsFlightDataAsync() {
            return CloudExperienceHostAPI.UtilStaticsCore.getWindowsFlightDataAsync().then((result) => {
                if (result) {
                    this._windowsFlightData = result.split(",").filter((featureId) => { return featureId.startsWith("FX:"); }).toString();
                }
            }, (error) => {
            });
        }
        _navigate(cxid) {
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().start(CloudExperienceHost.UriHelper.RemovePIIFromUri(this._description.source), CloudExperienceHost.ExperienceDescription.RemovePIIFromExperienceDescription(this._description), this._correlationId);
            this._appView.showProgress().then(function () {
                this._create().then(function () {
                    this._setRootElementDisplayed(true);
                    this._initializeExternalModalRects();
                    this._navigator.navigate(this.getDiscoveryNavMesh(), this._description, cxid).done();
                }.bind(this));
            }.bind(this));
        }
        _setRootElementDisplayed(visible) {
            document.getElementById("_defaultRoot").style.display = (visible ? "" : "none");
        }
        _setupForNavigation(webViewCtrl, completeDispatch, errorDispatch) {
            CloudExperienceHost.Discovery.getApiRules().then(function (rules) {
                var contractHandler = new CloudExperienceHost.ContractHandler(rules);
                if (AppManager._globalBridgeInstance) {
                    this._bridge = AppManager._globalBridgeInstance;
                    this._bridge.setContractHandler(contractHandler);
                }
                else {
                    this._bridge = new CloudExperienceHost.Bridge(webViewCtrl, contractHandler);
                    AppManager._globalBridgeInstance = this._bridge;
                }
                this._bridge.addEventListener(CloudExperienceHost.Events.visible, this._onVisible.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.goBack, this._onGoBack.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.done, this._onDone.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.skipApp, this._onSkip.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.retryApp, this._onRetry.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.navigate, this._onNavigate.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.showEaseOfAccessControl, this._onShowEaseOfAccessControl.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.loadIdentityProvider, this._onLoadIdentityProvider.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.postTicketToReturnUrl, this._onPostTicketToReturnUrl.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.postDeviceTicketToUrl, this._onPostDeviceTicketToUrl.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.registerNGCForUser, this._onRegisterNGCForUser.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.resetNGCForUser, this._onResetNGCForUser.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.postSharedAccountRegistrationTicketsToUrl, this._onPostSharedAccountRegistrationTicketsToUrl.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.showProgressWhenPageIsBusy, this._onShowProgressWhenPageIsBusy.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.unhandledException, this._onWebViewUnhandledException.bind(this));
                this._bridge.addEventListener(CloudExperienceHost.Events.reportTargetedContentInteraction, this._onReportTargetedContentInteraction.bind(this));
                this._navManager.registerBridge(this._bridge);
                this._navManager.registerWebviewCtrl(webViewCtrl);
                this._navManager.registerAppView(this._appView);
                this._navigator = new CloudExperienceHost.Navigator(webViewCtrl, contractHandler, this._navManager);
                this._navigator.addEventListener("Error", this._onError.bind(this));
                this._navigator.addEventListener("NavigationStarting", this._onNavigationStarting.bind(this));
                this._navigator.addEventListener("NavigationCompleted", this._onNavigationCompleted.bind(this));
                this._navigator.addEventListener("Done", this._onDone.bind(this));
                webViewCtrl.addEventListener("MSWebViewUnsupportedUriSchemeIdentified", this._onUnsupportedUriSchemeIdentified.bind(this));
                window.addEventListener("focus", this._onFocus.bind(this), false);
                window.addEventListener("focusout", this._onFocusOut.bind(this), false);
                window.addEventListener("resize", this._onResize.bind(this));
                let headerParams = CloudExperienceHost.ExperienceDescription.GetHeaderParams(this._description);
                if (headerParams !== "") {
                    this._navigator.setHeaderParams(headerParams);
                }
                this._readyToNavigate = true;
                completeDispatch();
            }.bind(this), errorDispatch);
        }
        _create() {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                var webViewCtrl = this._appView.createWebView();
                this._appView.cleanView();
                this._appView.getView().appendChild(webViewCtrl);
                webViewCtrl.setAttribute("id", "x-ms-webview");
                if (this._platform === CloudExperienceHost.TargetPlatform.XBOX) {
                    webViewCtrl.focus();
                }
                if (!this._readyToNavigate) {
                    this._setupForNavigation(webViewCtrl, completeDispatch, errorDispatch);
                }
                else {
                    completeDispatch();
                }
            }.bind(this));
        }
        _initializeExternalModalRects() {
            if (this.getDiscoveryNavMesh().getInitializeExternalModalRects()) {
                let clientRect = this._appView.getBoundingClientRect();
                let rect = {
                    height: clientRect.height,
                    width: clientRect.width,
                    x: clientRect.left,
                    y: clientRect.top
                };
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("UpdatingExternalBoundingClientRect", JSON.stringify(rect));
                CloudExperienceHostAPI.HostedApplicationCore.setWindowLocation(false /* modal rect */, rect);
                let coordinator = WindowsUdk.Security.Credentials.UI.CredUICoordinator.getForCurrentView();
                if (coordinator) {
                    let physicalPixelRect = {
                        height: clientRect.height * window.devicePixelRatio,
                        width: clientRect.width * window.devicePixelRatio,
                        x: clientRect.left * window.devicePixelRatio,
                        y: clientRect.top * window.devicePixelRatio
                    };
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("UpdatingCredUICoordinatorRect", JSON.stringify(physicalPixelRect));
                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeCredUIPopupHandheldFix")) {
                        if (!CloudExperienceHost.Environment.isGamepadBasedDevice()) {
                            coordinator.styleOptions = coordinator.styleOptions | WindowsUdk.Security.Credentials.UI.CredUICoordinatorStyleOptions.useCoordinatorPlacement |
                                WindowsUdk.Security.Credentials.UI.CredUICoordinatorStyleOptions.inlineFluentTheme;
                        }
                    }
                    else {
                        coordinator.styleOptions = coordinator.styleOptions | WindowsUdk.Security.Credentials.UI.CredUICoordinatorStyleOptions.useCoordinatorPlacement |
                            WindowsUdk.Security.Credentials.UI.CredUICoordinatorStyleOptions.inlineFluentTheme;
                    }
                    coordinator.placement = physicalPixelRect;
                    coordinator.reportChanged();
                }
            }
        }
        _onResize() {
            this._initializeExternalModalRects();
        }
        _onFocus() {
            if (this._platform === CloudExperienceHost.TargetPlatform.XBOX) {
                var webViewCtrl = document.getElementById("x-ms-webview");
                webViewCtrl.focus();
                webViewCtrl.focus();
            }
            if (this._appView.isChromeDimBasedOnFocus()) {
                this._appView.undimChrome();
            }
        }
        _onFocusOut() {
            if (this._appView.isChromeDimBasedOnFocus()) {
                this._appView.dimChrome();
            }
        }
        _onNavigationStarting(node) {
            Debug.log(`Navigation starting to node: ${node && node.cxid}`);
            if (this._pendingNode) {
                Debug.break("Trying to navigate to " + node && node.cxid + " while already navigating to " + this._pendingNode.cxid);
                let logDetails = { currentCxid: this._currentNode && this._currentNode.cxid, pendingCxid: this._pendingNode.cxid, navCxid: node && node.cxid };
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("StartedNavigatingWhileAlreadyNavigating", JSON.stringify(logDetails));
            }
            this._pendingNode = node;
            CloudExperienceHost.StateManager.getInstance().onNavigate(node);
            if (this._blockLateWebAppCalls()) {
                this._bridge.connectToWebView();
            }
            this._stopShowProgressWhenPageIsBusyTimer();
            this._stopVisibilityTimer(); // Ensure timer is cleared prior to navigation- if needed, it will be set again on navigation completion
            this._appView.setAllowChangeDisplayMode(node.allowDisplayModeChange);
        }
        _startVisibilityTimer() {
            var timeout = 15000; // 15 seconds
            if (this._currentNode.timeout) {
                timeout = this._currentNode.timeout;
            }
            this._visibilityTimer = WinJS.Promise.timeout(timeout).then(function () {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("VisibilityTimeout", this._currentNode.cxid);
                this._onDone(this._isInclusiveNavMesh() ? CloudExperienceHost.AppResult.error : CloudExperienceHost.AppResult.fail, true); // WebApp should fire Visible event when is ready; passing true to signify that this an internal CXH result
            }.bind(this));
        }
        _stopVisibilityTimer() {
            if (this._visibilityTimer) {
                this._visibilityTimer.cancel();
                this._visibilityTimer = null;
            }
        }
        _startNarratorInstructionTimer() {
            let timeout = 20000; // 20 seconds
            this._narratorInstruction = WinJS.Promise.timeout(timeout).then(() => {
                try {
                    let resourceStrings = JSON.parse(CloudExperienceHost.StringResources.makeResourceObject("oobeWelcome"));
                    CloudExperienceHostAPI.Speech.SpeechSynthesis.speakAsync(resourceStrings.LaunchNarratorInstruction, true /* useVoiceOver */, false /* checkSpeechControllerState */);
                }
                catch (e) {
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("NarratorInstructionFailed", CloudExperienceHost.GetJsonFromError(e));
                }
            });
        }
        _stopNarratorInstructionTimer() {
            if (this._narratorInstruction) {
                this._narratorInstruction.cancel();
                this._narratorInstruction = null;
            }
        }
        _startShowProgressWhenPageIsBusyTimer(callerTimeout) {
            var timeout = 60000; // 60 seconds default, or use caller supplied value from webapp
            if (callerTimeout > 0) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("SetCustomShowProgressTimeout", callerTimeout);
                timeout = callerTimeout;
            }
            this._showProgressWhenPageIsBusyTimer = WinJS.Promise.timeout(timeout).then(function () {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("ShowProgressWhenPageIsBusyTimeout", this._currentNode.cxid);
                this._onDone(CloudExperienceHost.AppResult.error, true); // WebApp should fire Appresult success/fail event when is ready; passing true to signify that this an internal CXH result
            }.bind(this));
        }
        _stopShowProgressWhenPageIsBusyTimer() {
            if (this._showProgressWhenPageIsBusyTimer) {
                this._showProgressWhenPageIsBusyTimer.cancel();
                this._showProgressWhenPageIsBusyTimer = null;
            }
        }
        _startPlayIntroVideoTimer(videoWrapperElement, videoDuration) {
            let timeout = 2000 * videoDuration; // 2 times of the video duration in ms
            this._endIntroVideoTimer = WinJS.Promise.timeout(timeout).then(() => {
                try {
                    this._removeIntroVideoWrapper(videoWrapperElement);
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("EndToPlayIntroVideoDueToTimeout");
                }
                catch (e) {
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("EndIntroVideoTimerFailed", CloudExperienceHost.GetJsonFromError(e));
                }
            });
        }
        _stopPlayIntrovideoTimer() {
            if (this._endIntroVideoTimer) {
                this._endIntroVideoTimer.cancel();
                this._endIntroVideoTimer = null;
            }
        }
        _stopSpeech() {
            this._stopNarratorInstructionTimer();
            if (this._isInclusiveNavMesh()) {
                try {
                    CloudExperienceHostAPI.Speech.SpeechSynthesis.stop();
                    CloudExperienceHostAPI.Speech.SpeechRecognition.stop();
                }
                catch (e) {
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("StopSpeechFailure", CloudExperienceHost.GetJsonFromError(e));
                }
            }
        }
        _onNavigationCompleted(node) {
            Debug.log(`Navigation completed to node: ${node && node.cxid}`);
            if (!this._pendingNode) {
                Debug.log("Completed a navigation without NavigationStarting having fired");
            }
            else if (node != this._pendingNode) {
                Debug.break("Completed navigating to " + node && node.cxid + " while already navigating to " + this._pendingNode.cxid);
                let logDetails = { currentCxid: this._currentNode && this._currentNode.cxid, pendingCxid: this._pendingNode && this._pendingNode.cxid, navCxid: node && node.cxid };
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("NavigationCompletedDifferentNodeThanStarted", JSON.stringify(logDetails));
            }
            this._pendingNode = null;
            if ((this._currentNode) && (this._currentNode.cxid === node.cxid)) {
                this._stopVisibilityTimer();
                this._stopShowProgressWhenPageIsBusyTimer();
                if ((typeof (this._currentNode.intraWebAppVisibility) === 'undefined') || (this._currentNode.intraWebAppVisibility === true) || (this._navigator.getRedirectForPostTicketInterrupt() === true)) {
                    this._onVisible(true);
                }
                else {
                    this._startVisibilityTimer();
                }
            }
            else {
                this._stopVisibilityTimer();
                this._stopShowProgressWhenPageIsBusyTimer();
                this._currentNode = node;
                if ((typeof (this._currentNode.visibility) === 'undefined') || (this._currentNode.visibility === true)) {
                    this._onVisible(true);
                }
                else {
                    this._startVisibilityTimer();
                }
            }
            this._navigator.setRedirectForPostTicketInterrupt(false);
        }
        _onUnsupportedUriSchemeIdentified(e) {
            var uri = new Windows.Foundation.Uri(e.uri);
            if (uri.schemeName === "ms-aadj-redir") {
                var payload = (uri.query !== "") ? uri.query : uri.fragment;
                CloudExperienceHost.Storage.PrivateData.addItem("msAadjRedirQueryTerms", payload);
                this._navigator.setNavigationInterruptExpected();
                this._navigate(this._currentNode.cxid);
                e.preventDefault();
            }
        }
        _notifyWebAppVisibleIfNecessary() {
            if (this._currentNode) {
                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyWebAppStatusChanged(this._currentNode.cxid, CloudExperienceHostAPI.WebAppStatus.visible);
            }
            if (!this._hasNotifiedFirstVisible) {
                this._hasNotifiedFirstVisible = true;
                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("FirstWebAppVisible", this._currentNode && this._currentNode.cxid);
                if (this._navigator && this._navigator.getNavMesh().getNotifyOnFirstVisible()) {
                    if (this._introVideoElement != null) {
                        this._playIntroVideoIfLoaded();
                    }
                    else {
                        AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").onFirstOOBEWebAppVisible();
                    }
                }
                if (CloudExperienceHost.getContext().host.toLowerCase() === "frx") {
                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyOobeReadyStateChanged(true);
                }
                if (this._discoveryNavMesh.shouldRunNarratorInstruction() &&
                    !(CloudExperienceHost.Storage.SharableData.getValue("OOBEResumeEnabled")) &&
                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Speech.SpeechRecognitionController").isSpeechAllowedByPolicy()) {
                    this._startNarratorInstructionTimer();
                }
            }
        }
        _loadErrorPage(showAccountErrorPageOnFailure) {
            return new WinJS.Promise(function (completeDispatch, errorDispatch /*, progressDispatch */) {
                this._appView.cleanView();
                this._appView.showProgress().then(function () {
                    let errorPageUri = "views/errorHandler.html";
                    WinJS.UI.Pages.render(errorPageUri, this._appView.getView(), showAccountErrorPageOnFailure).done(function () {
                        this._appView.showView().done(completeDispatch, errorDispatch);
                    }.bind(this));
                }.bind(this));
            }.bind(this));
        }
        _isInclusiveNavMesh() {
            return (this._navigator && this._navigator.getNavMesh()) ? (this._navigator.getNavMesh().getInclusive() != 0) : false;
        }
        _blockLateWebAppCalls() {
            return (this._navigator && this._navigator.getNavMesh()) ? this._navigator.getNavMesh().blockLateWebAppCalls() : false;
        }
        _loadInclusiveErrorAppOrSkipToNext() {
            let resumeNode = this._navigator.getResumeNode();
            if (resumeNode.disableErrorPageOnFailure && resumeNode.failID) {
                this._processingWebAppTerminationMessage = false;
                this._onSkip();
            }
            else {
                this._errorAppFailedNavigationAttemptsCount++;
                this._navigateHelper(() => {
                    this._processingWebAppTerminationMessage = false;
                    this._navigator.navigate(this._navigator.getNavMesh(), this._description, this._navigator.getNavMesh().getErrorNodeName());
                });
            }
        }
        _onError(e) {
            if (e.node) {
                this._currentNode = e.node;
            }
            if (e.node && this._isInclusiveNavMesh()) {
                this._tryLoadInclusiveErrorApp(e);
            }
            else if (e.node && (e.node.showAccountErrorPageOnFailure || e.node.showErrorPageOnFailure)) {
                this._loadErrorPage(e.node.showAccountErrorPageOnFailure ? true : false).done(function () {
                    this._notifyWebAppVisibleIfNecessary();
                }.bind(this));
            }
            else {
                this._onDone(CloudExperienceHost.AppResult.fail, true); // Passing true to signify that this an internal CXH result
            }
        }
        _onVisible(arg) {
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("Visible", arg);
            if (arg === true) {
                this._stopVisibilityTimer();
                this._stopShowProgressWhenPageIsBusyTimer();
                let switchView = true;
                if (this._currentNode && this._currentNode.launcher) {
                    switchView = false;
                }
                this._navManager.notifyEvent(CloudExperienceHost.NavigationEvent.CompletedAndVisible, this._currentNode ? this._currentNode.cxid : undefined);
                if (switchView) {
                    this._appView.showView().done(function () {
                        this._notifyWebAppVisibleIfNecessary();
                    }.bind(this));
                }
                else {
                    this._notifyWebAppVisibleIfNecessary();
                }
                if (this._currentNode && this._currentNode.frameAnimation) {
                    CloudExperienceHost.AppFrame.showGraphicAnimation(this._currentNode.frameAnimation);
                }
                this._navigator.evaluateBackNavigationStatusForNextTransition();
            }
        }
        _onGoBack() {
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("GoBack");
            this._stopSpeech();
            this._navigateHelper(() => {
                this._navigator.goBack();
            });
        }
        _onSkip() {
            this._resetErrorPageNavigationFailureCount();
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("SkippingWebapp");
            this._stopSpeech();
            this._navigateHelper(() => {
                this._navigator.skipCurrentApp(this._navigator.getResumeNode());
            });
        }
        _onRetry() {
            this._resetErrorPageNavigationFailureCount();
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("Retry");
            this._stopSpeech();
            CloudExperienceHost.Storage.SharableData.addValue("resumeCXHId", this._navigator.getResumeNode().cxid);
            CloudExperienceHost.Storage.SharableData.addValue("OOBEResumeEnabled", true);
            this._navigator.resetBackNavigationStatusForNextTransition();
            this.restart(this._description.source.replace(this._description.query, ""));
        }
        _logDuplicateWebAppTerminationAttempt(eventName, result) {
            let errorObj = new Error();
            let logResult = {
                currentNode: this._currentNode ? this._currentNode.cxid : "unknown",
                result: result,
                stack: errorObj.stack
            };
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2(eventName, JSON.stringify(logResult));
        }
        _onDone(result, isInternalResult) {
            if (this._processingWebAppTerminationMessage && this._blockLateWebAppCalls()) {
                Debug.break("Second WebApp termination message reported while navigating to next node");
                if (isInternalResult) {
                    this._logDuplicateWebAppTerminationAttempt("DuplicateInternalDone", result);
                    return;
                }
                if (this._currentNode && this._currentNode.launcher) {
                    this._logDuplicateWebAppTerminationAttempt("DuplicateLauncherDone", result);
                    return;
                }
                this._logDuplicateWebAppTerminationAttempt("DuplicateWebAppDone", result);
                this._crashCxh(new Error("CrashAppOnDuplicateWebAppDone"));
            }
            this._processingWebAppTerminationMessage = true;
            this._ticketRequestId = null;
            this._stopVisibilityTimer();
            this._stopShowProgressWhenPageIsBusyTimer();
            if (this._blockLateWebAppCalls()) {
                this._bridge.disconnectFromWebView();
            }
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("Done", result);
            this._stopSpeech();
            if (this._currentNode) {
                CloudExperienceHost.StateManager.getInstance().onDone(this._currentNode, result);
                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyWebAppStatusChanged(this._currentNode.cxid, CloudExperienceHostAPI.WebAppStatus.done);
            }
            if (!this._currentNode || (typeof (this._currentNode.ignoreResult) === 'undefined') || (this._currentNode.ignoreResult === false)) {
                this._appResult = CloudExperienceHost.AppResult.getExternalAppResult(result);
            }
            if ((this._platform === CloudExperienceHost.TargetPlatform.XBOX) &&
                (this._appResult === CloudExperienceHost.AppResult.fail) &&
                isInternalResult) {
                this._appResult = this._failFromCxh;
            }
            if (this._navigator.webAppDone(result)) {
                this._navigateHelper(() => {
                    let completeNavigation = function () {
                        this._processingWebAppTerminationMessage = false;
                        this._navigator.goNext();
                    }.bind(this);
                    if (this._blockLateWebAppCalls()) {
                        this._navigator.clearWebView().done(() => {
                            completeNavigation();
                        }, (e) => {
                            Debug.break("Failed to clear the webview after a page was done");
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("ClearWebViewFailure", CloudExperienceHost.GetJsonFromError(e));
                            completeNavigation();
                        });
                    }
                    else {
                        completeNavigation();
                    }
                });
            }
            else {
                if (this._navigator.getNavMesh().getErrorNode() === this._navigator.getCurrentNode()) {
                    this._tryLoadInclusiveErrorApp("InclusiveError App failed to load");
                }
                else if (this._navigator.getNavMesh().blockEarlyExit() && this._navigator.getCurrentNode() &&
                    (!this._navigator.getCurrentNode().canExitCxh || !CloudExperienceHost.AppResult.doesResultAllowExit(result))) {
                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logCriticalEvent2("UnexpectedResultFromWebapp", JSON.stringify({ cxid: this._navigator.getCurrentNode().cxid, result: result }));
                    this._processingWebAppTerminationMessage = false;
                    CloudExperienceHost.Storage.SharableData.addValue("OOBEResumeEnabled", false);
                    this._navigator.resetBackNavigationStatusForNextTransition();
                    this.restart(this._description.source.replace(this._description.query, ""));
                }
                else {
                    this._close();
                }
            }
        }
        _onNavigate(e, contextHeaders) {
            var target = ((typeof e === "string") ? new CloudExperienceHost.RedirectEventArgs(e) : e);
            if (target.url.split(':')[0] === 'ms-aadj-redir') {
                return;
            }
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("Navigate", JSON.stringify({
                httpMethod: target.httpMethod,
                url: CloudExperienceHost.UriHelper.RemovePIIFromUri(target.url)
            }));
            this._navigateHelper(() => {
                this._navigator.redirect(target, contextHeaders);
            });
        }
        _onShowProgressWhenPageIsBusy(callerTimeout) {
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("showProgressWhenPageIsBusy");
            this._stopVisibilityTimer();
            this._stopShowProgressWhenPageIsBusyTimer();
            this._startShowProgressWhenPageIsBusyTimer(callerTimeout);
            this._appView.showProgress();
        }
        _onShowEaseOfAccessControl(boundingRectOfEOAButton) {
            if (!boundingRectOfEOAButton) {
                var boundingRectangleOfWindow = this._appView.getBoundingClientRect();
                boundingRectOfEOAButton = {
                    left: boundingRectangleOfWindow.left,
                    top: boundingRectangleOfWindow.bottom,
                    right: boundingRectangleOfWindow.left,
                    bottom: boundingRectangleOfWindow.bottom
                };
            }
            CloudExperienceHost.showEaseOfAccessFlyout(boundingRectOfEOAButton).then(function () {
            }, function (e) {
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent(e);
            });
        }
        _onLoadIdentityProvider(signInIdentityProvider) {
            if (this._processingWebAppTerminationMessage && this._blockLateWebAppCalls()) {
                this._logDuplicateWebAppTerminationAttempt("DuplicateLoadIdentityProvider", signInIdentityProvider);
                return;
            }
            this._processingWebAppTerminationMessage = true;
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("LoadIdentityProvider", signInIdentityProvider);
            this._navigateHelper(() => {
                this._navigator.loadIdentityProvider(signInIdentityProvider);
                this._processingWebAppTerminationMessage = false;
            });
        }
        _onTicketError(targetUrl, errorMsg, errorCode, localErrorHandlingMode) {
            var logData = new Object;
            logData["cxid"] = this._currentNode && this._currentNode.cxid;
            logData["errorCode"] = errorCode || null;
            logData["message"] = errorMsg || null;
            logData["targetUrl"] = targetUrl;
            CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("TicketRequestError", JSON.stringify(logData));
            var error = null;
            switch (errorCode) {
                case -2147023665:
                    error = Windows.Web.WebErrorStatus.serverUnreachable;
                    break;
            }
            if ((localErrorHandlingMode == CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabled)
                || ((localErrorHandlingMode == CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabledForKnownErrors) && error)) {
                this._onError(new CloudExperienceHost.NavigationError(error, targetUrl, this._currentNode, errorMsg || errorCode.toString()));
                return true;
            }
            return false;
        }
        _onTicketRequestComplete(targetUrl, result) {
            if (targetUrl) {
                this._navigator.redirect(new CloudExperienceHost.RedirectEventArgs(targetUrl, null, result, result ? "POST" : "GET"));
            }
            else {
                this._onTicketError(targetUrl, result, -2147012891 /* WININET_E_INVALID_URL */, CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabled);
            }
        }
        _onPostTicketToReturnUrl(data) {
            this._msaUIHandler = this._msaUIHandler || new CloudExperienceHost.MSAUIHandlerInternal(this._appView);
            this._msaUIHandler.clearTokenBrokerOperation();
            let currentCxid = this._currentNode ? this._currentNode.cxid : "";
            let uniqueid = currentCxid + '_' + Math.random().toString(16).slice(2);
            this._ticketRequestId = uniqueid;
            data.ticketRequestId = uniqueid;
            var msaTicketContext = this._navigator.getNavMesh().getMsaTicketContext();
            data.msaTicketBroker = this._navigator.getNavMesh().getMsaTicketBroker() || false;
            this._msaUIHandler.requestTicketForUrl(data, msaTicketContext, function (e, contextHeaders, privateProperties) {
                if (this._ticketRequestId === data.ticketRequestId) {
                    if (typeof (privateProperties) !== 'undefined' && privateProperties !== null) {
                        for (var iterator = privateProperties.first(); iterator.hasCurrent; iterator.moveNext()) {
                            CloudExperienceHost.Storage.PrivateData.addItem(iterator.current.key, iterator.current.value);
                        }
                    }
                    this._navigator.setRedirectForPostTicketInterrupt(true);
                    this._onNavigate(e, contextHeaders);
                }
                else {
                    let logDetails = { thisRequestId: this._ticketRequestId, callbackRequestId: data.ticketRequestId };
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PostTicketToReturnUrlInterrupt", JSON.stringify(logDetails));
                }
            }.bind(this)).done(
            function (redirectArgs) {
                if (this._ticketRequestId === data.ticketRequestId) {
                    this._navigator.redirect(redirectArgs);
                }
                else {
                    let logDetails = { thisRequestId: this._ticketRequestId, callbackRequestId: data.ticketRequestId };
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PostTicketToReturnUrlCompleteDispatch", JSON.stringify(logDetails));
                }
            }.bind(this), 
            function (error) {
                if (this._ticketRequestId === data.ticketRequestId) {
                    var localErrorHandlingMode = data.errorUrl ? CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabledForKnownErrors : CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabled;
                    if (!this._onTicketError(data.targetUrl, "", error.number, localErrorHandlingMode)) {
                        this._navigator.setRedirectForPostTicketInterrupt(true);
                        this._navigator.redirect(new CloudExperienceHost.RedirectEventArgs(data.errorUrl, "ticketError", error.number, "POST"));
                    }
                }
                else {
                    let logDetails = { thisRequestId: this._ticketRequestId, callbackRequestId: data.ticketRequestId };
                    CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PostTicketToReturnUrlErrorDispatch", JSON.stringify(logDetails));
                }
            }.bind(this));
        }
        _onRegisterNGCForUser(data) {
            this._msaUIHandler = this._msaUIHandler || new CloudExperienceHost.MSAUIHandlerInternal(this._appView);
            let msaTicketContext = this._navigator.getNavMesh().getMsaTicketContext() || "";
            let experienceName = CloudExperienceHost.ExperienceDescription.getExperience(this._description);
            data.msaTicketBroker = this._navigator.getNavMesh().getMsaTicketBroker() || false;
            this._msaUIHandler.registerNGCForUser(data, msaTicketContext, experienceName, this._onNavigate.bind(this)).done(this._onTicketRequestComplete.bind(this), function (destinationUrl) {
                this._navigator.redirect(new CloudExperienceHost.RedirectEventArgs(destinationUrl));
            }.bind(this));
        }
        _onResetNGCForUser(data) {
            this._msaUIHandler = this._msaUIHandler || new CloudExperienceHost.MSAUIHandlerInternal(this._appView);
            let msaTicketContext = this._navigator.getNavMesh().getMsaTicketContext() || "";
            let experienceName = CloudExperienceHost.ExperienceDescription.getExperience(this._description);
            data.msaTicketBroker = this._navigator.getNavMesh().getMsaTicketBroker() || false;
            this._msaUIHandler.resetNGCForUser(data, msaTicketContext, experienceName, this._onNavigate.bind(this)).done(this._onTicketRequestComplete.bind(this), function (destinationUrl) {
                this._navigator.redirect(new CloudExperienceHost.RedirectEventArgs(destinationUrl));
            }.bind(this));
        }
        _onPostDeviceTicketToUrl(data) {
            var targetUrl = data.targetUrl;
            var policy = data.policy;
            var guid = "49BB5C55-7CF8-49EA-BE52-9FEC226F728C"; // Value is only used for analytics
            let currentCxid = this._currentNode ? this._currentNode.cxid : "";
            let uniqueid = currentCxid + '_' + Math.random().toString(16).slice(2);
            this._ticketRequestId = uniqueid;
            data.ticketRequestId = uniqueid;
            this._appView.showProgress().then(function () {
                let msaExtension = new MicrosoftAccount.Extension.ExtensionWorkerForUser();
                let user = null;
                user = CloudExperienceHost.IUserManager.getInstance().getIUser();
                msaExtension.getDeviceTicketForWebFlowForUserAsync(user, targetUrl, policy, guid).done(function (result) {
                    if (this._ticketRequestId === data.ticketRequestId) {
                        this._onTicketRequestComplete(result.lookup("ResultUrl"), result.lookup("Ticket"));
                    }
                    else {
                        let logDetails = { thisRequestId: this._ticketRequestId, callbackRequestId: data.ticketRequestId };
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PostDeviceTicketToUrlDone", JSON.stringify(logDetails));
                    }
                }.bind(this), function (error) {
                    if (this._ticketRequestId === data.ticketRequestId) {
                        this._onTicketError(targetUrl, error.message, error.number, CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabled);
                    }
                    else {
                        let logDetails = { thisRequestId: this._ticketRequestId, callbackRequestId: data.ticketRequestId };
                        CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("PostDeviceTicketToUrlError", JSON.stringify(logDetails));
                    }
                }.bind(this));
            }.bind(this));
        }
        _onPostSharedAccountRegistrationTicketsToUrl(data) {
            let targetUrl = data.targetUrl;
            let policy = data.policy;
            let guid = "49BB5C55-7CF8-49EA-BE52-9FEC226F728C"; // Value is only used for analytics
            this._appView.showProgress().then(function () {
                let userTicketRedirectArgs = null;
                let deviceTicketRedirectArgs = null;
                this._msaUIHandler = this._msaUIHandler || new CloudExperienceHost.MSAUIHandlerInternal(this._appView);
                CloudExperienceHost.Telemetry.WebAppTelemetry.getInstance().logEvent("onPostSharedAccountRegistrationTicketsToUrl", this._currentNode ? this._currentNode.cxid : "");
                this._msaUIHandler.clearTokenBrokerOperation();
                let msaTicketContext = this._navigator.getNavMesh().getMsaTicketContext();
                let getUserTicket = this._msaUIHandler.requestTicketForUrl(data, msaTicketContext, this._onNavigate.bind(this));
                getUserTicket.done(function (userRedirectArgs) {
                    userTicketRedirectArgs = userRedirectArgs;
                }.bind(this), function (error) {
                    this._onTicketError(data.targetUrl, "", error.number, CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabled);
                }.bind(this));
                let msaExtension = new MicrosoftAccount.Extension.ExtensionWorkerForUser();
                let user = null;
                user = CloudExperienceHost.IUserManager.getInstance().getIUser();
                let getDeviceTicket = msaExtension.getSharedAccountDeviceTicketForWebFlowForUserAsync(user, targetUrl, policy, guid);
                getDeviceTicket.done(function (deviceRedirectArgs) {
                    deviceTicketRedirectArgs = deviceRedirectArgs;
                }.bind(this), function (error) {
                    this._onTicketError(targetUrl, error.message, error.number, CloudExperienceHost.LocalErrorHandlingMode.LocalErrorHandlingEnabled);
                }.bind(this));
                WinJS.Promise.join({
                    getUserTicket: getUserTicket,
                    getDeviceTicket: getDeviceTicket
                }).done(function () {
                    let deviceTicket = deviceTicketRedirectArgs.lookup("Ticket");
                    let deviceTicketStart = deviceTicket.indexOf("t=");
                    if (deviceTicketStart == -1) {
                        deviceTicket = null;
                    }
                    else {
                        let deviceTicketEnd = deviceTicket.indexOf("&", deviceTicketStart);
                        if (deviceTicketEnd == -1) {
                            deviceTicket = deviceTicket.substring(deviceTicketStart + 2);
                        }
                        else {
                            deviceTicket = deviceTicket.substring(deviceTicketStart + 2, deviceTicketEnd);
                        }
                    }
                    if (userTicketRedirectArgs.value && deviceTicket) {
                        userTicketRedirectArgs.value = userTicketRedirectArgs.value + "&d=" + deviceTicket;
                    }
                    this._navigator.redirect(userTicketRedirectArgs);
                }.bind(this));
            }.bind(this));
        }
        _close() {
            this._cxhReadyToClose = true;
            var cxhResult = (this._appResult !== CloudExperienceHost.AppResult.fail);
            let checkpointsEnabled = CloudExperienceHost.getNavMesh().checkpointsEnabled();
            if ((this._appResult === CloudExperienceHost.AppResult.success) && checkpointsEnabled) {
                CloudExperienceHost.Storage.SharableData.removeValue("resumeCXHId");
            }
            Windows.Networking.Connectivity.NetworkInformation.onnetworkstatuschanged = null;
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().stop(this._appResult);
            CloudExperienceHost.StateManager.getInstance().clean();
            try {
                if (this._resultsOperation != null) {
                    var valueSet = new Windows.Foundation.Collections.ValueSet();
                    valueSet.insert("Result", this._appResult);
                    this._resultsOperation.reportCompleted(valueSet);
                }
                else {
                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").reportResult(cxhResult);
                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").reportSubResult(this._appResult);
                }
                if (!CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeHostAppInDefaultUserSession")) {
                    if (CloudExperienceHost.getContext().host.toLowerCase() === "frx") {
                        AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyOobeReadyStateChanged(false);
                    }
                }
                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.AppEventNotificationManager").notifyAppFinished(cxhResult, this._appResult);
                if (this._navigator && this._navigator.getNavMesh() && this._navigator.getNavMesh().getNotifyOnLastFinished()) {
                    if (this._navigator.getNavMesh().endFadeTransition()) {
                        let blackOverlay = document.createElement('div');
                        blackOverlay.setAttribute('class', 'black-overlay');
                        document.body.appendChild(blackOverlay);
                        blackOverlay.classList.add('fade-in-overlay');
                        blackOverlay.addEventListener("animationend", () => {
                            if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeHostAppInDefaultUserSession")) {
                                let shouldSkipNotifyOnLastFinished = (CloudExperienceHost.Storage.VolatileSharableData.getItem("OobePrepTransitionToNextAppValues", "launchNextApp") === true);
                                CloudExperienceHost.Storage.VolatileSharableData.removeItem("OobePrepTransitionToNextAppValues", "launchNextApp");
                                if (shouldSkipNotifyOnLastFinished) {
                                    CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("SkipNotifyOnLastFinished");
                                    this._closeWindowAndTerminateApp();
                                    return;
                                }
                                else {
                                    AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").onLastOOBEWebAppFinished(cxhResult, this._appResult);
                                }
                            }
                            else {
                                AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").onLastOOBEWebAppFinished(cxhResult, this._appResult);
                            }
                        });
                    }
                    else {
                        AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Synchronization").onLastOOBEWebAppFinished(cxhResult, this._appResult);
                    }
                    this._navManager.notifyEvent(CloudExperienceHost.NavigationEvent.LastWebAppFinished, undefined);
                    if (this._navigator.getNavMesh().getWaitForTaskbarReady()) {
                        CloudExperienceHostAPI.Synchronization.waitForTaskbarReadyAsync(30000 /* timeoutMs */).then(() => {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("WaitForTaskbarReady", "Success");
                            Windows.UI.ViewManagement.ApplicationView.getForCurrentView().tryConsolidateAsync().then((success) => {
                                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("TryConsolidateApplicationViewCrossfade", JSON.stringify(success));
                                if (!success) {
                                    this._closeWindowAndTerminateApp();
                                }
                                else {
                                    setTimeout(() => {
                                        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("TryConsolidateApplicationViewCrossfade", "Timeout");
                                        this._closeWindowAndTerminateApp();
                                    }, 5000);
                                }
                            }, (error) => {
                                CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("TryConsolidateApplicationViewCrossfadeFailed", CloudExperienceHost.GetJsonFromError(error));
                                this._closeWindowAndTerminateApp();
                            });
                        }, (error) => {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("WaitForTaskbarReadyFailed", CloudExperienceHost.GetJsonFromError(error));
                            this._closeWindowAndTerminateApp();
                        });
                    }
                }
                else {
                    this._closeWindowAndTerminateApp();
                }
            }
            catch (error) {
                AppManager.prototype.onUnhandledException = () => {
                    return null;
                };
                throw error;
            }
        }
        _closeWindowAndTerminateApp() {
            window.close();
            CloudExperienceHostAPI.AppLifetimeManager.terminateApp();
        }
        _getResultOperationForXbox() {
            var resultOperation = null;
            if (CloudExperienceHost.Environment.getPlatform() === CloudExperienceHost.TargetPlatform.XBOX) {
                try {
                    var tcuiContext = Windows.Xbox.UI.Internal.TCUIStateManager.getContext();
                    if (tcuiContext != null) {
                        resultOperation = new CloudExperienceHost.XboxTcuiContext(tcuiContext);
                    }
                }
                catch (e) {
                    this.onUnhandledException(e);
                }
            }
            return resultOperation;
        }
    }
    AppManager._globalBridgeInstance = null;
    CloudExperienceHost.AppManager = AppManager;
})(CloudExperienceHost || (CloudExperienceHost = {}));
