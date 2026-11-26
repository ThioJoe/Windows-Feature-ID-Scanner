
"use strict";

define([
    'lib/knockout',
    'legacy/bridge',
    'legacy/events',
    'legacy/appObjectFactory', // necessary for OOBE framework, even though not directly used here
    'autopilot/bootstrapSessionGeneralUtilities',
    'autopilot/commercialDiagnosticsUtilities'], (
        ko,
        bridge,
        constants,
        appObjectFactory, // necessary for OOBE framework, even though not directly used here
        bootstrapSessionGeneralUtilities,
        commercialDiagnosticsUtilities) => {
    class DeviceLinkViewModel {
        constructor(resourceStrings, rootElement) {


            this.VIRTUAL_PAGE_ID_UNKNOWN = "Unknown";
            this.VIRTUAL_PAGE_ID_DEVICE_LINK_OPTIONS = "DeviceLinkOptionsVirtualPage";
            this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS = "DeviceLinkProgressVirtualPage";
            this.VIRTUAL_PAGE_ID_DEVICE_LINK_SUCCESS_RESULT = "DeviceLinkSuccessResultVirtualPage";
            this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT = "DeviceLinkErrorResultVirtualPage";
            this.VIRTUAL_PAGE_ID_DEVICE_LINK_NOT_SUPPORTED_RESULT = "DeviceLinkNotSupportedResultVirtualPage";

            this.BUTTON_ID_UNKNOWN = "Unknown";
            this.BUTTON_ID_CANCEL = "idCancelButton";
            this.BUTTON_ID_NEXT_ENABLED = "idNextEnabledButton";
            this.BUTTON_ID_NEXT_DISABLED = "idNextDisabledButton";
            this.BUTTON_ID_START_OVER = "idStartOverButton";
            this.BUTTON_ID_EXIT = "idExitButton";
            this.BUTTON_ID_TRY_AGAIN = "idTryAgainButton";

            this.PAGE_EXIT_STATUS_UNKNOWN = 0;
            this.PAGE_EXIT_STATUS_SUCCESS = 1;
            this.PAGE_EXIT_STATUS_SUCCESS_BACK_TO_OOBE_START = 2;
            this.PAGE_EXIT_STATUS_ERROR = 3;
            this.PAGE_EXIT_STATUS_CANCELED = 4;
            this.PAGE_EXIT_STATUS_CANCELED_BACK_TO_OOBE_START = 5;
            this.PAGE_EXIT_STATUS_UNSUPPORTED_BACK_TO_OOBE_START = 6;

            this.TSM_PROCESS_NAME = "DeviceLinkPage";
            this.TSM_STATE_CONFIGURE_DEVICE_LINK = "ConfigureDeviceLink";
            this.TSM_STATE_CONFIGURE_DEVICE_LINK_APPLY_DEVICE_LINK = "ApplyDeviceLink";
            this.TSM_STATE_CONFIGURE_DEVICE_LINK_MAA_ATTEST = "MaaAttestation";
            this.TSM_STATE_CONFIGURE_DEVICE_LINK_RETRIEVE_DEVICE_LINK = "RetrieveDeviceLink";
            this.TSM_STATE_CONFIGURE_DEVICE_LINK_TPM_ATTEST = "TpmAttestation";
            this.TSM_STATE_EXPORT_DEVICE_LINK_INFO = "ExportDeviceLinkInfo";
            this.TSM_STATE_GENERATE_QR = "GenerateQrCode";
            this.TSM_STATE_LINK_DEVICE = "LinkDevice";
            this.TSM_STATE_LINK_DEVICE_OPTIONS = "LinkDeviceOptions";
            this.TSM_STATE_PAGE = "Page";
            this.TSM_STATE_PAGE_INITIALIZATION = "PageInitialization";
            this.TSM_STATE_REQUEST_DISCOVERY_URL = "RequestDiscoverUrl";
            this.TSM_STATE_REQUEST_ENROLLMENT_DISCOVERY = "RequestEnrollmentDiscovery";
            
            this.DAP_COMMANDS_PHASE_ID_ON_SUCCESSFUL_DAP_PAGE_EXIT = "onSuccessfulDapPageExit";
            this.DAP_COMMANDS_PHASE_ID_ON_SUCCESSFUL_DAP_PAGE_EXIT_TO_OOBE_START = "onSuccessfulDapPageExitToOobeStart";
            this.DAP_COMMANDS_PHASE_ID_ON_ERROR_DAP_PAGE_EXIT = "onErrorDapPageExit";
            this.DAP_COMMANDS_PHASE_ID_ON_CANCELED_DAP_PAGE_EXIT = "onCanceledDapPageExit";
            this.DAP_COMMANDS_PHASE_ID_ON_CANCELED_DAP_PAGE_EXIT_TO_OOBE_START = "onCanceledDapPageExitToOobeStart";
            this.DAP_COMMANDS_PHASE_ID_ON_UNSUPPORTED_DEVICE_DAP_EXIT_TO_OOBE_START = "onUnsupportedDeviceDapExitToOobeStart";

            this.LOTTIE_FILE_SUCCESS = "autopilotLottie.json";
            this.LOTTIE_FILE_ERROR = "errorLottie.json";

            this.AUTOPILOT_DEVICE_TAGGING_ENABLED = CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotDeviceTagging");

            this.DEVICE_LINK_FORMAT_FLAGS = ModernDeployment.Autopilot.Core.DeviceLinkFormatFlags.json | ModernDeployment.Autopilot.Core.DeviceLinkFormatFlags.base64;

            this.E_AUTOPILOT_DEVICE_LINK_NO_TPM = -2130460668; // 0x8103c004
            this.E_AUTOPILOT_DEVICE_LINK_NO_COMPATIBLE_TPM = -2130460667 // 0x8103c005

            this.deviceLinkInfo = null;
            this.initializationSucceeded = false;

            this.resourceStrings = resourceStrings;
            
            this.deviceLinkExportSuccessMessage = this.resourceStrings["DeviceLinkExportSuccessText"];
            this.deviceLinkExportErrorMessage = this.resourceStrings["DeviceLinkExportErrorText"];
            this.deviceLinkExportTimeoutMessage = this.resourceStrings["DeviceLinkExportTimeoutText"];

            this.sessionUtilities = new bootstrapSessionGeneralUtilities(true);
            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities(this.sessionUtilities);
            this.deviceLinkManager = new ModernDeployment.Autopilot.Core.DeviceLinkManager();

            this.cancelButtonProperties = {
                automationId: this.BUTTON_ID_CANCEL,
                buttonText: this.resourceStrings["DeviceLinkCancelButton"],
                buttonType: "button",
                isPrimaryButton: false,
                autoFocus: false,
                isVisible: true,
                disableControl: false,
                buttonClickHandler: () => {
                    this.onCancelButtonClickAsync();
                }
            };

            this.nextEnabledButtonProperties = {
                automationId: this.BUTTON_ID_NEXT_ENABLED,
                buttonText: this.resourceStrings["DeviceLinkNextButton"],
                buttonType: "button",
                isPrimaryButton: false,
                autoFocus: false,
                isVisible: true,
                disableControl: false,
                buttonClickHandler: () => {
                    this.onNextButtonClickAsync();
                }
            };

            this.nextDisabledButtonProperties = {
                automationId: this.BUTTON_ID_NEXT_DISABLED,
                buttonText: this.resourceStrings["DeviceLinkNextButton"],
                buttonType: "button",
                isPrimaryButton: false,
                autoFocus: false,
                isVisible: true,
                disableControl: true,
                buttonClickHandler: () => { }
            };

            this.startOverMenuButtonProperties = {
                automationId: this.BUTTON_ID_START_OVER,
                buttonText: this.resourceStrings["DeviceLinkStartOverButton"],
                buttonType: "button",
                isPrimaryButton: false,
                autoFocus: false,
                isVisible: true,
                disableControl: false,
                buttonClickHandler: () => {
                    this.onStartOverButtonClickAsync();
                }
            };

            this.exitButtonProperties = {
                automationId: this.BUTTON_ID_EXIT,
                buttonText: this.resourceStrings["DeviceLinkExitButton"],
                buttonType: "button",
                isPrimaryButton: false,
                autoFocus: false,
                isVisible: true,
                disableControl: false,
                buttonClickHandler: () => {
                    this.onExitButtonClickAsync();
                }
            };

            this.tryAgainButtonProperties = {
                automationId: this.BUTTON_ID_TRY_AGAIN,
                buttonText: this.resourceStrings["DeviceLinkTryAgainButton"],
                buttonType: "button",
                isPrimaryButton: false,
                autoFocus: false,
                isVisible: true,
                disableControl: false,
                buttonClickHandler: () => {
                    this.onTryAgainButtonClickAsync();
                }
            };

            this.showDeviceLinkOptionsVirtualPage = ko.observable(true);
            this.showDeviceLinkProgressVirtualPage = ko.observable(false);
            this.showDeviceLinkSuccessResultVirtualPage = ko.observable(false);
            this.showDeviceLinkErrorResultVirtualPage = ko.observable(false);
            this.showDeviceLinkNotSupportedResultVirtualPage = ko.observable(false);

            this.allVirtualPages = [];

            this.allVirtualPages[this.VIRTUAL_PAGE_ID_DEVICE_LINK_OPTIONS] = {
                pageTitle: this.resourceStrings["DeviceLinkPageTitleOptions"],
                isVisible: this.showDeviceLinkOptionsVirtualPage,
                lottieAnimation: this.LOTTIE_FILE_SUCCESS,
                buttonSet: [this.cancelButtonProperties, this.nextEnabledButtonProperties],
                onVisibleHandler: this.onOptionsVirtualPageVisible.bind(this)
            };

            this.allVirtualPages[this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS] = {
                pageTitle: this.resourceStrings["DeviceLinkPageTitleProgress"],
                isVisible: this.showDeviceLinkProgressVirtualPage,
                lottieAnimation: this.LOTTIE_FILE_SUCCESS,
                buttonSet: [this.cancelButtonProperties, this.nextDisabledButtonProperties],
                onVisibleHandler: this.onProgressVirtualPageVisible.bind(this)
            };

            this.allVirtualPages[this.VIRTUAL_PAGE_ID_DEVICE_LINK_SUCCESS_RESULT] = {
                pageTitle: this.resourceStrings["DeviceLinkPageTitleSuccessResult"],
                isVisible: this.showDeviceLinkSuccessResultVirtualPage,
                lottieAnimation: this.LOTTIE_FILE_SUCCESS,
                buttonSet: [this.exitButtonProperties],
                onVisibleHandler: this.onSuccessVirtualPageVisible.bind(this),
                exitPageStatus: this.PAGE_EXIT_STATUS_SUCCESS_BACK_TO_OOBE_START
            };
            
            this.allVirtualPages[this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT] = {
                pageTitle: this.resourceStrings["DeviceLinkPageTitleErrorResult"],
                isVisible: this.showDeviceLinkErrorResultVirtualPage,
                lottieAnimation: this.LOTTIE_FILE_ERROR,
                buttonSet: [this.startOverMenuButtonProperties, this.tryAgainButtonProperties],
                onVisibleHandler: this.onFailureVirtualPageVisible.bind(this)
            };

            this.allVirtualPages[this.VIRTUAL_PAGE_ID_DEVICE_LINK_NOT_SUPPORTED_RESULT] = {
                pageTitle: this.resourceStrings["DeviceLinkPageTitleNotSupportedResult"],
                isVisible: this.showDeviceLinkNotSupportedResultVirtualPage,
                lottieAnimation: this.LOTTIE_FILE_ERROR,
                buttonSet: [this.exitButtonProperties],
                onVisibleHandler: this.onNotSupportedVirtualPageVisible.bind(this),
                exitPageStatus: this.PAGE_EXIT_STATUS_UNSUPPORTED_BACK_TO_OOBE_START
            };

            this.pageTitle = ko.observable(this.resourceStrings["DeviceLinkPageTitleOptions"]);

            this.option1Title = ko.observable(this.resourceStrings["DeviceLinkOption1Title"]);
            this.option1Body = ko.observable(this.resourceStrings["DeviceLinkOption1Body"]);

            this.option2Title = ko.observable(this.resourceStrings["DeviceLinkOption2Title"]);
            this.option2Body1 = ko.observable(this.resourceStrings["DeviceLinkOption2Body1"]);
            this.option2Body2 = ko.observable(this.resourceStrings["DeviceLinkOption2Body2"]);

            this.exportDeviceLinkInfoEnabled = ko.observable(true);
            this.exportDeviceLinkInfoText = ko.observable(this.resourceStrings["DeviceLinkExportLinkText"]);

            this.showExportLinkSuccess = ko.observable(false);
            this.exportLinkSuccessResult = ko.observable(this.deviceLinkExportSuccessMessage);
            
            this.showExportLinkError = ko.observable(false);
            this.exportLinkErrorResult = ko.observable(this.deviceLinkExportErrorMessage);

            this.progressStatusText = ko.observable(this.resourceStrings["DeviceLinkProgressStatusText"]);
            this.successResultBody = ko.observable(this.resourceStrings["DeviceLinkSuccessResultBody"]);
            this.errorResultBody = ko.observable(this.resourceStrings["DeviceLinkErrorResultBody"]);
            this.notSupportedResultBody = ko.observable(this.resourceStrings["DeviceLinkPageTitleNotSupportedResultBody"]);

            this.currentVirtualPageId = ko.observable(this.VIRTUAL_PAGE_ID_DEVICE_LINK_OPTIONS);

            if (!this.AUTOPILOT_DEVICE_TAGGING_ENABLED) {
                return WinJS.Promise.as(CloudExperienceHost.AppResult.abort);
            }

            this.flexEndButtons = ko.pureComputed(() => {
                return this.allVirtualPages[this.currentVirtualPageId()].buttonSet;
            });

            return this.waitForDebuggerAttachmentAsync().then(async () => {
                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_PAGE)
                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_PAGE_INITIALIZATION);
            }).then(async () => {
                try {
                    this.deviceLinkUtilities = new ModernDeployment.Autopilot.Core.DeviceLinkUtilities();
                    this.deviceLinkInfo = await this.deviceLinkUtilities.getDeviceLinkInfoAsync(this.DEVICE_LINK_FORMAT_FLAGS);
                    this.initializationSucceeded = true;
                } catch (e) {
                    if ((e.number == this.E_AUTOPILOT_DEVICE_LINK_NO_TPM) ||
                        (e.number == this.E_AUTOPILOT_DEVICE_LINK_NO_COMPATIBLE_TPM)) {
                        this.currentVirtualPageId(this.VIRTUAL_PAGE_ID_DEVICE_LINK_NOT_SUPPORTED_RESULT);
                    } else {
                        this.currentVirtualPageId(this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT);
                    }

                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                        this.TSM_PROCESS_NAME, 
                        this.TSM_STATE_PAGE_INITIALIZATION,
                        null,
                        "Failed to create initialize device link info.",
                        e);
                }
            }).done(async () => {
                if (this.initializationSucceeded) {
                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_PAGE_INITIALIZATION);
                }

                this.displayVirtualPage(this.currentVirtualPageId());

                bridge.fireEvent(CloudExperienceHost.Events.visible, true);
            });
        }

        async createQrCodeAsync() {
            try {
                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_GENERATE_QR);

                let walletBarcode = new Windows.ApplicationModel.Wallet.WalletBarcode(Windows.ApplicationModel.Wallet.WalletBarcodeSymbology.qr, this.deviceLinkInfo);

                let image = await walletBarcode.getImageAsync();
                if (image != null) {
                    let qrCodeElement = document.getElementById("qrCodeImage");

                    qrCodeElement.setAttribute("aria-label", resourceStrings.DeviceLinkQRCodeNarratorText);
                    let blob = await image.openReadAsync();

                    let qrImageStream = MSApp.createStreamFromInputStream("image/bmp", blob);
                    qrCodeElement.src = URL.createObjectURL(qrImageStream);

                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_GENERATE_QR);
                } else {
                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_GENERATE_QR, null, "Could not get QR image", null);
                }
            } catch (e) {
                await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_GENERATE_QR, null, "Failed to create QR code", e);
            }
        }

        waitForDebuggerAttachmentAsync() {
            return this.sessionUtilities.getSettingAsync(this.sessionUtilities.STATE_NAME_GLOBAL_SHOULD_WAIT_FOR_DEBUGGER_ATTACH).then((debuggerFlagValue) => {
                if ((null === debuggerFlagValue) || (debuggerFlagValue.length === 0)) {
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "DeviceLinkPage_DebuggerAttachment_Success",
                        `DeviceLinkPage: Done waiting for debugger to attach (value == ${debuggerFlagValue}).`);

                    return WinJS.Promise.as(true);
                }

                this.commercialDiagnosticsUtilities.logInfoEvent("DeviceLinkPage_DebuggerAttachment_Waiting", "DeviceLinkPage: Waiting 5 seconds for debugger to attach.");

                return WinJS.Promise.timeout(5000).then(() => {
                    return this.waitForDebuggerAttachment();
                });
            });
        }

        async exitPageAsync(pageExitStatus) {
            try {
                let result = CloudExperienceHost.AppResult.success;
                let dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_SUCCESSFUL_DAP_PAGE_EXIT;

                switch (pageExitStatus) {
                    case this.PAGE_EXIT_STATUS_SUCCESS:
                        result = CloudExperienceHost.AppResult.success;
                        dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_SUCCESSFUL_DAP_PAGE_EXIT;

                        await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_PAGE);
                        break;

                    case this.PAGE_EXIT_STATUS_SUCCESS_BACK_TO_OOBE_START:
                        result = CloudExperienceHost.AppResult.action1;
                        dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_SUCCESSFUL_DAP_PAGE_EXIT_TO_OOBE_START;

                        await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_PAGE, "Navigating back to OOBE start.");
                        break;

                    case this.PAGE_EXIT_STATUS_ERROR:
                        result = CloudExperienceHost.AppResult.fail;
                        dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_ERROR_DAP_PAGE_EXIT;

                        await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_PAGE, null, "Exiting page on error.", null);
                        break;

                    case this.PAGE_EXIT_STATUS_CANCELED:
                        result = CloudExperienceHost.AppResult.cancel;
                        dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_CANCELED_DAP_PAGE_EXIT;

                        await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(
                            this.TSM_PROCESS_NAME, 
                            this.TSM_STATE_PAGE, 
                            "Exiting page on user-initiated cancellation");
                        break;

                    case this.PAGE_EXIT_STATUS_CANCELED_BACK_TO_OOBE_START:
                        result = CloudExperienceHost.AppResult.action1;
                        dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_CANCELED_DAP_PAGE_EXIT_TO_OOBE_START;

                        await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(
                            this.TSM_PROCESS_NAME, 
                            this.TSM_STATE_PAGE, 
                            "Exiting page on user-initiated cancellation and navigating back to OOBE start.");
                        break;

                    case this.VIRTUAL_PAGE_ID_DEVICE_LINK_NOT_SUPPORTED_RESULT:
                        result = CloudExperienceHost.AppResult.action1;
                        dapCommandPhaseId = this.DAP_COMMANDS_PHASE_ID_ON_UNSUPPORTED_DEVICE_DAP_EXIT_TO_OOBE_START;

                        await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                            this.TSM_PROCESS_NAME, 
                            this.TSM_STATE_PAGE, 
                            "UnsupportedDevice",
                            "Exiting page due to unsupported device and navigating back to OOBE start.",
                            null);
                        break;

                    default:
                        this.commercialDiagnosticsUtilities.logInfoEvent(
                            "DeviceLinkPage_ExitPageAsync_Error",
                            this.commercialDiagnosticsUtilities.formatMessage(
                                "DeviceLinkPage: Exiting page on unknown page exit status ({0})",
                                pageExitStatus));
                        break;
                }

                return this.sessionUtilities.startPhaseStateMachineAsync(
                    dapCommandPhaseId,
                    this.sessionUtilities.AUTOMATION_COMMAND_PHASE_NAME_PREACTION,
                    () => {
                        return bridge.fireEvent(CloudExperienceHost.Events.done, result);
                    },
                    (actionResultToUse) => {
                        return WinJS.Promise.as(true);
                    }
                );

            } catch (e) {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "DeviceLinkPage_ExitPageAsync_FailedWithError",
                    "DeviceLinkPage: Exiting the page failed.",
                    e);
            }
        }

        displayVirtualPage(nextVirtualPageId) {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "DeviceLinkPage_DisplayVirtualPage_Navigation",
                this.commercialDiagnosticsUtilities.formatMessage(
                    "DeviceLinkPage: Navigating from virtual page {0} to {1}",
                    this.currentVirtualPageId(),
                    nextVirtualPageId));

            this.allVirtualPages[this.currentVirtualPageId()].isVisible(false);

            for (let i = 0; i < this.allVirtualPages[nextVirtualPageId].buttonSet.length; i++) {
                if (i == this.allVirtualPages[nextVirtualPageId].buttonSet.length - 1) {
                    this.allVirtualPages[nextVirtualPageId].buttonSet[i].isPrimaryButton = true;
                    this.allVirtualPages[nextVirtualPageId].buttonSet[i].autoFocus = true;
                } else {
                    this.allVirtualPages[nextVirtualPageId].buttonSet[i].isPrimaryButton = false;
                    this.allVirtualPages[nextVirtualPageId].buttonSet[i].autoFocus = false;
                }
            }

            this.currentVirtualPageId(nextVirtualPageId);
            let currentVirtualPageInfo = this.allVirtualPages[this.currentVirtualPageId()];

            this.pageTitle(currentVirtualPageInfo.pageTitle);

            bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", currentVirtualPageInfo.lottieAnimation);

            currentVirtualPageInfo.isVisible(true);

            if (currentVirtualPageInfo.onVisibleHandler !== undefined) {
                currentVirtualPageInfo.onVisibleHandler();
            }
        }

        async onCancelButtonClickAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "DeviceLinkPage_CancelButtonClicked_Started",
                "DeviceLinkPage: Cancel button clicked");

            switch (this.currentVirtualPageId()) {
                case this.VIRTUAL_PAGE_ID_DEVICE_LINK_OPTIONS:
                    await this.exitPageAsync(this.PAGE_EXIT_STATUS_CANCELED);
                    break;

                case this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS:
                    this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_OPTIONS);
                    break;

                default:
                    this.commercialDiagnosticsUtilities.logErrorEvent(
                        "DeviceLinkPage_CancelButtonClicked_UnexpectedCurrentVirtualPage",
                        this.commercialDiagnosticsUtilities.formatMessage("DeviceLinkPage: Cancel was clicked on an unexpected virtual page ({0})", this.currentVirtualPageId()),
                        this.commercialDiagnosticsUtilities.unexpectedErrorCode);
            }
        }

        async onNextButtonClickAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "DeviceLinkPage_NextButtonClicked_Started",
                "DeviceLinkPage: Next button clicked");

            await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_LINK_DEVICE_OPTIONS, null);
            
            this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS);
        }

        async onStartOverButtonClickAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "DeviceLinkPage_StartOverButtonClicked_Started",
                "DeviceLinkPage: Start Over button clicked");

            this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_OPTIONS);
        }

        async onExitButtonClickAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "DeviceLinkPage_ExitButtonClicked_Started",
                "DeviceLinkPage: Exit button clicked");

            if (this.allVirtualPages[this.currentVirtualPageId()].exitPageStatus !== undefined) {
                await this.exitPageAsync(this.allVirtualPages[this.currentVirtualPageId()].exitPageStatus);
            } else {
                this.commercialDiagnosticsUtilities.logErrorEvent(
                    "DeviceLinkPage_ExitButtonClicked_UnexpectedCurrentVirtualPage",
                    this.commercialDiagnosticsUtilities.formatMessage("DeviceLinkPage: Exit was clicked on an unexpected virtual page ({0})", this.currentVirtualPageId()),
                    this.commercialDiagnosticsUtilities.unexpectedErrorCode);
            }
        }

        async onTryAgainButtonClickAsync() {
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "DeviceLinkPage_TryAgainButtonClicked_Started",
                "DeviceLinkPage: Try Again button clicked");

            this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS);
        }

        async onExportDeviceLinkInfoClickAsync() {
            if (!this.exportDeviceLinkInfoEnabled()) {
                this.commercialDiagnosticsUtilities.logInfoEventName("DeviceLinkPage_ExportDeviceLinkInfo_AlreadyRunning");
                return;
            }
        
            this.showExportLinkSuccess(false);
            this.showExportLinkError(false);

            await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_EXPORT_DEVICE_LINK_INFO);

            this.DIAGNOSTICS_LOGS_EXPORT_MAX_DURATION_IN_MILLISECONDS = 3 * 60 * 1000; // 3 minutes;

            this.exportDeviceLinkInfoEnabled(false);

            return this.commercialDiagnosticsUtilities.getExportLogsFolderPathAsync().then(
                async (folderPath) => {                   
                    this.commercialDiagnosticsUtilities.logInfoEvent(
                        "DeviceLinkPage_ExportDeviceLinkInfo_RemovableDriveFound",
                        `Device link info will be exported to folder: ${folderPath}`);

                    let hasTimedOut = false;
                    return WinJS.Promise.timeout(
                        this.DIAGNOSTICS_LOGS_EXPORT_MAX_DURATION_IN_MILLISECONDS,
                        this.deviceLinkUtilities.exportDeviceLinkInfoCsvAsync(folderPath, this.DEVICE_LINK_FORMAT_FLAGS)).then(
                            async () => {
                                if (hasTimedOut) {
                                    return;
                                }

                                this.commercialDiagnosticsUtilities.logInfoEventName("DeviceLinkPage_ExportDeviceLinkInfo_Succeeded");

                                this.exportDeviceLinkInfoEnabled(true);
                                this.exportLinkSuccessResult(this.deviceLinkExportSuccessMessage);
                                this.showExportLinkSuccess(true);

                                await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_EXPORT_DEVICE_LINK_INFO, null);
                            },

                            async (e) => {
                                hasTimedOut = true;
                                this.exportDeviceLinkInfoEnabled(true);
                                this.exportLinkErrorResult(this.deviceLinkExportTimeoutMessage);
                                this.showExportLinkError(true);

                                await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                                    this.TSM_PROCESS_NAME, 
                                    this.TSM_STATE_EXPORT_DEVICE_LINK_INFO,
                                    "TimedOut" ,
                                    "Export of device link info timed out.", 
                                    null);
                            });
                },
                async (e) => {
                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                        this.TSM_PROCESS_NAME, 
                        this.TSM_STATE_EXPORT_DEVICE_LINK_INFO,
                        "FolderPicker",
                        "No exportable drive found.", 
                        e);

                    this.exportDeviceLinkInfoEnabled(true);
                    this.exportLinkErrorResult(this.deviceLinkExportErrorMessage);
                    this.showExportLinkError(true);
                });
        }

        onSuccessVirtualPageVisible() {
            this.showDeviceLinkOptionsVirtualPage(false);
            this.successResultBody(
                this.commercialDiagnosticsUtilities.formatMessage(
                    this.resourceStrings["DeviceLinkSuccessResultBody"],
                    "Contoso, Inc."));
        }

        onFailureVirtualPageVisible() {
            this.showDeviceLinkOptionsVirtualPage(false);
        }

        onNotSupportedVirtualPageVisible() {
            this.showDeviceLinkOptionsVirtualPage(false);
        }

        async onOptionsVirtualPageVisible() {
            await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_LINK_DEVICE_OPTIONS);

            this.showExportLinkSuccess(false);
            this.showExportLinkError(false);

            if (this.deviceLinkManager.getConfigureDeviceLinkResult() === ModernDeployment.Autopilot.Core.ConfigureDeviceLinkResult.successfullyAppliedLink) {
                await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_LINK_DEVICE_OPTIONS, "Device link is already configured.");

                this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_SUCCESS_RESULT);
            } else {
                this.createQrCodeAsync();
            }
        }

        async onProgressVirtualPageVisible() {
            try {
                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_LINK_DEVICE);
                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_REQUEST_DISCOVERY_URL);

                let discoveryUrlRequestInfo = await this.deviceLinkManager.requestDiscoveryUrlAsync(this.deviceLinkInfo);

                if (((discoveryUrlRequestInfo.discoveryUrlRequestResultValue !== ModernDeployment.Autopilot.Core.DiscoveryUrlRequestResult.successfullyRetrievedUrl) &&
                    (discoveryUrlRequestInfo.discoveryUrlRequestResultValue !== ModernDeployment.Autopilot.Core.DiscoveryUrlRequestResult.successfullyRetrievedUrlAndReceivedRedirection)) ||
                    ((discoveryUrlRequestInfo.discoveryUrl == null ) || (discoveryUrlRequestInfo.discoveryUrl.length == 0))) {
                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                        this.TSM_PROCESS_NAME, 
                        this.TSM_STATE_REQUEST_DISCOVERY_URL,
                        null,
                        `Failed to request discovery URL with result: ${discoveryUrlRequestInfo.discoveryUrlRequestResultValue}`,
                        null);

                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                        this.TSM_PROCESS_NAME, 
                        this.TSM_STATE_LINK_DEVICE,
                        "RequestDiscoveryUrl",
                        "Failed to obtain request URL",
                        null);
                        
                    this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT);
                    return;
                }

                let discoveryUrl = discoveryUrlRequestInfo.discoveryUrl;
                let tenantId = discoveryUrlRequestInfo.tenantId;
                await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_REQUEST_DISCOVERY_URL, `Discovery URL: ${discoveryUrl}, Tenant ID: ${tenantId}`);


                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK);

                let currentConfigurationStep = null;
        
                return this.deviceLinkManager.configureDeviceLinkAsync(discoveryUrl, tenantId, null).then(async (result) => {
                    if (this.currentVirtualPageId() == this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS) {
                        if (result === ModernDeployment.Autopilot.Core.ConfigureDeviceLinkResult.successfullyAppliedLink) {
                            if (currentConfigurationStep != null) {
                                await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                            }

                            await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK);
                            await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_LINK_DEVICE);

                            this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_SUCCESS_RESULT);
                        } else {
                            if (currentConfigurationStep != null) {
                                await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(this.TSM_PROCESS_NAME, currentConfigurationStep, null, null, null);
                            }

                            await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                                this.TSM_PROCESS_NAME, 
                                this.TSM_STATE_CONFIGURE_DEVICE_LINK,
                                null, 
                                `Failed to apply device link with result: ${result}.`,
                                null);

                            await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                                this.TSM_PROCESS_NAME, 
                                this.TSM_STATE_LINK_DEVICE, 
                                "ConfigureDeviceLink", 
                                "Failed to configure device link.", 
                                null);

                            this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT);
                        }
                    }
                    else
                    {
                        await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK, "User cancelled.");
                        await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_LINK_DEVICE, "User cancelled.");
                    }
                }, async (e) => {
                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                        this.TSM_PROCESS_NAME, 
                        this.TSM_STATE_CONFIGURE_DEVICE_LINK,
                        null, 
                        "Unexpected error configuring device link",
                        e);

                    await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                        this.TSM_PROCESS_NAME, 
                        this.TSM_STATE_LINK_DEVICE, 
                        "ConfigureDeviceLink", 
                        "Exception hit while attempting to configure device link.", 
                        null);

                    this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT);
                }, async (progress) => {
                    if (this.currentVirtualPageId() == this.VIRTUAL_PAGE_ID_DEVICE_LINK_PROGRESS) {
                        switch (progress) {
                            case ModernDeployment.Autopilot.Core.DeviceLinkConfigurationStatus.enrollmentDiscovery:
                                if (currentConfigurationStep != null) {
                                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                                }

                                currentConfigurationStep = this.TSM_STATE_REQUEST_ENROLLMENT_DISCOVERY;
                                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_REQUEST_ENROLLMENT_DISCOVERY);
                                break;
                                
                            case ModernDeployment.Autopilot.Core.DeviceLinkConfigurationStatus.tpmAttesting:
                                if (currentConfigurationStep != null) {
                                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                                }

                                currentConfigurationStep = this.TSM_STATE_CONFIGURE_DEVICE_LINK_TPM_ATTEST;
                                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK_TPM_ATTEST);
                                break;

                            case ModernDeployment.Autopilot.Core.DeviceLinkConfigurationStatus.initiatingMaaAttestationRequest:                                
                                if (currentConfigurationStep != null) {
                                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                                }

                                currentConfigurationStep = this.TSM_STATE_CONFIGURE_DEVICE_LINK_MAA_ATTEST;
                                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK_MAA_ATTEST);
                                break;

                            case ModernDeployment.Autopilot.Core.DeviceLinkConfigurationStatus.retrievingDeviceLink:
                                if (currentConfigurationStep != null) {
                                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                                }

                                currentConfigurationStep = this.TSM_STATE_CONFIGURE_DEVICE_LINK_RETRIEVE_DEVICE_LINK;
                                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK_RETRIEVE_DEVICE_LINK);
                                break;

                            case ModernDeployment.Autopilot.Core.DeviceLinkConfigurationStatus.retrievingDeviceLinkFromRedirectedUrl:
                                if (currentConfigurationStep != null) {
                                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                                }

                                currentConfigurationStep = this.TSM_STATE_CONFIGURE_DEVICE_LINK_RETRIEVE_DEVICE_LINK;
                                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK_RETRIEVE_DEVICE_LINK);
                                break;

                            case ModernDeployment.Autopilot.Core.DeviceLinkConfigurationStatus.applyingDeviceLink:
                                if (currentConfigurationStep != null) {
                                    await this.commercialDiagnosticsUtilities.logTsmProcessEndSuccessAsync(this.TSM_PROCESS_NAME, currentConfigurationStep);
                                }

                                currentConfigurationStep = this.TSM_STATE_CONFIGURE_DEVICE_LINK_APPLY_DEVICE_LINK;
                                await this.commercialDiagnosticsUtilities.logTsmProcessStartAsync(this.TSM_PROCESS_NAME, this.TSM_STATE_CONFIGURE_DEVICE_LINK_APPLY_DEVICE_LINK);
                                break;

                            default:
                                this.commercialDiagnosticsUtilities.logInfoEvent(
                                    "DeviceLinkPage_ProgressVirtualPage_UnknownProgress",
                                    `DeviceLinkPage: Unknown progress value (${progress})...`);
                                break;
                        }
                    }
                });
            } catch (e) {
                await this.commercialDiagnosticsUtilities.logTsmProcessEndErrorAsync(
                    this.TSM_PROCESS_NAME, 
                    this.TSM_STATE_LINK_DEVICE, 
                    "ExceptionOccurred", 
                    "Failed to complete device link operation.", 
                    e);
                
                this.displayVirtualPage(this.VIRTUAL_PAGE_ID_DEVICE_LINK_ERROR_RESULT);
            }
        }        
    }

    return DeviceLinkViewModel;
});
