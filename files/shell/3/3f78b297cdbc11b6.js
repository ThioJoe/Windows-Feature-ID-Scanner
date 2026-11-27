
"use strict";

define([
    'lib/knockout',
    'legacy/bridge',
    'legacy/appObjectFactory',
    'autopilot/commercialDiagnosticsUtilities',
    'autopilot/bootstrapSessionGeneralUtilities'], (
    ko,
    bridge,
    appObjectFactory,
    commercialDiagnosticsUtilities,
    bootstrapSessionGeneralUtilities) => {
    class ExportDiagnosticsViewModel {
        constructor(resourceStrings, targetPersonality) {

            this.resourceStrings = resourceStrings;


            this.DIAGNOSTICS_PAGE_LOGS_EXPORT_PROGRESS_TEXT = this.resourceStrings["ExportDiagnosticsPageLogsExportInProgressText"];
            this.DETAILS = this.resourceStrings["ExportDiagnosticsPageDetailsHeading"];
            this.LOG_EXPORT_SUCCEEDED = this.resourceStrings["ExportDiagnosticsPageLogsExportSuccessText"];
            this.ERROR_ADDITIONAL_INFO_HEADING = this.resourceStrings["DiagnosticsPageErrorAdditionalInfoHeading"];

            this.STATUS_SUCCESS = this.resourceStrings["BootstrapPageComplete"]; // Complete
            this.STATUS_FAILURE = this.resourceStrings["BootstrapPageStatusFailed"]; // Error
            this.STATUS_IN_PROGRESS = this.resourceStrings["BootstrapPageStillWorking"]; // Still working on it
            this.STATUS_WARNING = this.resourceStrings["EnrollmentErrorFinishedTitle"]; // There was a problem

            this.EXPORTLOGS_PREVIOUS_CXID_NAME = "ExportLogsPreviousCXID";
            this.DIAGNOSTICS_LOGS_EXPORT_AREA_NAME = "DiagnosticsLogsExportArea";
            this.DIAGNOSTICS_LOGS_EXPORT_AREA_DEFAULT = "Autopilot;TPM";
            this.DIAGNOSTICS_LOGS_EXPORT_FILE_NAME = "MDMDiagReport.zip";
            this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR = 0x81039025; // defined in AutopilotErrors.mc
            this.PAGE_UNIVERSAL_TIMEOUT_MILLISECONDS = 2 * 60 * 1000; // 2 minutes

            this.BUTTON_SET_NONE = 0;
            this.BUTTON_SET_DEFAULT = 1;
            this.BUTTON_SET_LOGS_EXPORT = 2;
            this.BUTTON_SET_LOGS_EXPORT_FAILURE = 3;

            this.pageTitle = ko.observable(this.resourceStrings["ExportDiagnosticsPageTitle"]);
            this.errorCode = ko.observable("");
            this.errorDescription = ko.observable("");
            this.errorSubHeader = ko.observable("");
            this.logExportErrorSubheader = ko.observable("");

            this.isLiteWhitePersonality = (targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite);

            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities();
            this.sessionUtilities = new bootstrapSessionGeneralUtilities(true); // Argument doesn't matter since it's not used here.

            this.shouldShowError = ko.observable(false);
            this.shouldShowLogsExportProgress = ko.observable(false);
            this.shouldShowLogsExportSpinner = ko.observable(false);
            this.shouldShowLogsExportError = ko.observable(false);
            this.logExportSucceeded = ko.observable(false);
            this.outputLogPath = ko.observable("");

            this.regionVisibilityFlags = [
                this.shouldShowLogsExportProgress,
                this.shouldShowError
            ];

            this.defaultLottieFile = "autopilotLottie.json";
            this.failureLottieFile = "errorLottie.json";


            this.buttonVisibility = ko.observable(this.BUTTON_SET_DEFAULT);

            this.closeLogsExportSuccessButton = {
                buttonText: this.resourceStrings["ExportDiagnosticsPageCloseButton"],
                buttonType: "button",
                isPrimaryButton: true,
                isVisible: true,
                buttonClickHandler: () => {
                    this.closeLogsExportButtonClick();
                }
            };

            this.closeLogsExportFailureButton = this.closeLogsExportSuccessButton;
            this.closeLogsExportFailureButton.isPrimaryButton = false;

            this.exportLogsButton = {
                buttonText: this.resourceStrings["ExportDiagnosticsPageExportLogsButton"],
                buttonType: "button",
                isPrimaryButton: true,
                isVisible: true,
                buttonClickHandler: () => {
                    this.exportLogsButtonClick();
                }
            };

            this.tryExportLogsAgainButton = {
                buttonText: this.resourceStrings["ExportDiagnosticsPageTryAgainButton"],
                buttonType: "button",
                isPrimaryButton: true,
                isVisible: true,
                buttonClickHandler: () => {
                    this.exportLogsButtonClick();
                }
            }

            const flexEndButtonSets = {};

            flexEndButtonSets[this.BUTTON_SET_NONE] = [];

            flexEndButtonSets[this.BUTTON_SET_DEFAULT] = [
                this.exportLogsButton
            ];

            flexEndButtonSets[this.BUTTON_SET_LOGS_EXPORT] = [
                this.closeLogsExportSuccessButton
            ];

            flexEndButtonSets[this.BUTTON_SET_LOGS_EXPORT_FAILURE] = [
                this.closeLogsExportFailureButton,
                this.tryExportLogsAgainButton
            ];

            this.flexEndButtons = ko.pureComputed(() => {
                return flexEndButtonSets[this.buttonVisibility()];
            });

            this.exportLogsButtonClick();
        }

        closeButtonClick() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CloudExperienceHost.ExportDiagnostics.CloseButton clicked");

            bridge.fireEvent(constants.Events.done, constants.AppResult.cancel);
        }

        setLogsCollectionError(subheader, code) {
            bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", this.failureLottieFile);

            if (!this.isLiteWhitePersonality) {
                let errorSubheader = this.commercialDiagnosticsUtilities.formatMessage(
                    subheader, 
                    this.commercialDiagnosticsUtilities.formatNumberAsHexString(code, 8));
                this.logExportErrorSubheader(errorSubheader);
            }

            this.buttonVisibility(this.BUTTON_SET_LOGS_EXPORT_FAILURE);
            
            this.shouldShowLogsExportSpinner(false);
            this.shouldShowLogsExportError(true);
        }

        exportLogsButtonClick() {
            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_ExportDiagnostics_LogsExport_Started");

            this.buttonVisibility(this.BUTTON_SET_NONE);

            this.showOnlySpecificRegion(this.shouldShowLogsExportProgress);
            this.shouldShowLogsExportSpinner(true);
            this.shouldShowLogsExportError(false);

            return this.commercialDiagnosticsUtilities.getExportLogsFolderPathAsync().then((folderPath) => {
                return bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", this.DIAGNOSTICS_LOGS_EXPORT_AREA_NAME).then(
                    (logsAreaValue) => {
                        if (logsAreaValue === null || logsAreaValue === undefined) {
                            logsAreaValue = this.DIAGNOSTICS_LOGS_EXPORT_AREA_DEFAULT;
                        }

                        let hasTimedOut = false;

                        let timerId = setTimeout(() => {
                            hasTimedOut = true;

                            this.commercialDiagnosticsUtilities.logHresultEvent(
                                "CommercialOOBE_ExportDiagnostics_CollectLogs_TimedOut",
                                "Collecting logs took longer than the specified timeout",
                                this.commercialDiagnosticsUtilities.timeoutErrorCode);

                            this.setLogsCollectionError(
                                this.resourceStrings["ExportDiagnosticsPageLogsExportTimeoutMessage"],
                                this.commercialDiagnosticsUtilities.timeoutErrorCode);

                            this.displayError(
                                this.BUTTON_SET_LOGS_EXPORT_FAILURE,
                                this.commercialDiagnosticsUtilities.timeoutErrorCode,
                                this.resourceStrings["ExportDiagnosticsPageLogsExportTimeoutMessageNoErrorCode"],
                                this.resourceStrings["ExportDiagnosticsPageLogsExportFailureSubheader"]);

                            return;
                        }, this.PAGE_UNIVERSAL_TIMEOUT_MILLISECONDS);

                        let outputLogFilePath = folderPath + "\\" + this.DIAGNOSTICS_LOGS_EXPORT_FILE_NAME;
                        return this.sessionUtilities.enrollmentApis.collectLogsEx(logsAreaValue, outputLogFilePath).then(() => {
                            if (hasTimedOut) {
                                return;
                            }

                            clearTimeout(timerId);

                            this.buttonVisibility(this.BUTTON_SET_LOGS_EXPORT);

                            this.shouldShowLogsExportSpinner(false);

                            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_ExportDiagnostics_LogsExport_Succeeded");

                            this.outputLogPath(outputLogFilePath);

                            if (this.isLiteWhitePersonality) {
                                this.logExportSucceeded(true);
                            } else {
                                this.pageTitle(this.resourceStrings["ExportDiagnosticsPageLogsExportSuccessText"]);
                            }
                        }, (e) => {
                            this.commercialDiagnosticsUtilities.logExceptionEvent(
                                "CommercialOOBE_ExportDiagnostics_LogsExport_Failed",
                                "Diagnostics page collectLogsEx failed.",
                                e);
                            
                            if (hasTimedOut) {
                                return;
                            }
                            clearTimeout(timerId);

                            let code = e.number ? e.number : this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR;

                            this.setLogsCollectionError(
                                this.resourceStrings["ExportDiagnosticsPageLogsExportFailureMessage"],
                                code);

                            this.displayError(
                                this.BUTTON_SET_LOGS_EXPORT_FAILURE,
                                code,
                                this.resourceStrings["ExportDiagnosticsPageLogsExportFailureMessageNoErrorCode"],
                                this.resourceStrings["ExportDiagnosticsPageLogsExportFailureSubheader"]);
                        });
                    });
            }, (e) => {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ExportDiagnostics_LogsExport_Failed",
                    "Folder picker failed.",
                    e);

                let code = e.number ? e.number : this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR;

                this.setLogsCollectionError(
                    this.resourceStrings["ExportDiagnosticsPageLogsExportFailureMessage"],
                    code);

                this.displayError(
                    this.BUTTON_SET_LOGS_EXPORT_FAILURE,
                    code,
                    this.resourceStrings["ExportDiagnosticsPageLogsExportFailureMessageNoErrorCode"],
                    this.resourceStrings["ExportDiagnosticsPageLogsExportFailureSubheader"]);
            });
        }

        closeLogsExportButtonClick() {
            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_ExportDiagnostics_LogsExport_CloseButtonPressed");

            this.logExportSucceeded(false);

            bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", this.EXPORTLOGS_PREVIOUS_CXID_NAME).then(
                (previousNodeCxid) => {
                    try {
                        this.commercialDiagnosticsUtilities.logInfoEvent(
                            "CommercialOOBE_ExportDiagnostics_LogsExport_CloseButtonPressed",
                            this.commercialDiagnosticsUtilities.formatMessage("Navigating to CXID '{0}'...", previousNodeCxid));

                        return bridge.fireEvent(CloudExperienceHost.Events.done, previousNodeCxid);
                    } catch (e) {
                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                            "CommercialOOBE_ExportDiagnostics_LogsExport_CloseButtonPressed_Failed",
                            this.commercialDiagnosticsUtilities.formatMessage(
                                "Navigating to CXID: {0} in closeButtonClick failed.",
                                this.DIAGNOSTICS_PREVIOUS_CXID_NAME),
                            e);
                    }
                }, (e) => {
                    this.commercialDiagnosticsUtilities.logExceptionEvent(
                        "CommercialOOBE_ExportDiagnostics_LogsExport_CloseButtonPressed_PreviousCxidRetrievalFailed",
                        this.commercialDiagnosticsUtilities.formatMessage(
                            "CloudExperienceHost.Storage.SharableData.getValue for CXID: {0} in closeButtonClick failed.",
                            this.DIAGNOSTICS_PREVIOUS_CXID_NAME),
                        e);
                });
        }

        showOnlySpecificRegion(region) {
            this.pageTitle(this.resourceStrings["ExportDiagnosticsPageTitle"]);

            try {
                if (region !== this.shouldShowError) {
                    bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", this.defaultLottieFile);
                } else {
                    bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", this.failureLottieFile);
                }

                for (let i = 0; i < this.regionVisibilityFlags.length; i++) {
                    (this.regionVisibilityFlags[i])(false);
                }
                region(true);

                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_ExportDiagnostics_ShowOnlySpecificRegion_Succeeded",
                    "Invoked showOnlySpecificRegion successfully.");

            } catch (e) {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_ExportDiagnostics_ShowOnlySpecificRegion_Failed",
                    "showOnlySpecificRegion failed.",
                    e);
            }
        }

        displayError(buttonVisibility, code, description, subheaderOverride) {
            this.buttonVisibility(buttonVisibility);

            this.errorSubHeader((subheaderOverride === undefined || subheaderOverride === null) ? this.resourceStrings["ExportDiagnosticsPageTryAgainFailureMessage"] : subheaderOverride);

            let errorCode = this.commercialDiagnosticsUtilities.formatMessage(
                this.resourceStrings["ExportDiagnosticsPageErrorCode"], 
                this.commercialDiagnosticsUtilities.formatNumberAsHexString(code, 8));
            this.errorCode(errorCode);

            let errorDescription = null;
            switch (code) {
                case this.commercialDiagnosticsUtilities.hresultAutopilotLogExportNoDrive:
                    errorDescription = this.resourceStrings["ExportDiagnosticsPageLogsExportFailureNoUsbDriveFoundMessage"];
                    break;

                case this.commercialDiagnosticsUtilities.hresultFileExists:
                    errorDescription = this.resourceStrings["ExportDiagnosticsPageLogsExportFailureFileExistsMessage"];
                    break;

                case this.commercialDiagnosticsUtilities.timeoutErrorCode:
                    errorDescription = this.resourceStrings["ExportDiagnosticsPageLogsExportTimeoutMessage"];
                    break;

                default:
                    errorDescription = this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings["ExportDiagnosticsPageErrorDescription"], description);;
                    break;
            }
            this.errorDescription(errorDescription);

            this.showOnlySpecificRegion(this.shouldShowError);
        }
    }

    return ExportDiagnosticsViewModel;
});
