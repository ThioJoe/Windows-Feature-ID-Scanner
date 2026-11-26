
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
    class devicePreparationCategoryViewModel {
        constructor(resourceStrings, sessionUtilities) {
            this.MAX_TPM_ATTESTATION_WAIT_TIME_IN_MILLISECONDS = 420000; // 7 minutes
            this.MIN_PPKG_PROCESSING_TIME_IN_MILLISECONDS = 5000;   // 5 seconds
            this.POLLING_INTERVAL_IN_MILLISECONDS = 500; // .5 seconds

            this.PROVISIONING_STATUS_RUNNING = 0;
            this.PROVISIONING_STATUS_SUCCEEDED = 1;
            this.PROVISIONING_STATUS_FAILED = 2;

            this.ESP_POLICY_PROVIDER_INSTALL_RESULT_SUCCESS = 1;
            this.ESP_POLICY_PROVIDER_INSTALL_RESULT_TIMEOUT = 2;
            this.ESP_POLICY_PROVIDER_INSTALL_RESULT_FAILURE = 3;

            this.resourceStrings = resourceStrings;
            this.tpmIsAttested = false;
            this.whiteGloveMode = 0; // Initialize to unknown mode
            this.isUsingDeviceTicket = false;
            this.tpmAttestationEventName = "tpmevent";
            this.timeoutErrorCode = 0x800705B4;

            this.sessionUtilities = sessionUtilities;
            this.mdmBootstrapSessionUtilities = new mdmBootstrapSessionUtilities(
                resourceStrings,
                this.sessionUtilities.runningInOobe(),
                sessionUtilities);
            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities();

            this.initializationPromise = this.sessionUtilities.autopilotApis.getDeviceAutopilotModeAsync().then((mode) => {
                this.whiteGloveMode = mode;
            }).then(() => {
                return this.sessionUtilities.autopilotApis.getOobeSettingsOverrideAsync(EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotOobeSetting.aadAuthUsingDeviceTicket);
            }).then((isUsingDeviceTicket) => {
                this.isUsingDeviceTicket = isUsingDeviceTicket;
                return bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", "AutopilotWhiteGloveStartTime");
            }).then((startTime) => {
                this.whiteGloveStartTime = startTime;
            });
        }

        runTpmAttestationAsync() {
            return new WinJS.Promise(
                (completeDispatch, errorDispatch, progressDispatch) => {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_TPMAttestation_Started",
                        "Beginning TPM identity attestation for device token Azure AD Join.");        
                    let tpmAttestationWaitPromise = new WinJS.Promise(
                        (completeDispatch, errorDispatch, progressDispatch) => {
                            this.tpmAttestationListener = (hresult) => {
                                if (0 === hresult.target) {
                                    this.commercialDiagnosticsUtilities.logInfoEvent(
                                        "CommercialOOBE_ESPDevicePreparation_TPMAttestation_Succeeded",
                                        "BootstrapStatus: TPM identity attestation succeeded.");
                                    this.tpmIsAttested = true;
                                } else {
                                    this.tpmAttestationErrorHresultString = this.commercialDiagnosticsUtilities.formatNumberAsHexString(hresult.target, 8);
                                    this.commercialDiagnosticsUtilities.logHresultEvent(
                                        "CommercialOOBE_ESPDevicePreparation_TPMAttestation_Failed",
                                        `BootstrapStatus: TPM identity attestation failed. Error: ${this.tpmAttestationErrorHresultString}`,
                                        hresult.target);

                                    let errorMessage = this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.BootstrapPageDevicePreparationTpmError, this.tpmAttestationErrorHresultString);
                                    this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, errorMessage);
                                }

                                completeDispatch(true);
                            };

                            try {
                                this.sessionUtilities.tpmNotificationManager.addEventListener(this.tpmAttestationEventName, this.tpmAttestationListener.bind(this));
                            } catch (e) {
                                this.commercialDiagnosticsUtilities.logExceptionEvent(
                                    "CommercialOOBE_ESPDevicePreparation_TPMEventListenerRegistration_Failed",
                                    `BootstrapStatus: Registering TPM event listener failed.`,
                                    e);
                            }
                        },

                        () => {
                        });

                    let tpmAttestationTimeoutPromise = WinJS.Promise.timeout(this.MAX_TPM_ATTESTATION_WAIT_TIME_IN_MILLISECONDS).then(() => {
                        this.commercialDiagnosticsUtilities.logHresultEvent(
                            "CommercialOOBE_ESPDevicePreparation_TPMAttestation_TimedOut",
                            `BootstrapStatus: TPM attestation timed out.`,
                            this.timeoutErrorCode);
                    });

                    let tpmAttestationPromises = [
                        tpmAttestationTimeoutPromise,
                        tpmAttestationWaitPromise
                    ];

                    return WinJS.Promise.any(tpmAttestationPromises).then(() => {
                        if (this.tpmAttestationListener !== null) {
                            try {
                                this.sessionUtilities.tpmNotificationManager.removeEventListener(this.tpmAttestationEventName, this.tpmAttestationListener.bind(this));
                            } catch (e) {
                                this.commercialDiagnosticsUtilities.logExceptionEvent(
                                    "CommercialOOBE_ESPDevicePreparation_TPMEventListenerDeregistration_Failed",
                                    "BootstrapStatus: Deregistering TPM event listener failed.",
                                    e);
                            }
                        }

                        tpmAttestationTimeoutPromise.cancel();
                        tpmAttestationTimeoutPromise = null;

                        if (!this.tpmIsAttested && (undefined === this.tpmAttestationErrorHresultString)) {
                            this.tpmAttestationErrorHresultString = this.commercialDiagnosticsUtilities.formatNumberAsHexString(this.sessionUtilities.HRESULT_TIMEOUT, 8);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.resourceStrings.WhiteGloveTpmTimeoutError);
                        }

                        completeDispatch(this.sessionUtilities.createActionResult(
                            this.tpmIsAttested ? this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED : this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                            this.tpmAttestationErrorHresultString));
                    });
                },

                () => {
                });
        }

        startWaitForTpmAttestationAsync() {
            if (!this.isUsingDeviceTicket) {
                return bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", "AutopilotWhiteGloveStartTime").then(
                    (result) => {
                        if (undefined === result) {
                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPDevicePreparation_WhiteGlove_StartTimeMissing",
                                "BootstrapStatus: Unable to find AutopilotWhiteGloveStartTime value.");

                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPDevicePreparation_TPMAttestation_NotRequiredForScenario",
                                "Skipping TPM Attestation."
                            );

                            return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                                this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                                null));
                        }

                        this.commercialDiagnosticsUtilities.logInfoEvent(
                            "CommercialOOBE_ESPDevicePreparation_WhiteGlove_Started",
                            "OOBEProvisioningProgress AutopilotWhiteGloveFlow");
                        return this.runTpmAttestationAsync();
                    },

                    (e) => {
                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                            "CommercialOOBE_ESPDevicePreparation_StartWaitForTPMAttestation_Error",
                            "BootstrapStatus: TPM attestation failed.",
                            e);

                        return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                            this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                            null));
                    });
            }

            return this.runTpmAttestationAsync();
        }

         pollForPpkgProcessingResultsAsync() {
            return new WinJS.Promise(
                (completeDispatch, errorDispatch, progressDispatch) => {
                    return this.sessionUtilities.provisioningPluginManager.getProvisioningSucceededAsync().then((processingResult) => {
                        if (this.sessionUtilities.provisioningPluginManager.isRebootRequired()) {
                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPDevicePreparation_AADJProvisioningReboot_Started",
                                "PPKG package provisioning processing requires a reboot.");
                            try {
                                bridge.fireEvent(constants.Events.done, constants.AppResult.action1);
                            } catch (e) {
                                this.commercialDiagnosticsUtilities.logExceptionEvent(
                                    "CommercialOOBE_ESPDevicePreparation_AADJProvisioningReboot_Failed",
                                    "BootstrapStatus: Attempted reboot following provisioning failed.",
                                    e);
                            }

                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPDevicePreparation_AADJProvisioningReboot_Succeeded",
                                "Reboot following provisioning succeeded."
                            );

                            completeDispatch(this.sessionUtilities.createActionResult(
                                this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                                null));

                        } else if (this.PROVISIONING_STATUS_SUCCEEDED === processingResult) {
                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPDevicePreparation_AADJProvisioning_Succeeded",
                                "BootstrapStatus: PPKG package provisioning succeeded."
                            );

                            completeDispatch(this.sessionUtilities.createActionResult(
                                this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                                null));

                        } else if (this.PROVISIONING_STATUS_FAILED === processingResult) {
                            this.commercialDiagnosticsUtilities.logInfoEvent(
                                "CommercialOOBE_ESPDevicePreparation_AADJProvisioning_Failed",
                                "BootstrapStatus: PPKG package provisioning failed."
                            );

                            completeDispatch(this.sessionUtilities.createActionResult(
                                this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                                this.resourceStrings["BootstrapPageDevicePreparationReapplyingPpkgsErrorMessage"]));
                        }


                    }).then(() => {
                        return WinJS.Promise.timeout(this.POLLING_INTERVAL_IN_MILLISECONDS);

                    }).then(() => {
                        return pollForPpkgProcessingResultsAsync();
                    });

                }, () => {
                });
        }

        startPpkgProcessingAsync() {
            return this.sessionUtilities.getSettingAsync(this.sessionUtilities.STATE_NAME_GLOBAL_RESTORE_MDM_TASKS).then((restoreMdmTasks) => {
                if (restoreMdmTasks === "false") {
                    return WinJS.Promise.as();
                }

                try {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_AADJSyncWithServer_Started",
                        "Rebuilding schedules and syncing with server.");
                    return this.sessionUtilities.enrollmentApis.rebuildSchedulesAndSyncWithServerAsync();
                } catch (e) {
                    this.commercialDiagnosticsUtilities.logExceptionEvent(
                        "CommercialOOBE_ESPDevicePreparation_AADJSyncWithServer_Failed",
                        `BootstrapStatus: rebuildSchedulesAndSyncWithServerAsync failed. Error: ${this.commercialDiagnosticsUtilities.formatNumberAsHexString(e, 8)}.`,
                        e);
                }

            }).then(() => {
                return this.sessionUtilities.getSettingAsync(this.sessionUtilities.STATE_NAME_GLOBAL_RUN_PROVISIONING);

            }).then((runProvisioning) => {
                if (runProvisioning === "false") {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_AADJProvisioning_NotRequiredForScenario",
                        "AADJ Provisioning skipped.");

                    return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                        this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                        null));
                }

                let provisioningPromises = [
                    this.sessionUtilities.provisioningPluginManager.applyAfterConnectivityPackagesAsync(),
                    WinJS.Promise.timeout(this.MIN_PPKG_PROCESSING_TIME_IN_MILLISECONDS)
                ];

                return WinJS.Promise.join(provisioningPromises)
                    .then(() => {
                        return this.pollForPpkgProcessingResultsAsync();
                    });

            });
        }

        startDeviceAadjAndEnrollmentHelperAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_Started",
                "BootstrapStatus: Starting Autopilot device enrollment.");

            return this.sessionUtilities.autopilotApis.performDeviceEnrollmentAsync().then((result) => {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_Complete",
                    "BootstrapStatus: Device enrollment call completed. Processing results...");
                let enrollmentState = result.enrollmentDisposition;

                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_ResultExtracted",
                    "BootstrapStatus: Result data extracted.");

                this.sessionUtilities.storeSettingAsync(
                    this.sessionUtilities.STATE_NAME_GLOBAL_MDM_ENROLLMENT_STATUS,
                    this.sessionUtilities.MDM_ENROLLMENT_DISPOSITION[enrollmentState]);

                if (enrollmentState === EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.completed) {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_DispositionMarkedAsComplete",
                        "BootstrapStatus: Enrollment disposition marked as completed.");

                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_Complete",
                        `BootstrapStatus: Device enrollment results: ${enrollmentState}, ${this.commercialDiagnosticsUtilities.formatNumberAsHexString(result.dispositionResult, 8)}`);

                    return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                        this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                        null));

                } else {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_DispositionMarkedAsIncomplete",
                        "BootstrapStatus: Enrollment disposition marked as not completed.");

                    let errorCode = this.commercialDiagnosticsUtilities.formatNumberAsHexString(result.dispositionResult, 8);
                    let resultMessage = this.commercialDiagnosticsUtilities.formatMessage(`${enrollmentState}, ${errorCode}`);

                    switch (enrollmentState) {
                        case EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.aadConfigure:
                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGloveAadConfigureError",
                                `BootstrapStatus: Device enrollment results: ${resultMessage}`,
                                result.dispositionResult);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveAadConfigureError, errorCode));
                            break;

                        case EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.aadJoin:
                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGloveAadJoinError",
                                `BootstrapStatus: Device enrollment results: ${resultMessage}`,
                                result.dispositionResult);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveAadJoinError, errorCode));
                            break;

                        case EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.aadDeviceDiscovery:
                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGloveAadDeviceDiscoveryError",
                                `BootstrapStatus: Device enrollment results: ${resultMessage}`,
                                result.dispositionResult);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveAadDeviceDiscoveryError, errorCode));
                            break;

                        case EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.aadTicket:
                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGloveAadTicketError",
                                `BootstrapStatus: Device enrollment results: ${resultMessage}`,
                                result.dispositionResult);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveAadTicketError, errorCode));
                            break;

                        case EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentDisposition.mdmEnrolling:
                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGloveMdmEnrollmentError",
                                `BootstrapStatus: Device enrollment results: ${resultMessage}`,
                                result.dispositionResult);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveMdmEnrollmentError, errorCode));
                            break;

                        default:
                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGloveGenericEnrollmentError",
                                `BootstrapStatus: Device enrollment results: ${resultMessage}`,
                                result.dispositionResult);
                            this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveGenericEnrollmentError, errorCode));
                    }

                    return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                        this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                        resultMessage));
                }
            },
            (e) => {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_Failed",
                    "BootstrapStatus: performDeviceEnrollmentAsync failed.",
                    e);

                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                    null));
            });
        }

        startDeviceAadjAndEnrollmentAsync() {
            if ((!this.isUsingDeviceTicket || (this.whiteGloveMode === EnterpriseDeviceManagement.Service.AutoPilot.AutopilotMode.whiteGloveDJPP))
                && (this.whiteGloveMode !== EnterpriseDeviceManagement.Service.AutoPilot.AutopilotMode.whiteGloveCanonical)) {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDevicePreparation_MDMEnrollment_NotRequiredForScenario",
                    "Skipping MDM enrollment."
                );

                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                    null));
            } 

            if (undefined !== this.whiteGloveStartTime) {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGlove_Started",
                    "BootstrapStatus: White glove device enrollment.");

                return this.sessionUtilities.autopilotApis.setDeviceAutopilotModeAsync(EnterpriseDeviceManagement.Service.AutoPilot.AutopilotMode.whiteGloveCanonical).then(() => {
                    return this.startDeviceAadjAndEnrollmentHelperAsync();
                },
                (e) => {
                    this.commercialDiagnosticsUtilities.logExceptionEvent(
                        "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_WhiteGlove_Failed",
                        "BootstrapStatus: White glove device enrollment error.",
                        e);
                });
            }

            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPDevicePreparation_DeviceEnrollment_NonWhiteGlove_Started",
                "BootstrapStatus: Normal (i.e., non-white-glove) device enrollment.");
            return this.startDeviceAadjAndEnrollmentHelperAsync();
        }

        waitForEspPolicyProviders() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPDevicePreparation_PolicyProvidersInstallation_Started",
                "BootstrapStatus: Starting the wait for policy providers installation.");

            return this.sessionUtilities.espTrackingUtility.waitForPolicyProviderInstallationToCompleteAsync().then((result) => {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ESPDevicePreparation_PolicyProvidersInstallation_Complete",
                    "BootstrapStatus: waitForPolicyProviderInstallationToComplete returned, processing results...");

                if (result.installationResult === this.ESP_POLICY_PROVIDER_INSTALL_RESULT_SUCCESS) {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "CommercialOOBE_ESPDevicePreparation_PolicyProvidersInstallation_Succeeded",
                        "BootstrapStatus: All policy providers have successfully installed a list of policies.");

                    return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                        this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                        null));
                }

                let errorCode = 0;

                switch (result.installationResult) {
                    case this.ESP_POLICY_PROVIDER_INSTALL_RESULT_TIMEOUT:
                        errorCode = result.errorCode;
                        this.commercialDiagnosticsUtilities.logHresultEvent(
                            "CommercialOOBE_ESPDevicePreparation_PolicyProvidersInstallation_TimedOut",
                            "BootstrapStatus: Timed out waiting for all policy providers to provide a list of policies.",
                            errorCode);
                        break;

                    case this.ESP_POLICY_PROVIDER_INSTALL_RESULT_FAILURE:
                        errorCode = result.errorCode;
                        this.commercialDiagnosticsUtilities.logHresultEvent(
                            "CommercialOOBE_ESPDevicePreparation_PolicyProvidersInstallation_Failed",
                            `BootstrapStatus: Policy provider(s) installation failed. Error: ${this.commercialDiagnosticsUtilities.formatNumberAsHexString(errorCode, 8)}.`,
                            errorCode);
                        break;

                    default:
                        errorCode = this.commercialDiagnosticsUtilities.unexpectedErrorCode;
                        this.commercialDiagnosticsUtilities.logHresultEvent(
                            "CommercialOOBE_ESPDevicePreparation_PolicyProvidersInstallation_Failed",
                            `BootstrapStatus: Policy provider failure: unexpected installationResult encountered (${result.installationResult}). Error: ${this.commercialDiagnosticsUtilities.formatNumberAsHexString(errorCode, 8)}.`,
                            errorCode);                
                    }

                this.sessionUtilities.storeTransientState(this.sessionUtilities.WHITE_GLOVE_ERROR_USER_MESSAGE, this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings.WhiteGloveEspProviderError, this.commercialDiagnosticsUtilities.formatNumberAsHexString(errorCode, 8)));

                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_FAILED,
                    this.commercialDiagnosticsUtilities.formatNumberAsHexString(errorCode, 8)));
            },
            (e) => {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ESPDevicePreparation_WaitForPolicyProvidersInstallation_Failed",
                    "BootstrapStatus: waitForPolicyProviderInstallationToComplete Failed",
                    e);
            });
        }

        setContinueAnywayButtonVisibility() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_ESPDevicePreparation_SetContinueAnywayButtonVisibility_Triggered",
                "BootstrapStatus: setContinueAnywayButtonVisibility triggered.");

            return this.sessionUtilities.storeSettingAsync(this.sessionUtilities.STATE_NAME_GLOBAL_SHOW_CONTINUE_ANYWAY_BUTTON, "true").then(() => {
                return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                    this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                    null));
            });
        }


        getId() {
            return "DevicePreparationCategory";
        }

        getTitle() {
            return this.resourceStrings["BootstrapPageDevicePreparationCategoryTitle"];
        }

        getIconClass() {
            return "icon-gears";
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
                    "DevicePreparation.TpmAttestationSubcategory",
                    this.resourceStrings["BootstrapPageDevicePreparationTpmAttestationSubcategoryTitle"],
                    false,
                    () => {
                        if ((this.sessionUtilities.provisioningPluginManager != undefined)
                            && (this.sessionUtilities.provisioningPluginManager != null)) {
                            if (this.sessionUtilities.provisioningPluginManager.isPostPowerwash()) {
                                this.commercialDiagnosticsUtilities.logInfoEvent(
                                    "CommercialOOBE_ESPDevicePreparation_TPMAttestation_SkippedDueToAutopilotReset",
                                    "BootstrapStatus: Skipping TPM attestation because this device is running a post-reset flow.");
                                return this.sessionUtilities.SUBCATEGORY_DISPOSITION_IGNORED;
                            }
                        }

                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        return this.startWaitForTpmAttestationAsync();
                    }),

                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DevicePreparation.AadjSubcategory",
                    this.resourceStrings["BootstrapPageDevicePreparationAadjSubcategoryTitle"],
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        return this.startPpkgProcessingAsync();
                    }),

                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DevicePreparation.MdmEnrollmentSubcategory",
                    this.resourceStrings["BootstrapPageDevicePreparationMdmEnrollmentSubcategoryTitle"],
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        return this.startDeviceAadjAndEnrollmentAsync();
                    }),

                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DevicePreparation.EspProviderInstallationSubcategory",
                    this.resourceStrings["BootstrapPageDevicePreparationEspProviderInstallationSubcategoryTitle"],
                    true,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE;
                    },
                    (progressCallbackAsync) => {
                        return this.waitForEspPolicyProviders();
                    }),

                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DevicePreparation.InitiateSyncSessions",
                    "DevicePreparation.InitiateSyncSessions",
                    true,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        this.mdmBootstrapSessionUtilities.initiateSyncSessionsAsync(ModernDeployment.Autopilot.Core.SyncSessionExitCondition.policyProvidersComplete);

                        return WinJS.Promise.as(this.sessionUtilities.createActionResult(
                            this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED,
                            null));
                    }),

                new bootstrapStatusSubcategoryViewModel(
                    this.resourceStrings,
                    this.sessionUtilities,
                    "DevicePreparation.SetContinueAnywayButtonVisibility",
                    "DevicePreparation.SetContinueAnywayButtonVisibility",
                    false,
                    () => {
                        return this.sessionUtilities.SUBCATEGORY_DISPOSITION_SILENT;
                    },
                    (progressCallbackAsync) => {
                        return this.setContinueAnywayButtonVisibility();
                    })
            ];
        }

        getClickHandler() {
            return (handlerParameters) => {
                return WinJS.Promise.as(true);
            };
        }

    }

    return devicePreparationCategoryViewModel;
});
