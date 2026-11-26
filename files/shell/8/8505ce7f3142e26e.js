(function () {
    "use strict";

    var app = WinJS.Application;
    var activation = Windows.ApplicationModel.Activation;
    var appManager = null;
    let canShowUI = false;
    let areFrameComponentsRegistered = false;

    navigator.gamepadInputEmulation = "keyboard"; // The gamepad input should produce XYFocus style keyboard events.

    app.onactivated = function (args) {
        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AppActivated", JSON.stringify({ 'Kind': args.detail.kind, 'PreviousExecutionState': args.detail.previousExecutionState }));

        let clearTempWebDataOp = null;

        if (args.detail.kind === activation.ActivationKind.webAccountProvider ||
            args.detail.kind === activation.ActivationKind.componentUI) {
            clearTempWebDataOp = MSApp.clearTemporaryWebDataAsync();
            appManager = new CloudExperienceHost.MSATokenProviderManager();
        } else {
            clearTempWebDataOp = MSApp.clearTemporaryWebDataAsync();
            appManager = new CloudExperienceHost.AppManager();
            let argsWithUser = args.detail;
            if (argsWithUser) {
                CloudExperienceHost.IUserManager.getInstance().setIUser(argsWithUser.user);
            }
        }

        require.config(new RequirePathConfig('/core'));

        args.setPromise(requireAsync(['lib/knockout', 'knockouthelpers', 'default-vm', 'legacy/appViewManager', 'legacy/navigationManager', 'lib/knockout-winjs', 'optional!sample/SampleImplementationCollection']).then((result) => {
            let ko = result.lib_knockout;
            let KnockoutHelpers = result.knockouthelpers;
            let DefaultViewModel = result.default_vm;
            let appViewManager = result.legacy_appViewManager;
            let navManager = result.legacy_navigationManager;
            return appManager.initialize(args).then(function () {
                appViewManager.loadCss();

                let knockoutHelpers = new KnockoutHelpers();
                if (!areFrameComponentsRegistered) {
                    knockoutHelpers.registerComponents(CloudExperienceHost.RegisterComponentsScenarioMode.Default);
                    areFrameComponentsRegistered = true;
                }

                let rootElement = document.getElementById("_defaultRoot");
                let isBound = ko.dataFor(rootElement);
                if (isBound) {
                    ko.cleanNode(rootElement);
                }

                let navMesh = appManager.getDiscoveryNavMesh();
                let frameName = "default-frame";
                if (navMesh) {
                    let meshFrameName = appManager.getDiscoveryNavMesh().getFrameName();  // "default-frame", "oobe-frame" or "sspr-frame"
                    if (meshFrameName) {
                        frameName = meshFrameName;
                    }
                }

                appManager.setAppViewManager(appViewManager);
                appManager.setNavManager(navManager);
                ko.applyBindings(new DefaultViewModel(frameName), rootElement);
                return KnockoutHelpers.waitForInitialComponentLoadAsync();
            }).then(() => {
                return WinJS.UI.processAll();
            }).then(function () {
                canShowUI = true;

                let appManagerStartFunction = function () {
                    switch (args.detail.previousExecutionState) {
                        case activation.ApplicationExecutionState.notRunning:       /* The app is not running */
                        case activation.ApplicationExecutionState.closedByUser:     /* The app was closed by the user */
                            appManager.start(args);
                            break;

                        case activation.ApplicationExecutionState.suspended:        /* The app is suspended */
                            break;
                        case activation.ApplicationExecutionState.terminated:       /* The app was terminated after being suspended */
                            appManager.resume(args);
                            break;

                        case activation.ApplicationExecutionState.running:          /* The app is running */
                            appManager.start(args);
                            break;

                        default:
                            throw new Error(CloudExperienceHost.ErrorNames.ActivationNotSupported);
                    }
                };

                if (clearTempWebDataOp) {
                    clearTempWebDataOp.oncomplete = function () {
                        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("ClearTemporaryWebDataAsyncSucceeded");
                        appManagerStartFunction();
                    };
                    clearTempWebDataOp.onerror = function () {
                        if (Windows.System.Profile.SystemSetupInfo.outOfBoxExperienceState == Windows.System.Profile.SystemOutOfBoxExperienceState.completed) {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("ClearTemporaryWebDataAsyncFailed", "Fatal");
                            window.close();
                        } else {
                            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("ClearTemporaryWebDataAsyncFailed", "NonFatal");
                            appManagerStartFunction();
                        }
                    };
                    clearTempWebDataOp.start();
                }
                else {
                    appManagerStartFunction();
                }

                let gamepadEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("GamepadEnabledOobe");
                if (gamepadEnabledObj.result && gamepadEnabledObj.value && CloudExperienceHostAPI.AppLifetimeManager && CloudExperienceHostAPI.AppLifetimeManager.enableGamepadVKeysForProcessLifetime) {
                    try {
                        CloudExperienceHostAPI.AppLifetimeManager.enableGamepadVKeysForProcessLifetime();
                    } catch (err) {
                        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("Failed to enable gamepad vkeys for the process");
                    }
                }
            });
        }));
    };

    app.oncheckpoint = function (args) {
        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AppCheckpoint");
        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().appCheckpoint();

        if (appManager) {
            appManager.checkpoint(args);
        }
        else {
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AppCheckpoint with null appManager");
        }
    };

    app.onloaded = function () {
        WinJS.Resources.processAll();
    };

    app.onerror = function (e) {
        if (canShowUI === false) {
            var data = e.detail;
            var logData = new Object;
            logData["errorCode"] = data && (data.number || (data.exception && (data.exception.number || data.exception.code)) || (data.error && data.error.number) || data.errorCode || 0);
            logData["message"] = data && (data.message || data.errorMessage || (data.error && data.error.message) || (data.exception && data.exception.message) || null);
            logData["stack"] = data && (data.stack || (data.exception && (data.exception.stack || data.exception.message)) || (data.error && data.error.stack) || null);
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("UnhandledException", JSON.stringify(logData));
            return null;
        }
        return appManager ? appManager.onUnhandledException(e) : null;
    };

    app.restart = function (uri) {
        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AppRestart", uri);
        if (appManager) {
            appManager.restart(uri);
        }
        else {
            CloudExperienceHost.Telemetry.AppTelemetry.getInstance().logEvent("AppRestart but appManager is not ready", uri);
        }
    };

    app.start();
})();
