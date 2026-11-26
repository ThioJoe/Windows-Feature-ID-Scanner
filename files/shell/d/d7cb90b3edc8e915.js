
"use strict";

define([
    'legacy/bridge',
    'legacy/events',
    'autopilot/bootstrapStatusSubcategoryViewModel',
    'autopilot/mdmBootstrapSessionUtilities',
    'autopilot/commercialDiagnosticsUtilities'], (
    bridge,
    constants,
    bootstrapStatusSubcategoryViewModel,
    mdmBootstrapSessionUtilities,
    commercialDiagnosticsUtilities) => {

    class deviceSetupCategoryViewModel {
        constructor(resourceStrings, sessionUtilities) {
            this.rebootRequiredToCommitSettingsSettingName = "ESP.Device.rebootRequiredToCommitSettings";
            this.defaultWaitToInitiateSyncSessionsInMilliseconds = 1000; // 1 second

            this.resourceStrings = resourceStrings;
            this.sessionUtilities = sessionUtilities;
            this.mdmBootstrapSessionUtilities = new mdmBootstrapSessionUtilities(
                resourceStrings, 
                this.sessionUtilities.runningInOobe(),
                sessionUtilities);
            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities();
            this.securityPoliciesProvisioningSucceeded = true;
            this.certificatesProvisioningSucceeded = true;
            this.networkProfilesProvisioningSucceeded = true;
            this.appsProvisioningSucceeded = true;

            this.syncSyncSessionsShouldStart = false;
            this.waitForSyncSessionsInitiationPromise = this.waitForSyncSessionsInitiationAsync();

            this.initializationPromise = this.sessionUtilities.autopilotApis.getDeviceAutopilotModeAsync().then((mode) => {
                this.whiteGloveMode = mode;
            });
        }

        waitForSyncSessionsInitiationAsync() {
            if (this.syncSyncSessionsShouldStart) {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDeviceSetup_SyncSessionWaitLoop_StartingSyncSessions",
                    "BootstrapStatus: Start background sync sessions for Device Setup.");

                this.mdmBootstrapSessionUtilities.initiateSyncSessionsAsync(ModernDeployment.Autopilot.Core.SyncSessionExitCondition.deviceSetupComplete);

                return WinJS.Promise.as(true);
            } else {
                return WinJS.Promise.timeout(this.defaultWaitToInitiateSyncSessionsInMilliseconds).then(() => {
                    return this.waitForSyncSessionsInitiationAsync();
                });
            }
        }

        coalesceRebootsAsync() {
            return this.sessionUtilities.getSettingAsync(this.rebootRequiredToCommitSettingsSettingName).then((isRebootRequired) => {
                if (isRebootRequired === "true") {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDeviceSetup_RebootCoalescing_Required",
                        "BootstrapStatus: Coalesced reboot required.");

                    return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                        this.sessionUtilities.SUBCATEGORY_STATE_REBOOT_REQUIRED_AND_TRY_AGAIN,
                        null));
                }

                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                    null));
            });
        }

        sendResultsToMdmServerAsync() {
            try {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDeviceSetup_SendResultsToMdmServer_Started",
                    "BootstrapStatus: Device setup category sending success results to MDM server.");

                this.sessionUtilities.enrollmentApis.updateServerWithResult(true, this.sessionUtilities.runningInOobe());
            } catch (e) {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ESPDeviceSetup_SendResultsToMdmServer_Failed",
                    "Failed to send results to MDM server, likely due to setting an already-failed provisioning status.",
                    e);
            }

            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPDeviceSetup_SendResultsToMdmServer_Succeeded",
                "BootstrapStatus: Device setup category sent success results to MDM server.");

            return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                null));
        }

        saveWhiteGloveSuccessResultAsync() {
            if ((this.whiteGloveMode === EnterpriseDeviceManagement.Service.AutoPilot.AutopilotMode.whiteGloveCanonical) ||
                (this.whiteGloveMode === EnterpriseDeviceManagement.Service.AutoPilot.AutopilotMode.whiteGloveDJPP)) {
                return bridge.invoke("CloudExperienceHost.Storage.SharableData.addValue", this.sessionUtilities.WHITE_GLOVE_SUCCESS_VALUE_NAME, true).then(() => {
                    return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                        this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                        null));
                });
            }

            return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                null));
        }


        getId() {
            return "DeviceSetupCategory";
        }

        getTitle() {
            return this.resourceStrings["BootstrapPageDeviceSetupCategoryTitle"];
        }

        getIconClass() {
            return "icon-devices";
        }

        getDisposition() {
            return (this.sessionUtilities.runningInOobe() ? this.sessionUtilities.CATEGORY_DISPOSITION_VISIBLE : this.sessionUtilities.CATEGORY_DISPOSITION_IGNORED);
        }

        runsInOobe() {
            return true;
        }

        getInitializationPromise() {
            return this.initializationPromise;
        }

        getSubcategories() {
            return [
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.SecurityPoliciesSubcategory",
                    this.resourceStrings["BootstrapPageSecurityPoliciesSubcategoryTitle"],
                    true,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        this.syncSyncSessionsShouldStart = true;

                        return this.waitForSyncSessionsInitiationPromise.then(() => {
                            return this.mdmBootstrapSessionUtilities.monitorPoliciesApplicationAsync(progressCallbackAsync);
                        }).then((actionResult) => {
                            this.securityPoliciesProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.CertificatesSubcategory",
                    this.resourceStrings["BootstrapPageCertificatesSubcategoryTitle"],
                    true,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        this.syncSyncSessionsShouldStart = true;

                        return this.waitForSyncSessionsInitiationPromise.then(() => {
                            return this.mdmBootstrapSessionUtilities.monitorCertsInstallationAsync(progressCallbackAsync);
                        }).then((actionResult) => {
                            this.certificatesProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.NetworkConnectionsSubcategory",
                    this.resourceStrings["BootstrapPageNetworkConnectionsSubcategoryTitle"],
                    true,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        this.syncSyncSessionsShouldStart = true;

                        return this.waitForSyncSessionsInitiationPromise.then(() => {
                            return this.mdmBootstrapSessionUtilities.monitorNetworkProfilesConfigAsync(progressCallbackAsync);
                        }).then((actionResult) => {
                            this.networkProfilesProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.AppsSubcategory",
                    this.resourceStrings["BootstrapPageAppsSubcategoryTitle"],
                    true,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        this.syncSyncSessionsShouldStart = true;

                        return this.waitForSyncSessionsInitiationPromise.then(() => {
                            return this.mdmBootstrapSessionUtilities.monitorAppsInstallAsync(progressCallbackAsync);
                        }).then((actionResult) => {
                            this.appsProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.RebootCoalescing",
                    "DeviceSetup.RebootCoalescing", // Title is mandatory, even for silent subcategories.
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        return this.coalesceRebootsAsync();
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.SendResultsToMdmServer",
                    "DeviceSetup.SendResultsToMdmServer", // Title is mandatory, even for silent subcategories.
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        return this.sendResultsToMdmServerAsync();
                    }
                ),

                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DeviceSetup.SaveWhiteGloveSuccessResult",
                    "DeviceSetup.SaveWhiteGloveSuccessResult", // Title is mandatory, even for silent subcategories.
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        return this.saveWhiteGloveSuccessResultAsync();
                    }
                )];
        }

        getClickHandler() {
            return (handlerParameters) => {
                switch (handlerParameters.clickedItemId) {
                    case this.sessionUtilities.CLICKABLE_ITEM_ID_CONTINUE_ANYWAY_BUTTON:
                        return new WinJS.Promise(
                            (completeDispatch, errorDispatch, progressDispatch) => {
                                if (!this.securityPoliciesProvisioningSucceeded ||
                                    !this.certificatesProvisioningSucceeded ||
                                    !this.networkProfilesProvisioningSucceeded ||
                                    !this.appsProvisioningSucceeded) {
                                    try {
                                        this.commercialDiagnosticsUtilities.logInfoEvent(
                                            "CommercialOOBE_ESPDeviceSetup_MDMPollingTasks_Started",
                                            "One of the provisioning subcategories failed, so kicking off MDM polling tasks.");
                                        this.sessionUtilities.enrollmentApis.startPollingTask();
                                    } catch (e) {
                                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                                            "CommercialOOBE_ESPDeviceSetup_MDMPollingTasks_Failed",
                                            "Error starting the MDM polling tasks.",
                                            e);
                                    }
                                }

                                completeDispatch(true);
                            },

                            () => {
                            });

                    case this.sessionUtilities.CLICKABLE_ITEM_ID_TRY_AGAIN_BUTTON:
                        return new WinJS.Promise(
                            (completeDispatch, errorDispatch, progressDispatch) => {
                                this.syncSyncSessionsShouldStart = false;
                                this.waitForSyncSessionsInitiationPromise = this.waitForSyncSessionsInitiationAsync();

                                completeDispatch(true);
                            },

                            () => {
                            });

                    default:
                       this.commercialDiagnosticsUtilities.logInfoEvent(
                           "CommercialOOBE_ESPDeviceSetup_ClickHandlerItem_Unhandled",
                           "Unhandled click handler item");
                }

                return WinJS.Promise.as(true);
            };
        }
    }

    return deviceSetupCategoryViewModel;
});
