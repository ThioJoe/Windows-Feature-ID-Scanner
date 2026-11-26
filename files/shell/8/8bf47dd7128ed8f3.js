
define(() => {
    class OobePrepTransitionToNextApp {
        launchAsync() {
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                CloudExperienceHost.Telemetry.logEvent("OobePrepTransitionToNextAppStart");
                CloudExperienceHost.Storage.VolatileSharableData.addItem("OobePrepTransitionToNextAppValues", "launchNextApp", false);

                try {
                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OHAOobeZDPResiliency")) {
                        let redirectionManager = CloudExperienceHostAPI.Redirection.RedirectionManager.getForUri("ms-cxh://oobe/defaultusersession");
                        if (!redirectionManager) {
                            CloudExperienceHost.Telemetry.logEvent("OobePrepTransitionToNextAppNotReady");
                            completeDispatch(CloudExperienceHost.AppResult.preloadSkip);
                            return;
                        }
                    }

                    CloudExperienceHostAPI.UtilStaticsCore.setDefaultUserSessionNextAppLaunch(true);
                    CloudExperienceHost.Telemetry.logEvent("SetDefaultUserSessionNextAppLaunchSucceeded");
                    CloudExperienceHost.Storage.VolatileSharableData.addItem("OobePrepTransitionToNextAppValues", "launchNextApp", true);

                    try
                    {
                        CloudExperienceHost.Storage.SharableData.saveDataForOobeDefaultUser();
                        CloudExperienceHost.Storage.VolatileSharableData.saveDataForOobeDefaultUser();
                    }
                    catch (err)
                    {
                        CloudExperienceHost.Telemetry.logEvent("saveDataForOobeDefaultUserFailed", CloudExperienceHost.GetJsonFromError(err));
                    }

                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("OobeProgressTransition")) {
                        try {
                            CloudExperienceHostAPI.UtilStaticsCore.setLaunchProgressTransition(true);
                            CloudExperienceHost.Telemetry.logEvent("SetLaunchProgressTransitionSucceeded");
                        } catch (err) {
                            CloudExperienceHost.Telemetry.logEvent("SetLaunchProgressTransitionFailed", CloudExperienceHost.GetJsonFromError(err));
                            completeDispatch(CloudExperienceHost.AppResult.success);
                            return;
                        }

                        let timeoutMs = 5000;
                        let variantDataObj = CloudExperienceHost.FeatureStaging.tryGetFeatureVariantData("OobeProgressTransition");
                        if (variantDataObj.result && variantDataObj.value > 0) {
                            timeoutMs = variantDataObj.value;
                        }

                        WinJS.Promise.timeout(timeoutMs).then(function () {
                            completeDispatch(CloudExperienceHost.AppResult.success);
                        });
                    } else {
                        completeDispatch(CloudExperienceHost.AppResult.success);
                    }
                } catch (err) {
                    CloudExperienceHost.Telemetry.logEvent("SetDefaultUserSessionNextAppLaunchFailed", CloudExperienceHost.GetJsonFromError(err));
                    completeDispatch(CloudExperienceHost.AppResult.fail);
                }
            });
        }
    }
    return OobePrepTransitionToNextApp;
});