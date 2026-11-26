
define(['lib/knockout', 'legacy/bridge', 'legacy/appObjectFactory', 'legacy/events', 'legacy/core'], (ko, bridge, appObjectFactory, constants, core) => {
    class AutopilotRebootViewModel {
        constructor(resourceStrings, targetPersonality) {
            this.rebootMessageText = ko.observable(resourceStrings.UpdateMessageRestartText);

            this.isLiteWhitePersonality = ko.pureComputed(() => {
                return targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite;
            });

            WinJS.Promise.timeout(3000 /*3 second timeout*/).then(() => {
                this.renameDeviceAsync();
            });
        }

        renameDeviceAsync() {
            let autopilotServer = new EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotServer();
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeAutopilotDeviceRenameStarted");

            autopilotServer.getStringPolicyAsync("CloudAssignedDeviceName").then(function (policyValue) {

                if ((policyValue !== null) && (policyValue !== "")) {
                autopilotServer.getStringPolicyAsync("CloudAssignedDeviceNameLastProcessed").then(function (policyValueLastProcessed) {
                    if (policyValue === policyValueLastProcessed) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CloudAssignedDeviceName: Info: Skip since the same name had already been set");
                        bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                    } else {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Device rename required by Autopilot policy");

                        autopilotServer.renameDeviceAsync(policyValue).then(function () {
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot device rename completed");

                            bridge.invoke("CloudExperienceHost.setRebootForOOBE");

                            bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                        }.bind(this), function (err) {
                            let errorJson = core.GetJsonFromError(err);
                            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CloudAssignedDeviceName: Failed: renameDeviceAsync", errorJson);

                            bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
                        }.bind(this));
                    }
                }.bind(this), function (err) {
                    let errorJson = core.GetJsonFromError(err);
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot device rename failed", errorJson);
                    bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
                }.bind(this));
                } else {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot device rename not required");
                    bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                }
            }, function (err) {
                let errorJson = core.GetJsonFromError(err);
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot device rename failed", errorJson);
                bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
            });
        }
    }

    return AutopilotRebootViewModel;
});
