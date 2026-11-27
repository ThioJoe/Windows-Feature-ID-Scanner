
"use strict";

define(['legacy/bridge'], (bridge) => {
    class bootstrapSessionGeneralUtilities {
        constructor(isInOobe) {
            this.HRESULT_TIMEOUT = 0x800705B4;
            this.SUBCATEGORY_DISPOSITION_VISIBLE = "visible";
            this.SUBCATEGORY_DISPOSITION_SILENT = "silent";
            this.SUBCATEGORY_DISPOSITION_IGNORED = "ignored";
            this.CATEGORY_DISPOSITION_VISIBLE = "visible";
            this.CATEGORY_DISPOSITION_IGNORED = "ignored";

            this.SUBCATEGORY_STATE_NOT_STARTED = "notStarted";
            this.SUBCATEGORY_STATE_IN_PROGRESS = "inProgress";
            this.SUBCATEGORY_STATE_SUCCEEDED = "succeeded";
            this.SUBCATEGORY_STATE_FAILED = "failed";
            this.SUBCATEGORY_STATE_CANCELLED = "cancelled";
            this.SUBCATEGORY_STATE_FAILED_FROM_PREVIOUS_SUBCATEGORY = "failedFromPreviousSubcategory";
            this.SUBCATEGORY_STATE_REBOOT_REQUIRED_AND_TRY_AGAIN = "rebootRequiredAndTryAgain";

            this.CATEGORY_STATE_NOT_STARTED = "notStarted";
            this.CATEGORY_STATE_IN_PROGRESS = "inProgress";
            this.CATEGORY_STATE_SUCCEEDED = "succeeded";
            this.CATEGORY_STATE_FAILED = "failed";
            this.CATEGORY_STATE_CANCELLED = "cancelled";
            this.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY = "failedFromPreviousCategory";
            this.CATEGORY_STATE_REBOOT_REQUIRED_AND_TRY_AGAIN = "rebootRequiredAndTryAgain";

            this.CLICKABLE_ITEM_ID_CONTINUE_ANYWAY_BUTTON = "continueAnywayButton";
            this.CLICKABLE_ITEM_ID_VIEW_DIAGNOSTICS_BUTTON = "viewDiagnosticsButton";
            this.CLICKABLE_ITEM_ID_TRY_AGAIN_BUTTON = "tryAgainButton";
            this.CLICKABLE_ITEM_ID_RESET_BUTTON = "resetButton";
            this.CLICKABLE_ITEM_ID_COLLECT_LOGS_BUTTON = "collectLogsButton";
            this.CLICKABLE_ITEM_ID_SIGN_OUT_BUTTON = "signOutButton";

            this.STATE_NAME_GLOBAL_RUN_PROVISIONING = "Global.RunProvisioning";
            this.STATE_NAME_GLOBAL_RESTORE_MDM_TASKS = "Global.RestoreMdmTasks";
            this.STATE_NAME_GLOBAL_SHOULD_WAIT_FOR_DEBUGGER_ATTACH = "Global.ShouldWaitForDebuggerAttach";

            this.STATE_NAME_GLOBAL_ERROR_BUTTONS_VISIBILITY = "Global.ErrorVisibility";
            this.STATE_NAME_GLOBAL_SHOW_COLLECT_LOGS_BUTTON = "Global.ShowCollectLogsButton";
            this.STATE_NAME_GLOBAL_MDM_PROGRESS_MODE = "Global.MdmProgressMode";
            this.STATE_NAME_GLOBAL_SHOW_CONTINUE_ANYWAY_BUTTON = "Global.ShowContinueAnywayButton";
            this.STATE_NAME_GLOBAL_MDM_ENROLLMENT_STATUS = "Global.MDMEnrollmentStatus";

            this.WHITE_GLOVE_END_TIME_VALUE = "AutopilotWhiteGloveEndTime";
            this.WHITE_GLOVE_RESULT_NAME = "AutopilotWhiteGloveSuccess";
            this.WHITE_GLOVE_RESULT_VALUE_SUCCESS = "Success";
            this.WHITE_GLOVE_ERROR_USER_MESSAGE = "AutopilotWhiteGloveError";

            this.MDM_PROGRESS_MODE_DEVICE = 0;
            this.MDM_PROGRESS_MODE_USER = 1;
            this.MDM_PROGRESS_MODE_DEVICE_AND_USER = 2;

            this.MDM_ENROLLMENT_DISPOSITION = {
                0 : "Unknown",
                1 : "Initial",
                2 : "AadConfigure",
                3 : "AadJoin",
                4 : "AadDeviceDiscovery",
                5 : "AadTicket",
                6 : "MdmEnrolling",
                7 : "Completed",
                8 : "LastKnown",
            };

            this.ESP_COMMANDS_JSON_VALUE_NAME = "EspCommandsJson";

            this.ESP_COMMAND_PROPERTY_NAME_PHASE = "phase";
            this.ESP_COMMAND_PROPERTY_NAME_STATE = "state";
            this.ESP_COMMAND_PROPERTY_NAME_STATE_TRANSITION_WAIT_INTERVAL_IN_MILLISECONDS = "stateTransitionWaitIntervalInMilliseconds";
            this.ESP_COMMAND_PROPERTY_NAME_ACTION_RESULT = "actionResult";

            this.ESP_COMMAND_PHASE_NAME_PREACTION = "preaction";
            this.ESP_COMMAND_PHASE_NAME_POSTACTION = "postaction";

            this.ESP_COMMAND_STATE_PHASE_WAITING_FOR_NEXT_COMMAND = "PhaseWaitingForNextCommand";
            this.ESP_COMMAND_STATE_PHASE_EXITED_SUCCESSFULLY = "PhaseExitedSuccessfully";
            this.ESP_COMMAND_STATE_PHASE_EXITED_WITH_RESULT = "PhaseExitedWithResult";
            this.ESP_COMMAND_STATE_TEST_WAITING_FOR_PHASE_START = "TestWaitingForPhaseStart";
            this.ESP_COMMAND_STATE_TEST_WAITING_FOR_PHASE_TO_EXIT_SUCCESSFULLY = "TestWaitingForPhaseToExitSuccessfully";
            this.ESP_COMMAND_STATE_TEST_WAITING_FOR_PHASE_TO_EXIT_WITH_RESULT = "TestWaitingForPhaseToExitWithResult";

            this.DEFAULT_STATE_TRANSITION_TIME_OUT_IN_MILLISECONDS = 5000; // 5 seconds

            this.AUTOMATION_COMMANDS_JSON_VALUE_NAME = "AutomationCommandsJson";

            this.AUTOMATION_COMMAND_PROPERTY_NAME_PHASE = "phase";
            this.AUTOMATION_COMMAND_PROPERTY_NAME_STATE = "state";
            this.AUTOMATION_COMMAND_PROPERTY_NAME_STATE_TRANSITION_WAIT_INTERVAL_IN_MILLISECONDS = "stateTransitionWaitIntervalInMilliseconds";
            this.AUTOMATION_COMMAND_PROPERTY_NAME_ACTION_RESULT = "actionResult";

            this.AUTOMATION_COMMAND_PHASE_NAME_PREACTION = "preaction";
            this.AUTOMATION_COMMAND_PHASE_NAME_POSTACTION = "postaction";

            this.AUTOMATION_COMMAND_STATE_PHASE_WAITING_FOR_NEXT_COMMAND = "PhaseWaitingForNextCommand";
            this.AUTOMATION_COMMAND_STATE_PHASE_EXITED_SUCCESSFULLY = "PhaseExitedSuccessfully";
            this.AUTOMATION_COMMAND_STATE_PHASE_EXITED_WITH_RESULT = "PhaseExitedWithResult";
            this.AUTOMATION_COMMAND_STATE_TEST_WAITING_FOR_PHASE_START = "TestWaitingForPhaseStart";
            this.AUTOMATION_COMMAND_STATE_TEST_WAITING_FOR_PHASE_TO_EXIT_SUCCESSFULLY = "TestWaitingForPhaseToExitSuccessfully";
            this.AUTOMATION_COMMAND_STATE_TEST_WAITING_FOR_PHASE_TO_EXIT_WITH_RESULT = "TestWaitingForPhaseToExitWithResult";

            this.enrollmentApis = new EnterpriseDeviceManagement.Enrollment.ReflectedEnroller();
            this.autopilotSubscriptionManager = new EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotWnfSubscriptionManager();
            this.tpmNotificationManager = new ModernDeployment.Autopilot.Core.TpmNotification();
            this.autopilotApis = new EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotServer();

            if (CloudExperienceHostAPI.Environment.platform !== 10) { // Holographic 
                this.provisioningPluginManager = new CloudExperienceHostAPI.Provisioning.PluginManager();
            }

            this.espTrackingUtility = new EnterpriseDeviceManagement.Service.AutoPilot.EnrollmentStatusTrackingUtil();
            this.deviceManagementUtilities = new ModernDeployment.Autopilot.Core.DeviceManagementUtilities();
            this.hybridUtilities = new ModernDeployment.Autopilot.Core.AutopilotHybridJoin();

            this.isInOobe = isInOobe;
            this.transientStateStore = {};
        }

        
        showElement(element, collapsible) {
            if (collapsible) {
                element.style.display = "inline";
            } else {
                element.style.visibility = "visible";
            }
        }

        hideElement(element, collapsible) {
            if (collapsible) {
                element.style.display = "none";
            } else {
                element.style.visibility = "hidden";
            }
        }

        isElementHidden(element) {
            return ((element.style.display === "none") || (element.style.visibility === "hidden"));
        }

        clearChildDomNodes(parentDomNode) {
            while (parentDomNode.hasChildNodes()) {
                parentDomNode.removeChild(parentDomNode.childNodes[0]);
            }
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

        formatNumberAsHexString(numberToConvert, maxHexCharacters) {
            let stringToReturn = "";

            for (var i = 0; i < maxHexCharacters; i++) {
                let digitValue = 0xF & (numberToConvert >> (i * 4));
                stringToReturn = digitValue.toString(16) + stringToReturn;
            }

            return "0x" + stringToReturn;
        }

        replaceNodeText(node, newText) {
            this.clearChildDomNodes(node);
            node.appendChild(document.createTextNode(newText));
        }

        logInfoEvent(eventName, eventMessage) {
            bridge.invoke("CloudExperienceHost.AutoPilot.internalLogEvent", eventName, null, eventMessage, null);
        }

        logErrorEvent(eventName, eventMessage, errorCode) {
            bridge.invoke("CloudExperienceHost.AutoPilot.internalLogEvent", eventName, errorCode, eventMessage, null);
        }

        runningInOobe() {
            return this.isInOobe;
        }

        getSettingAsync(stateName) {
            return this.autopilotApis.getSettingAsync(stateName);
        }

        generateUUID() {
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0,
                    v = c === 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
        }

        storeSettingAsync(stateName, stateValue) {
            let storeSettingAction = null;

            try {
                storeSettingAction = this.autopilotApis.storeSettingAsync(stateName, stateValue);
            } catch (e) {
                storeSettingAction = null;
            }

            return storeSettingAction;
        }

        getTransientState(stateName) {
            return this.transientStateStore[stateName];
        }

        storeTransientState(stateName, stateValue) {
            this.transientStateStore[stateName] = stateValue;
        }

        createActionResult(actionResultStateToUse, statusMessageToUse) {
            return {
                actionResultState: actionResultStateToUse,
                statusMessage: statusMessageToUse
            };
        }

        categorySucceeded(categoryState) {
            return (categoryState === this.CATEGORY_STATE_SUCCEEDED);
        }

        subcategorySucceeded(subcategoryState) {
            return (subcategoryState === this.SUBCATEGORY_STATE_SUCCEEDED);
        }

        getEspCommandsJsonAsync() {
            return this.getSettingAsync(this.ESP_COMMANDS_JSON_VALUE_NAME).then((espCommandsJsonString) => {
                if ((espCommandsJsonString !== null) && (espCommandsJsonString.length > 0)) {
                    return WinJS.Promise.as(JSON.parse(espCommandsJsonString));
                }

                return WinJS.Promise.as({});
            });
        }

        storeEspCommandsJsonAsync(espCommandsJson) {
            return this.storeSettingAsync(this.ESP_COMMANDS_JSON_VALUE_NAME, JSON.stringify(espCommandsJson));
        }

        storeEspCommandsJsonWithNewStateAsync(espCommandsJson, subcategoryId, targetPhase, state) {
            espCommandsJson[subcategoryId][targetPhase][this.ESP_COMMAND_PROPERTY_NAME_STATE] = state;

            return this.storeEspCommandsJsonAsync(espCommandsJson);
        }

        signalBitlockerProvisioningComplete(reasonCode) {
            let autopilotBitlockerDeferral = CloudExperienceHostAPI.FeatureStaging.isOobeFeatureEnabled("AutopilotBitlockerOobeDeferral");
            if (autopilotBitlockerDeferral) {
                try {      
                    this.logInfoEvent("CommercialOOBE_BitlockerDeferral_Started", `Autopilot Bitlocker deferral release signaling started for '${reasonCode}'`);
                    ModernDeployment.Autopilot.Core.AutopilotWnfNotificationManagerStatics.setBitlockerDeferralComplete(reasonCode);
                    this.logInfoEvent("CommercialOOBE_BitlockerDeferral_Success", "Autopilot Bitlocker deferral release signaling succeeded");
                } catch (err) {
                    this.logErrorEvent(
                        "CommercialOOBE_BitlockerDeferral_Failed", 
                        `Autopilot failed to set the BitLocker deferral policy. Error: ${err.message}, Name: ${err.name}, Stack: ${err.stack}`);
                }
            }
        }

        runPhaseStateMachineAsync(
            subcategoryId,
            targetPhase,
            waitTimeInMilliseconds,
            asyncActionToRunOnSuccessfulPhaseExit,
            asyncActionToRunOnExitWithResult) {
            return WinJS.Promise.timeout(waitTimeInMilliseconds).then(() => {
                return this.getEspCommandsJsonAsync();

            }).then((espCommandsJson) => {
                let subcategoryCommand = espCommandsJson[subcategoryId];
                let nextStep = WinJS.Promise.as(true);

                if ((subcategoryCommand !== undefined) &&
                    (subcategoryCommand[targetPhase] !== undefined) &&
                    (subcategoryCommand[targetPhase][this.ESP_COMMAND_PROPERTY_NAME_STATE] !== this.ESP_COMMAND_STATE_PHASE_WAITING_FOR_NEXT_COMMAND)) {

                    switch (subcategoryCommand[targetPhase][this.ESP_COMMAND_PROPERTY_NAME_STATE]) {
                        case this.ESP_COMMAND_STATE_TEST_WAITING_FOR_PHASE_TO_EXIT_SUCCESSFULLY:
                            return this.storeEspCommandsJsonWithNewStateAsync(espCommandsJson, subcategoryId, targetPhase, this.ESP_COMMAND_STATE_PHASE_EXITED_SUCCESSFULLY).then(() => {
                                return asyncActionToRunOnSuccessfulPhaseExit();
                            });

                        case this.ESP_COMMAND_STATE_TEST_WAITING_FOR_PHASE_TO_EXIT_WITH_RESULT:
                            let overridenActionResult = subcategoryCommand[targetPhase][this.ESP_COMMAND_PROPERTY_NAME_ACTION_RESULT];

                            return asyncActionToRunOnExitWithResult(overridenActionResult).then(() => {
                                return this.storeEspCommandsJsonWithNewStateAsync(espCommandsJson, subcategoryId, targetPhase, this.ESP_COMMAND_STATE_PHASE_EXITED_WITH_RESULT)
                            });
                    }

                    nextStep = this.storeEspCommandsJsonWithNewStateAsync(espCommandsJson, subcategoryId, targetPhase, this.ESP_COMMAND_STATE_PHASE_WAITING_FOR_NEXT_COMMAND);
                }

                return nextStep.then(() => {
                    return this.runPhaseStateMachineAsync(
                        subcategoryId,
                        targetPhase,
                        waitTimeInMilliseconds,
                        asyncActionToRunOnSuccessfulPhaseExit,
                        asyncActionToRunOnExitWithResult);
                });
            });
        }

        startPhaseStateMachineAsync(subcategoryId, targetPhase, asyncActionToRunOnSuccessfulPhaseExit, asyncActionToRunOnExitWithResult) {
            return this.getEspCommandsJsonAsync().then((espCommandsJson) => {
                let subcategoryCommand = espCommandsJson[subcategoryId];

                if ((subcategoryCommand !== undefined) &&
                    (subcategoryCommand[targetPhase] !== undefined) &&
                    (subcategoryCommand[targetPhase][this.ESP_COMMAND_PROPERTY_NAME_STATE] === this.ESP_COMMAND_STATE_TEST_WAITING_FOR_PHASE_START)) {

                    let waitTimeInMilliseconds = subcategoryCommand[targetPhase][this.ESP_COMMAND_PROPERTY_NAME_STATE_TRANSITION_WAIT_INTERVAL_IN_MILLISECONDS];
                    if (undefined === waitTimeInMilliseconds) {
                        waitTimeInMilliseconds = this.DEFAULT_STATE_TRANSITION_TIME_OUT_IN_MILLISECONDS;
                    }

                    return this.storeEspCommandsJsonWithNewStateAsync(espCommandsJson, subcategoryId, targetPhase, this.ESP_COMMAND_STATE_PHASE_WAITING_FOR_NEXT_COMMAND).then(() => {
                        return this.runPhaseStateMachineAsync(
                            subcategoryId,
                            targetPhase,
                            waitTimeInMilliseconds,
                            asyncActionToRunOnSuccessfulPhaseExit,
                            asyncActionToRunOnExitWithResult
                        );
                    });
                }

                return asyncActionToRunOnSuccessfulPhaseExit();
            });
        }

    }

    return bootstrapSessionGeneralUtilities;
});
