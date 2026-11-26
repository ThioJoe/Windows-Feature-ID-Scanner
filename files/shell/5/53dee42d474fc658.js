
define(['legacy/core'], (core) => {

    class OobeCloudContentHydrant {

        refreshFeatureConfigurations() {
            if (!CloudExperienceHost.Environment.hasInternetAccess()) {
                return WinJS.Promise.as(CloudExperienceHost.AppResult.abort);
            }

            CloudExperienceHost.Telemetry.logEvent("flightDataRefreshStarted");
            return CloudExperienceHostAPI.UtilStaticsCore.tryRefreshWindowsFlightDataAsync().then((completed) => {
                CloudExperienceHost.Telemetry.logEvent("flightDataRefresh" + (completed ? "Completed" : "Timeout"));
                return CloudExperienceHost.getWindowsFlightDataAsync();
            }).then(() => {
                CloudExperienceHost.Telemetry.logEvent("flightDataRefreshDataRetrieved");
                return CloudExperienceHost.AppResult.success;
            }, (err) => {
                CloudExperienceHost.Telemetry.logEvent("flightDataRefreshFailed", core.GetJsonFromError(err));
                return CloudExperienceHost.AppResult.fail;
            });
        }

        notifyAutopilotProfile() {
            CloudExperienceHost.Telemetry.logEvent("Autopilot_CloudContentHydrant_notifyAutopilotProfile_start");
            return EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.setAutopilotDeviceNotManagedAsync(0);
        }

        launchAsync() {
            return WinJS.Promise.join({ featureConfigResult: this.refreshFeatureConfigurations(), autopilotNotifyResult: this.notifyAutopilotProfile() }).then((results) => {
                return results.featureConfigResult;
            });
        }

    }

    return OobeCloudContentHydrant;
});