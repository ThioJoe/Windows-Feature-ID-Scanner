
define(() => {
    class OobePrepTransitionToNextApp {
        launchAsync() {
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                CloudExperienceHost.Telemetry.logEvent("OobePrepTransitionToNextAppStart");
                CloudExperienceHost.Storage.VolatileSharableData.addItem("OobePrepTransitionToNextAppValues", "launchNextApp", false);

                try {
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

                    completeDispatch(CloudExperienceHost.AppResult.success);
                } catch (err) {
                    CloudExperienceHost.Telemetry.logEvent("SetDefaultUserSessionNextAppLaunchFailed", CloudExperienceHost.GetJsonFromError(err));
                    completeDispatch(CloudExperienceHost.AppResult.fail);
                }
            });
        }
    }
    return OobePrepTransitionToNextApp;
});