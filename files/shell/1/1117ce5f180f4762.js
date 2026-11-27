
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
    class TroubleshootingDiagnosticsViewModel {
        constructor(resourceStrings, targetPersonality) {

            this.resourceStrings = resourceStrings;


            this.DIAGNOSTICS_PAGE_RENDERING_TEXT = this.resourceStrings["DiagnosticsPageRenderingText"];
            this.CONFIGURATION_TITLE = this.resourceStrings["DiagnosticsPageConfigurationTitle"];
            this.DEPLOYMENT_TITLE = this.resourceStrings["DiagnosticsPageDeploymentTitle"];
            this.APPS_AND_POLICY_TITLE = this.resourceStrings["DiagnosticsPageAppsAndPolicyTitle"];
            this.APP_INFO_TITLE = this.resourceStrings["DiagnosticsPageAppInfoTitle"];
            this.POLICY_INFO_TITLE = this.resourceStrings["DiagnosticsPagePolicyInfoTitle"];
            this.STATUS_HEADING = this.resourceStrings["DiagnosticsPageStatusHeading"];
            this.EVENT_HEADING = this.resourceStrings["DiagnosticsPageEventHeading"];
            this.START_TIME_HEADING = this.resourceStrings["DiagnosticsPageStartTimeHeading"];
            this.FINISH_TIME_HEADING = this.resourceStrings["DiagnosticsPageFinishTimeHeading"];
            this.DETAILS_HEADING = this.resourceStrings["DiagnosticsPageDetailsHeading"];
            this.ERROR_ADDITIONAL_INFO_HEADING = this.resourceStrings["DiagnosticsPageErrorAdditionalInfoHeading"];
            this.DIAGNOSTICS_PAGE_LOGS_EXPORT_PROGRESS_TEXT = this.resourceStrings["DiagnosticsPageLogsExportInProgressText"];
            this.SHOW_DETAILS = this.resourceStrings["BootstrapPageShowDetailsButton"];
            this.HIDE_DETAILS = this.resourceStrings["BootstrapPageHideDetailsButton"];
            this.DETAILS = this.resourceStrings["DiagnosticsPageDetailsHeading"];
            this.LOG_EXPORT_SUCCEEDED = this.resourceStrings["DiagnosticsPageLogsExportSuccessText"];

            this.STATUS_SUCCESS = this.resourceStrings["BootstrapPageComplete"]; // Complete
            this.STATUS_FAILURE = this.resourceStrings["BootstrapPageStatusFailed"]; // Error
            this.STATUS_IN_PROGRESS = this.resourceStrings["BootstrapPageStillWorking"]; // Still working on it
            this.STATUS_WARNING = this.resourceStrings["EnrollmentErrorFinishedTitle"]; // There was a problem

            this.DIAGNOSTICS_PREVIOUS_CXID_NAME = "DiagnosticsPreviousCXID";
            this.DIAGNOSTICS_LOGS_EXPORT_AREA_NAME = "DiagnosticsLogsExportArea";
            this.DIAGNOSTICS_LOGS_EXPORT_AREA_DEFAULT = "Autopilot;TPM";
            this.DIAGNOSTICS_LOGS_EXPORT_FILE_NAME = "MDMDiagReport.zip";
            this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR = 0x81039025; // defined in AutopilotErrors.mc
            this.PAGE_UNIVERSAL_TIMEOUT_MILLISECONDS = 2 * 60 * 1000; // 2 minutes

            this.BUTTON_SET_NONE = 0;
            this.BUTTON_SET_DEFAULT = 1;
            this.BUTTON_SET_LOGS_EXPORT = 2;
            this.BUTTON_SET_LOGS_EXPORT_FAILURE = 3;

            this.pageTitle = ko.observable(this.resourceStrings["DiagnosticsPageTitle"]);
            this.errorCode = ko.observable("");
            this.errorDescription = ko.observable("");
            this.errorSubHeader = ko.observable("");
            this.logExportErrorSubheader = ko.observable("");

            this.isLiteWhitePersonality = (targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite);

            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities();
            this.sessionUtilities = new bootstrapSessionGeneralUtilities(true); // Argument doesn't matter since it's not used here.
            this.autopilotLogger = new ModernDeployment.Autopilot.Core.AutopilotLogging();

            this.diagnosticEvent = ko.observable(0);
            this.staticData = ko.observable(1);
            this.resourceEvent = ko.observable(2);

            this.CONFIGURATION_INFO_TAB_INDEX = 0;
            this.DEPLOYMENT_INFO_TAB_INDEX = 1;
            this.APP_AND_POLICY_STATUS_TAB_INDEX = 2;

            this.shouldShowDataRenderingProgress = ko.observable(true);
            this.shouldShowDiagnosticData = ko.observable(false);
            this.shouldShowError = ko.observable(false);
            this.shouldShowLogsExportProgress = ko.observable(false);
            this.shouldShowLogsExportSpinner = ko.observable(false);
            this.shouldShowLogsExportError = ko.observable(false);
            this.logExportSucceeded = ko.observable(false);
            this.outputLogPath = ko.observable("");

            this.cachedErrorState = null;

            this.regionVisibilityFlags = [
                this.shouldShowDataRenderingProgress,
                this.shouldShowDiagnosticData,
                this.shouldShowLogsExportProgress,
                this.shouldShowError
            ];

            this.configurationInfoTab = ko.observable();
            this.deploymentInfoByCategory = ko.observable();
            this.provisionedResourceData = ko.observable();
            this.diagnosticDataTabs = ko.observable({});

            this.defaultLottieFile = "autopilotLottie.json";
            this.failureLottieFile = "errorLottie.json";


            this.buttonVisibility = ko.observable(this.BUTTON_SET_NONE);

            this.closeButton = {
                buttonText: this.resourceStrings["DiagnosticsPageCloseButton"],
                buttonType: "button",
                isPrimaryButton: false,
                isVisible: true,
                buttonClickHandler: () => {
                    this.closeButtonClick();
                }
            };

            this.closeLogsExportSuccessButton = {
                buttonText: this.resourceStrings["DiagnosticsPageCloseButton"],
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
                buttonText: this.resourceStrings["DiagnosticsPageExportLogsButton"],
                buttonType: "button",
                isPrimaryButton: true,
                isVisible: true,
                buttonClickHandler: () => {
                    this.exportLogsButtonClick();
                }
            };

            this.tryExportLogsAgainButton = {
                buttonText: this.resourceStrings["DiagnosticsPageTryAgainButton"],
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
                this.closeButton,
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

            this.getApiOutputAsync();
        }

        getStatusString(status) {
            if (status == 5 || status == 6 || status == 7) {
                return this.STATUS_SUCCESS;
            } else if (status == 1 || status == 2) {
                return this.STATUS_FAILURE;
            } else if (status == 4) {
                return this.STATUS_IN_PROGRESS;
            } else if (status == 3) {
                return this.STATUS_WARNING;
            } else {
                return "";
            }
        }

        getAriaLabel(object) {
            let ariaLabel = "";

            if ('tabName' in object) {
                ariaLabel += object.tabName;
                ariaLabel += this.getStatusString(object.status);
                ariaLabel += this.DETAILS;
            } else if ('categoryName' in object) {
                ariaLabel += object.categoryName;

                if ('items' in object) {
                    for (let i = 0; i < object.items.length; i++) {
                        ariaLabel += " " + object.items[i].propertyName + " " + object.items[i].value;
                    }
                }
            } else if ('eventName' in object) {
                ariaLabel += object.eventName;
                ariaLabel += this.getStatusString(object.status);

                ariaLabel += " " + this.resourceStrings["DiagnosticsPageStartTimeHeading"] + " " + object.startTime;
                ariaLabel += " " + this.resourceStrings["DiagnosticsPageFinishTimeHeading"] + " " + object.finishTime;
                ariaLabel += " " + this.resourceStrings["DiagnosticsPageDetailsHeading"] + " " + object.details;
            } else if ('resourceName' in object) {
                ariaLabel = object.resourceName;
            }

            return ariaLabel;
        }

        setVisibilityStates(object) {
            if ((typeof object === "object") && Array.isArray(object)) {
                for (let i = 0; i < object.length; i++) {
                    object[i] = this.setVisibilityStates(object[i]);
                }

                return object;
            } else if ((typeof object === "object") && !Array.isArray(object)) {
                object.isVisible = ko.observable(false);

                object.ariaLabel = ko.observable(this.getAriaLabel(object));

                for (let key in object) {
                    object[key] = this.setVisibilityStates(object[key]);
                };

                return object;
            } else {
                return object;
            }
        }

        getApiOutputAsync() {
            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_Diagnostics_GetApiOutput_Started");

            this.cachedErrorState = null;

            let diagnosticsManager = new ModernDeployment.Autopilot.Core.DiagnosticAnalysisManager();
            let hasTimedOut = false;

            let timerId = setTimeout(() => {
                hasTimedOut = true;

                this.commercialDiagnosticsUtilities.logHresultEvent(
                    "CommercialOOBE_Diagnostics_GetApiOutput_TimedOut",
                    "Generating diagnostic data took longer than the specified timeout",
                    this.commercialDiagnosticsUtilities.timeoutErrorCode);

                this.autopilotLogger.logAutopilotTelemetryAsync(
                    "DiagnosticAnalysisFramework",
                    "OobeDiagnosticsPage",
                    "PageRendered",
                    "Failure",
                    this.commercialDiagnosticsUtilities.timeoutErrorCode);

                this.displayError(
                    this.BUTTON_SET_DEFAULT,
                    this.commercialDiagnosticsUtilities.timeoutErrorCode,
                    this.resourceStrings["DiagnosticsPageCallingApiTimedOut"]);

                return;
            }, this.PAGE_UNIVERSAL_TIMEOUT_MILLISECONDS);

            diagnosticsManager.generateDiagnosticsAsync("CommercialOOBE").then(
                (output) => {
                    if (hasTimedOut) {
                        return;
                    }
                    clearTimeout(timerId);

                    try {
                        let jsonDiagnosticData = JSON.parse(output.diagnosticResults[ModernDeployment.Autopilot.Core.DiagnosticResultIndices.filteredDiagnosticsDataUnlocalized]);

                        if (this.isLiteWhitePersonality) {
                            this.diagnosticDataTabs(this.setVisibilityStates(jsonDiagnosticData.$schema));
                        } else {
                            this.configurationInfoTab(jsonDiagnosticData.$schema[this.CONFIGURATION_INFO_TAB_INDEX]["categories"]);
                            this.deploymentInfoByCategory(jsonDiagnosticData.$schema[this.DEPLOYMENT_INFO_TAB_INDEX]["categories"]);
                            this.provisionedResourceData(jsonDiagnosticData.$schema[this.APP_AND_POLICY_STATUS_TAB_INDEX]);
                        }

                        this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_Diagnostics_GetApiOutput_Succeeded");
                        this.autopilotLogger.logAutopilotTelemetryAsync(
                            "DiagnosticAnalysisFramework",
                            "OobeDiagnosticsPage",
                            "PageRendered",
                            "Success",
                            0);

                        this.showOnlySpecificRegion(this.shouldShowDiagnosticData);
                    } catch (e) {
                        let errorCode = e.number ? e.number : this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR;

                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                            "CommercialOOBE_Diagnostics_GetApiOutput_Failed",
                            e.message,
                            e);

                        this.autopilotLogger.logAutopilotTelemetryAsync(
                            "DiagnosticAnalysisFramework",
                            "OobeDiagnosticsPage",
                            "PageRendered",
                            "Failure",
                            errorCode);

                        this.displayError(
                            this.BUTTON_SET_DEFAULT,
                            errorCode,
                            this.resourceStrings["DiagnosticsPageParsingApiOutputFailed"]);
                    }
                }, (e) => {
                    if (hasTimedOut) {
                        return;
                    }
                    clearTimeout(timerId);

                    let errorCode = e.number ? e.number : this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR;

                    this.commercialDiagnosticsUtilities.logExceptionEvent(
                        "CommercialOOBE_Diagnostics_GetApiOutput_Failed",
                        "getApiOutputAsync failed",
                        e);

                    this.autopilotLogger.logAutopilotTelemetryAsync(
                        "DiagnosticAnalysisFramework",
                        "OobeDiagnosticsPage",
                        "PageRendered",
                        "Failure",
                        errorCode); 

                    this.displayError(
                        this.BUTTON_SET_DEFAULT,
                        errorCode,
                        this.resourceStrings["DiagnosticsPageCallingApiFailed"]);
                });
        }

        closeButtonClick() {
            return bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", this.DIAGNOSTICS_PREVIOUS_CXID_NAME).then(
                (previousNodeCxid) => {
                    try {
                        this.commercialDiagnosticsUtilities.logInfoEvent(
                            "CommercialOOBE_Diagnostics_CloseButtonPressed",
                            this.commercialDiagnosticsUtilities.formatMessage("Navigating to CXID '{0}'...", previousNodeCxid));

                        return bridge.fireEvent(CloudExperienceHost.Events.done, previousNodeCxid);
                    } catch (e) {
                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                            "CommercialOOBE_Diagnostics_CloseButtonPressed_Failed",
                            this.commercialDiagnosticsUtilities.formatMessage(
                                "Navigating to CXID: {0} in closeButtonClick failed.", 
                                this.DIAGNOSTICS_PREVIOUS_CXID_NAME),
                            e);
                    }   
                }, (e) => {
                    this.commercialDiagnosticsUtilities.logExceptionEvent(
                        "CommercialOOBE_Diagnostics_CloseButtonPressed_PreviousCxidRetrievalFailed",
                        this.commercialDiagnosticsUtilities.formatMessage(
                            "CloudExperienceHost.Storage.SharableData.getValue for CXID: {0} in closeButtonClick failed.", 
                            this.DIAGNOSTICS_PREVIOUS_CXID_NAME),
                        e);
                });
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
            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_Diagnostics_LogsExport_Started");

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
                                "CommercialOOBE_Diagnostics_LogsExport_TimedOut",
                                "Collecting logs took longer than the specified timeout",
                                this.commercialDiagnosticsUtilities.timeoutErrorCode);

                            this.setLogsCollectionError(
                                this.resourceStrings["DiagnosticsPageLogsExportTimeoutMessage"],
                                this.commercialDiagnosticsUtilities.timeoutErrorCode);

                            this.displayError(
                                this.BUTTON_SET_LOGS_EXPORT_FAILURE,
                                this.commercialDiagnosticsUtilities.timeoutErrorCode,
                                this.resourceStrings["DiagnosticsPageLogsExportTimeoutMessageNoErrorCode"],
                                false, // Do not cache this error as it does not affect the primary view.
                                this.resourceStrings["DiagnosticsPageLogsExportFailureSubheader"]);

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

                            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_Diagnostics_LogsExport_Succeeded");
                            this.outputLogPath(outputLogFilePath);

                            if (this.isLiteWhitePersonality) {
                                this.logExportSucceeded(true);
                            } else {
                                this.pageTitle(this.resourceStrings["DiagnosticsPageLogsExportSuccessText"]);
                            }
                        }, (e) => {
                            this.commercialDiagnosticsUtilities.logExceptionEvent(
                                "CommercialOOBE_Diagnostics_LogsExport_Failed",
                                "Diagnostics page collectLogsEx failed.",
                                e);
                            
                            if (hasTimedOut) {
                                return;
                            }
                            clearTimeout(timerId);

                            let code = e.number ? e.number : this.E_DIAGNOSTIC_ANALYSIS_FRAMEWORK_GENERIC_ERROR;

                            this.setLogsCollectionError(
                                this.resourceStrings["DiagnosticsPageLogsExportFailureMessage"],
                                code);

                            this.displayError(
                                this.BUTTON_SET_LOGS_EXPORT_FAILURE,
                                code,
                                this.resourceStrings["DiagnosticsPageLogsExportFailureMessageNoErrorCode"],
                                false, // Do not cache this error as it does not affect the primary view.
                                this.resourceStrings["DiagnosticsPageLogsExportFailureSubheader"]);
                        });
                    });
            }, (e) => {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_Diagnostics_LogsExport_GetFolderPathFailed",
                    "Diagnostics page getExportLogsFolderPathAsync failed, likely due to no USB drive.",
                    e);

                this.displayError(
                    this.BUTTON_SET_LOGS_EXPORT_FAILURE,
                    this.commercialDiagnosticsUtilities.hresultAutopilotLogExportNoDrive,
                    this.resourceStrings["DiagnosticsPageLogsExportFailureNoUsbDriveFoundMessage"],
                    false, // Do not cache this error as it does not affect the primary view.
                    this.resourceStrings["DiagnosticsPageLogsExportFailureSubheader"]);
            });
        }

        closeLogsExportButtonClick() {
            this.commercialDiagnosticsUtilities.logInfoEventName("CommercialOOBE_Diagnostics_LogsExport_CloseButtonPressed");

            this.logExportSucceeded(false);

            if (this.cachedErrorState !== null) {
                this.restoreCachedState();
                this.buttonVisibility(this.BUTTON_SET_DEFAULT);

                bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", "");

                this.showOnlySpecificRegion(this.shouldShowError);
            } else {
                this.showOnlySpecificRegion(this.shouldShowDiagnosticData);
            }
        }

        showOnlySpecificRegion(region) {
            this.pageTitle(this.resourceStrings["DiagnosticsPageTitle"]);

            try {
                if (region !== this.shouldShowError) {
                    bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", this.defaultLottieFile);
                } else {
                    bridge.invoke("CloudExperienceHost.AppFrame.showGraphicAnimation", this.failureLottieFile);
                }

                if (region === this.shouldShowDiagnosticData) {
                    this.buttonVisibility(this.BUTTON_SET_DEFAULT);
                }

                for (let i = 0; i < this.regionVisibilityFlags.length; i++) {
                    (this.regionVisibilityFlags[i])(false);
                }
                region(true);

                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_Diagnostics_ShowOnlySpecificRegion_Succeeded",
                    "Invoked showOnlySpecificRegion successfully.");

            } catch (e) {
                this.commercialDiagnosticsUtilities.logExceptionEvent(
                    "CommercialOOBE_Diagnostics_ShowOnlySpecificRegion_Failed",
                    "showOnlySpecificRegion failed.",
                    e);
            }
        }

        displayError(buttonVisibility, code, description, cacheErrorDetails, subheaderOverride) {
            this.buttonVisibility(buttonVisibility);

            this.errorSubHeader((subheaderOverride === undefined || subheaderOverride === null) ? this.resourceStrings["DiagnosticsPageTryAgainFailureMessage"] : subheaderOverride);

            let errorCode = this.commercialDiagnosticsUtilities.formatMessage(
                this.resourceStrings["DiagnosticsPageErrorCode"], 
                this.commercialDiagnosticsUtilities.formatNumberAsHexString(code, 8));
            this.errorCode(errorCode);

            let errorDescription = this.commercialDiagnosticsUtilities.formatMessage(this.resourceStrings["DiagnosticsPageErrorDescription"], description);
            this.errorDescription(errorDescription);

            this.showOnlySpecificRegion(this.shouldShowError);

            if ((cacheErrorDetails === undefined || cacheErrorDetails === null || cacheErrorDetails)) {
                this.cachedErrorState = {};
                this.cachedErrorState.errorCode = this.errorCode();
                this.cachedErrorState.errorDescription = this.errorDescription();
                this.cachedErrorState.subheaderOverride = this.errorSubHeader();
            }
        }

        restoreCachedState() {
            if (this.cachedErrorState !== undefined || this.cachedErrorState !== null) {
                this.errorCode(this.cachedErrorState.errorCode);
                this.errorDescription(this.cachedErrorState.errorDescription);
                this.errorSubHeader(this.cachedErrorState.subheaderOverride)
            } else {
                this.displayError(
                    this.BUTTON_SET_DEFAULT,
                    this.commercialDiagnosticsUtilities.unexpectedErrorCode,
                    this.resourceStrings["DiagnosticsPageUnexpectedCacheErrorMessage"]);
            }
        }

        onShowDetailsButtonClick(data) {
            this.isVisible(!this.isVisible());

            this.ariaLabel(getAriaLabel(object));
        }
    }

    return TroubleshootingDiagnosticsViewModel;
});
