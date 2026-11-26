
define(['legacy/bridge'], (bridge) => {
    class commercialDiagnosticsUtilities {
        constructor(sessionUtilities) {
            this.unexpectedErrorCode                = 0x8000FFFF; // E_UNEXPECTED
            this.notSupportedErrorCode              = 0x80004021; // CO_E_NOT_SUPPORTED
            this.parameterNotFoundErrorCode         = 0x80020004; // DISP_E_PARAMNOTFOUND
            this.hresultFileExists                  = 0x80070050; // ERROR_FILE_EXISTS
            this.timeoutErrorCode                   = 0x800705B4; // ERROR_TIMEOUT
            this.noInternetErrorCode                = 0x800C0003; // INET_E_NO_SESSION
            this.hresultAutopilotLogExportNoDrive   = 0x81036503; // E_AUTOPILOT_LOG_EXPORT_NO_DRIVE

            this.TROUBLESHOOTING_MODEL_REG_KEY_NAME = "TSM/";
            this.TROUBLESHOOTING_MODEL_STATE_TYPE_START = "start";
            this.TROUBLESHOOTING_MODEL_STATE_TYPE_INFO = "info";
            this.TROUBLESHOOTING_MODEL_STATE_TYPE_END = "end";

            this.EXPORT_LOGS_REMOVABLE_DRIVE_SETTING = "ESP.AutomaticallyExportLogsToRemovableDrive";

            this.sessionUtilities = sessionUtilities;
        }

        logInfoEventWithMetadata(eventName, eventMessage, eventMetadata) {
            bridge.invoke("CloudExperienceHost.AutoPilot.internalLogEvent", eventName, null, eventMessage, eventMetadata);
        }

        logInfoEvent(eventName, eventMessage) {
            this.logInfoEventWithMetadata(eventName, eventMessage, null);
        }

        logInfoEventName(eventName) {
            this.logInfoEvent(eventName, "");
        }

        logErrorEvent(eventName, eventMessage, errorCode) {
            bridge.invoke("CloudExperienceHost.AutoPilot.internalLogEvent", eventName, errorCode, eventMessage, null);
        }

        logHresultEvent(eventName, eventMessage, hresult) {
            bridge.invoke("CloudExperienceHost.AutoPilot.internalLogEvent", eventName, hresult, eventMessage, null);
        }

        logExceptionEventWithMetadata(eventName, exception, eventMessage, eventMetadata) {
            if ((eventMetadata === null) || (eventMetadata === undefined) || (typeof(eventMetadata) !== "object")) {
                eventMetadata = {};
            }

            eventMetadata["stack"] = (exception && exception.asyncOpSource && exception.asyncOpSource.stack) ? exception.asyncOpSource.stack : "";

            bridge.invoke("CloudExperienceHost.AutoPilot.internalLogEvent", eventName, exception.number, eventMessage, eventMetadata);
        }

        logExceptionEvent(eventName, eventMessage, exception) {
            this.logExceptionEventWithMetadata(eventName, exception, eventMessage, null);
        }

        formatMessage(messageToFormat) {
            var args = Array.prototype.slice.call(arguments, 1);
            return messageToFormat.replace(/{(\d+)}/g, (match, number) => {
                return typeof args[number] !== 'undefined'
                    ? args[number]
                    : match
                    ;
            });
        }

        logInfoEventDeprecated() {
            let message = this.formatMessage.apply(this, arguments);

            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", message);
        }

        logErrorEventDeprecated(errorMessage, errorObject) {
            bridge.invoke(
                "CloudExperienceHost.Telemetry.logEvent",
                errorMessage,
                JSON.stringify({
                    number: errorObject && errorObject.number.toString(16),
                    stack: errorObject && errorObject.asyncOpSource && errorObject.asyncOpSource.stack
                }));
        }

        formatNumberAsHexString(numberToConvert, maxHexCharacters) {
            let stringToReturn = "";

            for (var i = 0; i < maxHexCharacters; i++) {
                let digitValue = 0xF & (numberToConvert >> (i * 4));
                stringToReturn = digitValue.toString(16) + stringToReturn;
            }

            return "0x" + stringToReturn;
        }

        getExportLogsFolderPathAsync() {
            this.logInfoEvent("CommercialOOBE_CommercialDiagnosticsUtilities_GetExportLogsFolderPathAsync", "Started");
            return bridge.invoke("CloudExperienceHost.AutoPilot.getStringSettingAsync", this.EXPORT_LOGS_REMOVABLE_DRIVE_SETTING).then((folderPath) => {
                this.logInfoEvent(
                    "CommercialOOBE_CommercialDiagnosticsUtilities_GetExportLogsFolderPathAsync",
                    this.formatMessage("Selected folder path: {0}", folderPath));
                return folderPath;
            });
        }


        async _logTroubleshootingModelCoreAsync(
            stateType,
            processName,
            stateName,
            eventMessage) {
            if (this.sessionUtilities !== undefined) {
                let currentDateTime = new Date();

                let tsmData = {
                    stateType: stateType,
                    processName: processName,
                    stateName: stateName,
                    eventMessage: (eventMessage !== undefined) && (eventMessage != null) ? eventMessage : ""
                };

                await this.sessionUtilities.storeSettingAsync(
                    this.TROUBLESHOOTING_MODEL_REG_KEY_NAME + currentDateTime.toISOString(),
                    JSON.stringify(tsmData));
            }
        }

        _createFullyQualifiedStateName(processName, stateName, extraStateNameDetails) {
            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotDeviceTagging")) {
                let fullyQualifiedStateName = `${processName}.${stateName}`;
                if ((extraStateNameDetails != null) && (extraStateNameDetails != undefined) && (extraStateNameDetails.length > 0)) {
                    fullyQualifiedStateName += `_${extraStateNameDetails}`;
                }

                return fullyQualifiedStateName;
            }
        }

        async logTsmProcessStartAsync(processName, stateName) {
            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotDeviceTagging")) {
                let fullyQualifiedStateName = `${this._createFullyQualifiedStateName(processName, stateName, null)}_Start`;

                await this._logTroubleshootingModelCoreAsync(
                    this.TROUBLESHOOTING_MODEL_STATE_TYPE_START,
                    processName,
                    fullyQualifiedStateName,
                    null
                );

                this.logInfoEvent(
                    fullyQualifiedStateName,
                    `${processName}: ${stateName} is starting`);
            }
        }

        async logTsmProcessEndSuccessAsync(processName, stateName, eventMessage) {
            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotDeviceTagging")) {
                let fullyQualifiedStateName = `${this._createFullyQualifiedStateName(processName, stateName, null)}_End_Success`;

                await this._logTroubleshootingModelCoreAsync(
                    this.TROUBLESHOOTING_MODEL_STATE_TYPE_END,
                    processName,
                    fullyQualifiedStateName,
                    null
                );

                let additionalMessage = ((eventMessage != null) && (eventMessage.length > 0)) ? ` - ${eventMessage}` : "";
                this.logInfoEvent(
                    fullyQualifiedStateName,
                    `${processName}: ${stateName} ended successfully. ${additionalMessage}`);
            }
        }

        async logTsmProcessEndErrorAsync(processName, stateName, extraStateNameDetails, eventMessage, exception) {
            if (CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotDeviceTagging")) {
                let fullyQualifiedStateName = `${this._createFullyQualifiedStateName(processName, stateName, extraStateNameDetails)}_End_Error`;
                await this._logTroubleshootingModelCoreAsync(
                    this.TROUBLESHOOTING_MODEL_STATE_TYPE_END,
                    processName,
                    fullyQualifiedStateName,
                    eventMessage
                );

                let additionalMessage = ((eventMessage != null ) && (eventMessage != undefined)) ? eventMessage : "";
                let formattedEventMessage = `${processName}: ${stateName} ended in failure. ${additionalMessage}`;
                if ((exception === null) || (exception === undefined)) {
                    this.logErrorEvent(
                        fullyQualifiedStateName,
                        formattedEventMessage);
                } else {
                    this.logExceptionEvent(
                        fullyQualifiedStateName,
                        formattedEventMessage,
                        exception);
                }
            }
        }

        async logTroubleshootingModelProcessStartEventAsync(processName, stateName, eventMessage) {
            await this._logTroubleshootingModelCoreAsync(
                this.TROUBLESHOOTING_MODEL_STATE_TYPE_START,
                processName,
                stateName,
                eventMessage);
        }

        async logTroubleshootingModelProcessInfoEventAsync(processName, stateName, eventMessage) {
            await this._logTroubleshootingModelCoreAsync(
                this.TROUBLESHOOTING_MODEL_STATE_TYPE_INFO,
                processName,
                stateName,
                eventMessage);
        }

        async logTroubleshootingModelProcessEndEventAsync(processName, stateName, eventMessage) {
            await this._logTroubleshootingModelCoreAsync(
                this.TROUBLESHOOTING_MODEL_STATE_TYPE_END,
                processName,
                stateName,
                eventMessage);
        }
    }

    return commercialDiagnosticsUtilities;
});
