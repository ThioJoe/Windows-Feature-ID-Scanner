
define(() => {
    class OOBEReboot {
        launchAsync(currentNode) {
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                if (!currentNode.successID) {
                    CloudExperienceHost.Telemetry.logEvent("SuccessIdNotFound");
                    completeDispatch(CloudExperienceHost.AppResult.error);
                    return;
                }

                let shouldReboot = CloudExperienceHost.Storage.SharableData.getValue("shouldRebootForOOBE");
                if (shouldReboot) {
                    CloudExperienceHost.Storage.SharableData.addValue("OOBEResumeEnabled", true);
                    let resumeCXHId = CloudExperienceHost.Storage.SharableData.getValue("resumeCXHId");
                    if (!resumeCXHId) {
                        CloudExperienceHost.Storage.SharableData.addValue("resumeCXHId", currentNode.successID);
                    }

                    CloudExperienceHostAPI.UtilStaticsCore.clearAutoLogonCredentialsAsync(true /* onlyClearConnectedCredentials */).then(() => {
                        CloudExperienceHost.Telemetry.logEvent("clearAutoLogonCredentialsAsyncSucceeded");
                    }, (err) => {
                        CloudExperienceHost.Telemetry.logEvent("clearAutoLogonCredentialsAsyncFailed", CloudExperienceHost.GetJsonFromError(err));
                    }).then(() => {
                        CloudExperienceHost.Telemetry.oobeHealthEvent(CloudExperienceHostAPI.HealthEvent.expectedMachineNoErrorReboot, 0 /* Unused Result Parameter */);
                        CloudExperienceHost.Telemetry.AppTelemetry.getInstance().expectedReboot();
                        CloudExperienceHostAPI.UtilStaticsCore.restartAsync().done(function () { }, function (err) { completeDispatch(CloudExperienceHost.AppResult.fail); });
                    });
                }
                else {
                    completeDispatch(CloudExperienceHost.AppResult.success);
                }
            });
        }
    }
    return OOBEReboot;
});
