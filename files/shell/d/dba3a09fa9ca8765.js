
define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/appObjectFactory'], (ko, bridge, constants, appObjectFactory) => {
    class AutopilotActivationViewModel {
        constructor(resourceStrings, targetPersonality) {
            this.FINALIZATION_INTERVAL_WAIT_TIME_IN_MILLISECONDS = 500; // half a second intervals
            this.DELAY_TIME_BEFORE_EXITING_PAGE_IN_MILLISECONDS = 1000; // one second
            this.activationText = ko.observable(resourceStrings.ActivationText);
            this.autoPilotSubscriptionManager = new EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotWnfSubscriptionManager();
            this.connectionProfile = Windows.Networking.Connectivity.NetworkInformation.getInternetConnectionProfile();
            this.profileAvailableTimeout = null;
            this.finalResult = null;

            this.shouldShowDesktopLiteView = ko.observable(targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite);

            this.populateZTPPolicyCache();

            this.profileAvailableTimeout = WinJS.Promise.timeout(180000/*3 minutes */).then(() => {
                this.autoPilotSubscriptionManager.removeEventListener("profileavailable", this.onProfileAvailable.bind(this));
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_RetrievingAutopilotProfileTimeout");
                this.activationText(resourceStrings.ActivationErrorText);

                WinJS.Promise.timeout(5000 /*5 second timeout*/).then(
                    () => {
                        this.connectionProfile.tryDeleteAsync().done(
                            (result) => {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_DeleteWifiProfileAsyncResult", result);
                            },

                            (e) => {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_DeleteWifiProfileAsyncError", JSON.stringify({ number: e && e.number.toString(16), stack: e && e.asyncOpSource && e.asyncOpSource.stack }));
                            })

                        bridge.fireEvent(constants.Events.done, constants.AppResult.fail);
                    });
            });

            this.autoPilotSubscriptionManager.addEventListener("profileavailable", this.onProfileAvailable.bind(this));
        }

        populateZTPPolicyCache() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_populateZTPPolicyCacheStarted");
            let startTime = performance.now();
            let populateAutoPilotPoliciesPromise = EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.retrieveSettingsAsync().then(
                () => {
                    let details = { timeElapsed: performance.now() - startTime };
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_oobeZTPCacheReturned", JSON.stringify(details));
                },

                (error) => {
                    let errorJson = core.GetJsonFromError(error);
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_oobeZTPCacheFailure", errorJson);
                });

            setImmediate(() => { populateAutoPilotPoliciesPromise });
        }

        onProfileAvailable(hresult) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_AutopilotProfileAvailableNotificationReceived");
            if (this.profileAvailableTimeout != null) {
                this.profileAvailableTimeout.cancel();
                this.profileAvailableTimeout = null;
            }

            EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.getProfileStateAsync().then(
                (result) => {
                    if (EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotProfileState.notProvisioned == result) {
                        EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.clearNetworkRequiredFlagAsync().then(
                            (res) => {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_ClearedNetworkRequiredFlagAsync")
                            },

                            (e) => {
                                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_ErrorClearingNetworkRequiredFlagAsync", JSON.stringify({ number: e && e.number.toString(16), stack: e && e.asyncOpSource && e.asyncOpSource.stack }));
                            });
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_AutopilotProfileNotExist");

                    } else if (EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotProfileState.available == result) {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_AutopilotProfileExist");

                    } else {
                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_AutopilotProfileState", result);
                    }

                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_SetSignalToExitPageWhenVisible");

                    this.finalResult = constants.AppResult.success;
                },

                (e) => {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_ErrorReadingAutopilotProfileState", JSON.stringify({ number: e && e.number.toString(16), stack: e && e.asyncOpSource && e.asyncOpSource.stack }));
                });
        }

        setIsPageVisibleAsync() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_CheckWhetherToExitSincePageIsVisible");

            if (this.finalResult === constants.AppResult.success) {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_FireSuccessEventToExitPage");

                return WinJS.Promise.timeout(this.DELAY_TIME_BEFORE_EXITING_PAGE_IN_MILLISECONDS).then(() => {
                    bridge.fireEvent(constants.Events.done, constants.AppResult.success);
                });
            }

            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Autopilot_ActivationPage_WaitBeforeCheckingAgainWhetherToExitPage");

            return WinJS.Promise.timeout(this.FINALIZATION_INTERVAL_WAIT_TIME_IN_MILLISECONDS).then(() => {
                return this.setIsPageVisibleAsync();
            });
        }
    }
    return AutopilotActivationViewModel;
});
