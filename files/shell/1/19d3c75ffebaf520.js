
define(['legacy/core'], (core) => {
    class OobeDeviceNameCommit {
        launchAsync() {
            CloudExperienceHost.Telemetry.logEvent("OobeDeviceNameCommitStarted");
            return new WinJS.Promise(function (completeDispatch /*, errorDispatch, progressDispatch */) {
                let deviceName = CloudExperienceHost.Storage.VolatileSharableData.getItem("DeviceNameValues", "DeviceNameChangeRequested");
                if (typeof deviceName === 'string' && deviceName !== "") {
                    CloudExperienceHost.Telemetry.logEvent("OobeDeviceNameCommitStarted_deviceNameChangeRequested");
                    CloudExperienceHostAPI.OobeDeviceNameManager.setDeviceNameAsync(deviceName).then(() => {
                        CloudExperienceHost.Storage.VolatileSharableData.removeItem("DeviceNameValues", "DeviceNameChangeRequested");
                        CloudExperienceHost.setRebootForOOBE();

                        CloudExperienceHost.Telemetry.logEvent("OobeDeviceNameCommit_setDeviceNameAsync_succeeded");
                        completeDispatch(CloudExperienceHost.AppResult.success);
                    }, (err) => {
                        CloudExperienceHost.Telemetry.logEvent("OobeDeviceNameCommit_setDeviceNameAsync_failed", core.GetJsonFromError(err));
                        completeDispatch(CloudExperienceHost.AppResult.error);
                    });
                }
                else {
                    CloudExperienceHost.Telemetry.logEvent("OobeDeviceNameCommit_setDeviceNameAsync_invalidName");
                    completeDispatch(CloudExperienceHost.AppResult.cancel);
                }
            });
        }
    }
    return OobeDeviceNameCommit;
});