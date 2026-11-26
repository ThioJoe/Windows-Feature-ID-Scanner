
"use strict";

define([
    'autopilot/bootstrapStatusSubcategoryViewModel',
    'autopilot/mdmBootstrapSessionUtilities',
    'autopilot/commercialDiagnosticsUtilities'], (
    bootstrapStatusSubcategoryViewModel,
    mdmBootstrapSessionUtilities,
    commercialDiagnosticsUtilities) => {

    class accountSetupCategoryViewModel {
        constructor(resourceStrings, sessionUtilities) {
            this.DEVICE_REGISTRATION_INTERVAL_WAIT_TIME_IN_MILLISECONDS = 240000;

            this.resourceStrings = resourceStrings;
            this.sessionUtilities = sessionUtilities;
            this.mdmBootstrapSessionUtilities = new mdmBootstrapSessionUtilities(
                resourceStrings,
                this.sessionUtilities.runningInOobe(),
                sessionUtilities);
            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities();
            this.aadRegistered = false;
            this.aadjEventName = "aadjcompleted";

            this.syncSyncSessionsShouldStart = false;
            this.waitForSyncSessionsInitiationPromise = this.waitForSyncSessionsInitiationAsync();
        }

        waitForSyncSessionsInitiationAsync() {
            if (this.syncSyncSessionsShouldStart) {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPAccountSetup_SyncSessionWaitLoop_StartingSyncSessions",
                    "BootstrapStatus: Start background sync sessions for Account Setup.");

                this.mdmBootstrapSessionUtilities.initiateSyncSessionsAsync(ModernDeployment.Autopilot.Core.SyncSessionExitCondition.accountSetupComplete);

                return WinJS.Promise.as(true);
            } else {
                return WinJS.Promise.timeout(this.defaultWaitToInitiateSyncSessionsInMilliseconds).then(() => {
                    return this.waitForSyncSessionsInitiationAsync();
                });
            }
        }

        async waitForAadRegistrationAsync() {
            const aadRegistrationWaitTimeInMilliseconds = await this.sessionUtilities.hybridUtilities.getMaxAadRegistrationWaitDurationAsync();

            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPAccountSetup_AadRegistration_Wait",
                `BootstrapStatus: AAD registration timeout set to ${aadRegistrationWaitTimeInMilliseconds}`);

            this.deviceRegistrationTaskScheduler = setInterval(
                () => {
                    this.sessionUtilities.enrollmentApis.forceRunDeviceRegistrationScheduledTaskAsync().then(
                        () => {
                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPAccountSetup_StartAadRegistration_Success",
                                "BootstrapStatus: Starting AAD device registration task succeeded");
                        },

                        (e) => {
                            this.commercialDiagnosticsUtilities.logExceptionEvent(
                                "CommercialOOBE_ESPAccountSetup_StartAadRegistration_Failed",
                                "BootstrapStatus: Starting AAD device registration task failed (non-fatal)",
                                e);
                        });
                },
                this.DEVICE_REGISTRATION_INTERVAL_WAIT_TIME_IN_MILLISECONDS);

            let aadRegistrationWaitPromise = new WinJS.Promise(
                (completeDispatch, errorDispatch, progressDispatch) => {
                    this.aadRegistrationListener = (hresult) => {
                        this.commercialDiagnosticsUtilities.logHresultEvent(
                            "CommercialOOBE_ESPAccountSetup_AadRegistrationTask_Complete",
                            `BootstrapStatus: AAD device registration task completed with hresult ${hresult.target}`,
                            hresult.target);

                        this.aadRegistered = (0 === hresult.target);
                        this.aadRegistrationHresult = hresult;
                        completeDispatch(true);
                    };

                    this.sessionUtilities.autopilotSubscriptionManager.addEventListener(this.aadjEventName, this.aadRegistrationListener.bind(this));
                },

                () => {
                });

            let aadRegistrationTimeoutPromise = WinJS.Promise.timeout(aadRegistrationWaitTimeInMilliseconds).then(() => {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPAccountSetup_AadRegistration_TimedOut",
                    "BootstrapStatus: AAD registration timed out");
            });

            let aadRegistrationPromises = [
                aadRegistrationTimeoutPromise,
                aadRegistrationWaitPromise
            ];

            return WinJS.Promise.any(aadRegistrationPromises).then(() => {
                if (this.aadRegistrationListener !== null) {
                    this.sessionUtilities.autopilotSubscriptionManager.removeEventListener(this.aadjEventName, this.aadRegistrationListener.bind(this));
                }

                aadRegistrationTimeoutPromise.cancel();
                aadRegistrationTimeoutPromise = null;

                clearInterval(this.deviceRegistrationTaskScheduler);
                this.deviceRegistrationTaskScheduler = null;

                if (!this.aadRegistered) {
                    if ((null === this.aadRegistrationHresult) || (undefined === this.aadRegistrationHresult)) {
                        this.aadRegistrationErrorString = this.commercialDiagnosticsUtilities.formatNumberAsHexString(this.sessionUtilities.HRESULT_TIMEOUT, 8);
                    } else {
                        this.aadRegistrationErrorString = this.commercialDiagnosticsUtilities.formatNumberAsHexString(this.aadRegistrationHresult.target, 8);
                    }
                }

                return;
            }).then(() => {
                return this.sessionUtilities.createActionResult(
                    this.aadRegistered ? this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED : this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                    this.aadRegistrationErrorString);
            });
        }

        sendResultsToMdmServerAsync() {
            try {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPAccountSetup_SendResultsToMdmServer_Started",
                    "BootstrapStatus: Account setup category sending success results to MDM server.");

                this.sessionUtilities.enrollmentApis.updateServerWithResult(true, this.sessionUtilities.runningInOobe());
            } catch (e) {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ESPAccountSetup_SendResultsToMdmServer_Failed",
                    "Failed to send results to MDM server, likely due to setting an already-failed provisioning status.",
                    e);
            }

            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPAccountSetup_SendResultsToMdmServer_Succeeded",
                "BootstrapStatus: Account setup category sent success results to MDM server.");

            return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                null));
        }

        prepareMultifactorAuthAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPAccountSetup_MultifactorAuth_Preparation",
                "BootstrapStatus: Requesting AAD user token");

            return CloudExperienceHostAPI.UtilStaticsCore.requestAADUserTokenAsync().then((result) => {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPAccountSetup_AadTokenRequest_Success",
                    "BootstrapStatus: AAD user token successfully requested");

                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                    null));
            },
            (e) => {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ESPAccountSetup_AadTokenRequest_Failed",
                    "BootstrapStatus: AAD user token request failed",
                    e);

                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                    null));
            });
        }


        getId() {
            return "AccountSetupCategory";
        }

        getTitle() {
            return this.resourceStrings["BootstrapPageAccountSetupCategoryTitle"];
        }

        getIconClass() {
            return "icon-users";
        }

        getDisposition() {
            return (!this.sessionUtilities.runningInOobe() ? this.sessionUtilities.CATEGORY_DISPOSITION_VISIBLE : this.sessionUtilities.CATEGORY_DISPOSITION_IGNORED);
        }

        runsInOobe() {
            return false;
        }

        getInitializationPromise() {
            return WinJS.Promise.as(true);
        }

        getSubcategories() {
            return [
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "AccountSetup.WaitingForAadRegistrationSubcategory",
                    this.resourceStrings["BootstrapPageAccountSetupWaitingForAadRegistrationSubcategoryTitle"],
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        return this.waitForAadRegistrationAsync();
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "AccountSetup.PrepareMultifactorAuth",
                    "AccountSetup.PrepareMultifactorAuth",
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        return this.prepareMultifactorAuthAsync();
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "AccountSetup.SecurityPoliciesSubcategory",
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
                            this.certificatesProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "AccountSetup.CertificatesSubcategory",
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
                    "AccountSetup.NetworkConnectionsSubcategory",
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
                            this.certificatesProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "AccountSetup.AppsSubcategory",
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
                            this.certificatesProvisioningSucceeded = this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState);

                            return actionResult;
                        });
                    }
                ),
                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "AccountSetup.SendResultsToMdmServer",
                    "AccountSetup.SendResultsToMdmServer", // Title is mandatory, even for silent subcategories.
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        return this.sendResultsToMdmServerAsync();
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
                                            "CommercialOOBE_ESPAccountSetup_MdmPolling_Started",
                                            "One of the provisioning subcategories failed, so kicking off MDM polling tasks.");
                                        this.sessionUtilities.enrollmentApis.startPollingTask();
                                    } catch (e) {
                                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                                            "CommercialOOBE_ESPAccountSetup_MdmPolling_Failed",
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
                            "CommercialOOBE_ESPAccountSetup_ClickHandlerItem_Unhandled",
                            "Unhandled click handler item");
                }

                return WinJS.Promise.as(true);
            };
        }
    }

    return accountSetupCategoryViewModel;
});
