//
// Copyright (C) Microsoft. All rights reserved.
//

define(() => {
    class OobePrepEndUserSession {
        launchAsync() {
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                CloudExperienceHostAPI.UtilStaticsCore.prepEnduserSessionAsync().then(() => {
                    CloudExperienceHost.Telemetry.logEvent("StartEnduserOobeSessionTransition");
                    if (CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled("SaveSharableDataForEnduserSession")) {
                        // Save SharableData and VolatileSharableData in registry before moving onto enduser-hosted OOBE
                        // In case of failures, this operation shouldn't block proceeding with the enduser session
                        let sharableDataPromise = CloudExperienceHost.Storage.SharableData.saveDataForOobeAsync();
                        let volatileSharableDataPromise = CloudExperienceHost.Storage.VolatileSharableData.saveDataForOobeAsync();
                        WinJS.Promise.join({ sharableDataPromise, volatileSharableDataPromise }).then(() => {
                            CloudExperienceHost.Telemetry.logEvent("SaveDataForOobeSucceeded");
                            completeDispatch(CloudExperienceHost.AppResult.success);
                        }, (err) => {
                            CloudExperienceHost.Telemetry.logEvent("SaveDataForOobeFailed", CloudExperienceHost.GetJsonFromError(err));
                            completeDispatch(CloudExperienceHost.AppResult.success);
                        });
                    } else {
                        completeDispatch(CloudExperienceHost.AppResult.success);
                    }
                }, (err) => {
                    CloudExperienceHost.Telemetry.logEvent("StartEnduserOobeSessionTransitionFailed", CloudExperienceHost.GetJsonFromError(err));
                    completeDispatch(CloudExperienceHost.AppResult.fail);
                });
            });
        }
    }
    return OobePrepEndUserSession;
});
