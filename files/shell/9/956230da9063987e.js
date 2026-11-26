define(['lib/knockout', 'legacy/bridge', 'legacy/events', 'legacy/core', 'winjs/ui'], (ko, bridge, constants, core) => {
    class ConfirmDialogManager {
        constructor(confirmDialogElement) {
            this.currentAfterHideHandler = null;
            this.confirmDialogElement = confirmDialogElement;
            this.confirmDialogWinControl = null;
        }

        show(title, description, primarybutton, secondarybutton, afterHideHandler) {
            if (this.confirmDialogWinControl) {
                if (!this.confirmDialogWinControl.hidden) {
                    return;
                }

                if (this.currentAfterHideHandler) {
                    this.confirmDialogWinControl.removeEventListener("afterhide", this.currentAfterHideHandler);
                    this.currentAfterHideHandler = null;
                }
                this.confirmDialogWinControl.dispose();
                this.confirmDialogElement.winControl = null;
            }

            this.confirmDialogElement.textContent = description ? description : "";
            WinJS.UI.process(this.confirmDialogElement).then(() => {
                this.confirmDialogWinControl = this.confirmDialogElement.winControl;
                this.confirmDialogWinControl.title = title;
                this.confirmDialogWinControl.primaryCommandText = primarybutton;
                this.confirmDialogWinControl.secondaryCommandText = secondarybutton;
                this.confirmDialogWinControl.addEventListener("afterhide", afterHideHandler);
                this.currentAfterHideHandler = afterHideHandler;

                this.confirmDialogWinControl.show();
            });
        }
    }

    class ProvisioningStatusViewModel {
        constructor(resourceStrings, oobeProvisioningResults, showEjectMediaMessage) {
            this.componentName = ko.observable();
            this.provResults = ko.observableArray();
            this.doneFired = false;
            this.pluginManager = new CloudExperienceHostAPI.Provisioning.PluginManager();
            this.isResumed = oobeProvisioningResults.isResumed;
            this.sourceOverride = oobeProvisioningResults.sourceOverride;
            this.minProgressTextTime = 7000;   // in ms
            this.pollingInterval = 500; // in ms
            this.promisePollingResults = null;
            this.stopPollingResults = false;
            this.promisePollingAppList = null;
            this.disableRemediationButtons = ko.observable();
            this.disableRetryButton = ko.observable();
            this.signalNoStagedResults = ko.observable();
            this.signalNoStagedResults(false);
            this.signalForceCompletion = ko.observable();
            this.signalForceCompletion(false);
            this.promiseWaitForNoStagedResults = this.createPromiseWaitForNoStagedResults();
            this.appDisplayNameList = {};
            this.hotKeyEnabled = ko.observable();
            this.confirmDialogManager = new ConfirmDialogManager(document.getElementById("provCommonConfirmDlg"));
            let titleStrings = {};
            let subHeaderTitleStrings = {};
            let flexStartHyperLinksSets = {};
            let flexEndButtonsSets = {};

            this.resourceStrings = resourceStrings;

            titleStrings["main"] = resourceStrings.ProvisioningStatusTitleAlreadyStarted;
            titleStrings["errorReport"] = resourceStrings.ProvisioningStatusTitle;

            subHeaderTitleStrings["main"] = showEjectMediaMessage ? resourceStrings.ProvisioningSafeToEject : "";
            subHeaderTitleStrings["errorReport"] = "";

            flexStartHyperLinksSets["main"] = [];
            flexStartHyperLinksSets["errorReport"] = [
                {
                    hyperlinkText: resourceStrings.ProvisioningStatusContinueButtonText,
                    disableControl: ko.pureComputed(() => {
                        return this.disableRemediationButtons();
                    }),
                    handler: () => {
                        this.onContinue();
                    }
                }
            ];

            flexEndButtonsSets["main"] = [];
            flexEndButtonsSets["errorReport"] = [
                {
                    buttonText: resourceStrings.ProvisioningStatusResetPCButtonText,
                    buttonType: "button",
                    isPrimaryButton: true,
                    disableControl: ko.pureComputed(() => {
                        return this.disableRemediationButtons();
                    }),
                    buttonClickHandler: () => {
                        this.onReset();
                    }
                },
                {
                    buttonText: resourceStrings.ProvisioningStatusRetryButtonText,
                    buttonType: "button",
                    isPrimaryButton: true,
                    disableControl: ko.pureComputed(() => {
                        return this.disableRemediationButtons() || this.disableRetryButton();
                    }),
                    buttonClickHandler: () => {
                        this.onRetry();
                    }
                },
            ];

            this.title = ko.pureComputed(() => {
                return titleStrings[this.componentName()];
            });

            this.subHeaderText = ko.pureComputed(() => {
                return subHeaderTitleStrings[this.componentName()];
            });

            this.flexStartHyperLinks = ko.pureComputed(() => {
                return flexStartHyperLinksSets[this.componentName()];
            });

            this.flexEndButtons = ko.pureComputed(() => {
                return flexEndButtonsSets[this.componentName()];
            });

            this.getLogsText = resourceStrings.ProvisioningStatusGetLogsButtonText;

            this.componentName.subscribe((newValue) => {
                this.setupVoiceOverAndSpeechRecognition(newValue);
            });

            this.componentName("main");
            this.disableRemediationButtons(true);
            this.disableRetryButton(true);
            this.hotKeyEnabled(true);

            if (this.sourceOverride) {
                this.pluginManager.setSourceOverride(this.sourceOverride);
            }
        }

        setupVoiceOverAndSpeechRecognition(componentName) {
            try {
                CloudExperienceHostAPI.Speech.SpeechRecognition.stop();
                let continueConstraint = new Windows.Media.SpeechRecognition.SpeechRecognitionListConstraint(new Array(this.resourceStrings.ProvisioningStatusContinueButtonText));
                continueConstraint.tag = "continue";
                let retryConstraint = new Windows.Media.SpeechRecognition.SpeechRecognitionListConstraint(new Array(this.resourceStrings.ProvisioningStatusRetryButtonText));
                retryConstraint.tag = "retry";
                let constraintsSets = {};
                let voiceOverSets = {};

                voiceOverSets["errorReport"] = this.resourceStrings.ProvisioningStatusVoiceOver;

                constraintsSets["errorReport"] = [continueConstraint, retryConstraint];

                if (componentName in voiceOverSets) {
                    CloudExperienceHostAPI.Speech.SpeechRecognition.promptForCommandsAsync(voiceOverSets[componentName], constraintsSets[componentName]).done((result) => {
                        if (result) {
                            if (result.constraint.tag == continueConstraint.tag) {
                                this.onContinue();
                            } else if (result.constraint.tag == retryConstraint.tag) {
                                this.onRetry();
                            }
                        }
                    });
                }
            }
            catch (error) {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "SpeechRecognitionSetupError",
                    JSON.stringify(new core.WinRtErrorWrapper(error)));
            }
        }

        checkOrExitErrorReport() {
            this.stopPollingResults = true;

            let commandResults = {};

            WinJS.Promise.join({ promisePollingResults: this.promisePollingResults }).then(() => {
                return this.pluginManager.getLastProvisioningCommandResultsAsync();
            })
            .then((results) => {
                commandResults = results;

                return this.pluginManager.getLastProvisioningResultsAsync();
            })
            .then((results) => {
                if (results.length == 0) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningProceededSuccessfully",
                        JSON.stringify(
                        {
                            sourceOverride: this.sourceOverride
                        }));
                    this.onExitErrorReport();
                    return;
                }

                let anyError = false;
                results.forEach((currentResult) => {
                    if (currentResult.hasError) {
                        anyError = true;
                    }
                });

                if (this.signalForceCompletion()) {
                    anyError = true;
                }

                if (!anyError) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningProceededSuccessfully",
                        JSON.stringify(
                        {
                            sourceOverride: this.sourceOverride
                        }));
                    this.pluginManager.onProvisioningCompletedAsync(this.resourceStrings.ProvisioningSuccessfulMessage).then(() => {
                        this.onExitErrorReport();
                    })
                    .done(null, (error) => {
                        this.onExitErrorReport();
                    });
                    return;
                }

                this.componentName("errorReport");
                this.updateProvisioningResults(results);
                this.updateProvisioningCommandsResults(commandResults);
                this.disableRemediationButtons(false);
                this.disableRetryButton(this.signalForceCompletion());

                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningShowErrorReport",
                    JSON.stringify(
                    {
                        forceCompletion: this.signalForceCompletion(),
                        sourceOverride: this.sourceOverride
                    }));
            })
            .done(null, (error) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningCheckErrorReportOrExitError", core.GetJsonFromError(error));
                this.onExitErrorReport();
            });
        }

        onContinue() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningContinueAnywayStart").then(() => {
                this.confirmDialogManager.show(
                    this.resourceStrings.ContinueConfirmationDialogTitle,
                    this.resourceStrings.ContinueConfirmationDialogDescription,
                    this.resourceStrings.ContinueConfirmationDialogCommandContinue,
                    this.resourceStrings.ContinueConfirmationDialogCommandCancel,
                    this.onContinueConfirmCheck.bind(this));
            });
        }

        onContinueConfirmCheck(eventInfo) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningContinueAnywayCompleted", JSON.stringify({ result: eventInfo.detail.result }));

            if (eventInfo.detail.result != WinJS.UI.ContentDialog.DismissalResult.primary) {
                return;
            }

            if (this.doneFired) {
                return;
            }

            this.doneFired = true;
            bridge.fireEvent(constants.Events.done, constants.AppResult.action1);
        }

        onExitErrorReport() {
            if (this.doneFired) {
                return;
            }

            this.doneFired = true;

            let shouldSkipOobe = this.pluginManager.getSkipOobeValue();

            if (shouldSkipOobe) {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningCommitSkipOobe");
                bridge.fireEvent(constants.Events.done, constants.AppResult.exitCxhSuccess);
            } else {
                bridge.fireEvent(constants.Events.done, constants.AppResult.success);
            }
        }

        onGetLogs() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningGetLogsStart").then(() => {
                return bridge.invoke("CloudExperienceHost.showFolderPicker");
            })
            .then((folderPath) => {
                return this.pluginManager.exportDiagEvtLogAsync(folderPath);
            })
            .then(() => {
                return bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningGetLogsCompleted");
            })
            .then(null, (error) => {
                return bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningGetLogsError", core.GetJsonFromError(error));
            });
        }

        onRetry() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningRetry", JSON.stringify({ sourceOverride: this.sourceOverride}));

            if (this.doneFired) {
                return;
            }

            this.doneFired = true;
            bridge.invoke("CloudExperienceHost.Storage.SharableData.addValue", "OobeProvisioningSourceOverride", "OOBE_RETRY");
            bridge.fireEvent(constants.Events.done, constants.AppResult.action2);
        }

        ready() {
            let promiseSet = {
                promiseMinProgressTextTime: WinJS.Promise.timeout(this.minProgressTextTime),
                promiseWaitForNoStagedResults: this.promiseWaitForNoStagedResults
            };

            if (!this.isResumed) {
                promiseSet.promiseApplyProvisioning = this.pluginManager.applyAcquiredPackageAsync();
            } else {
                promiseSet.promiseApplyProvisioning = this.pluginManager.applyAfterConnectivityPackagesAsync();
            }

            this.promisePollingResults = this.createPromisePollingResults();
            this.promisePollingAppList = this.createPromiseAppList();

            this.onExitProvisioningFlow(promiseSet);
        }

        onExitProvisioningFlow(promiseSet) {
            let internalPromiseSet = {};
            internalPromiseSet.promiseWaitForForceCompletion = new WinJS.Promise((onComplete, onError) => {
                try {
                    this.signalForceCompletion.subscribe((newValue) => {
                        if (newValue == true) {
                            onComplete(true);
                        }
                    });
                }
                catch (err) {
                    onError(err);
                }
            });

            internalPromiseSet.promiseWaitForNormalProvisioning =
            WinJS.Promise.join(promiseSet).then((resultSet) => {
                bridge.invoke("CloudExperienceHost.Storage.SharableData.addValue", "hasProvisionedThisSession", true);

                if (this.pluginManager.isRebootRequired()) {
                    bridge.invoke("CloudExperienceHost.Storage.SharableData.addValue", "OobeProvisioningResumeContinuation", true);
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningCommitRebootRequired");
                    bridge.invoke("CloudExperienceHost.setRebootForOOBE", "OobeProvisioningStatus");
                    bridge.fireEvent(constants.Events.done, constants.AppResult.action3);
                }
                else if (!this.isResumed) {
                    bridge.invoke("CloudExperienceHost.Storage.SharableData.addValue", "OobeProvisioningResumeContinuation", true);
                    bridge.fireEvent(constants.Events.done, constants.AppResult.action2);
                }
                else {
                    bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.enterpriseProvisioningCensusResult, 0);
                    return true;
                }

                return false;
            })
            .then(null, (error) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", this.isResumed ? "oobeProvisioningTurn3Failed" : "oobeProvisioningTurn2Failed", core.GetJsonFromError(error));
                bridge.invoke("CloudExperienceHost.Telemetry.oobeHealthEvent", CloudExperienceHostAPI.HealthEvent.enterpriseProvisioningCensusResult, error.number ? error.number : 0x8000ffff);
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);

                return false;
            });

            WinJS.Promise.any(internalPromiseSet).then((result) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningOnExitReason", result.key);

                this.hotKeyEnabled(false);
                return result.value;
            })
            .then((result) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningCheckErrorReportOrExit", result);
                if (result) {
                    this.checkOrExitErrorReport();
                }
            });
        }

        createPromisePollingResults() {
            if (this.stopPollingResults) {
                return WinJS.Promise.as(true);
            }

            let provDataResult = {};

            return this.pluginManager.getLastProvisioningResultsAsync().then((results) => {
                provDataResult = results;
                this.checkAndSignalNoStagedResults(results);

                return this.pluginManager.getLastProvisioningCommandResultsAsync();
            })
            .then((results) => {
                this.updateProvisioningResults(provDataResult);
                this.updateProvisioningCommandsResults(results);

                return WinJS.Promise.timeout(this.pollingInterval);
            })
            .then(() => {
                return this.createPromisePollingResults();
            })
            .then(null, (error) => {
                return WinJS.Promise.timeout(this.pollingInterval);
            })
            .then(() => {
                return this.createPromisePollingResults();
            });
        }

        updateProvisioningResults(results) {
            this.provResults.removeAll();

            let completionStateByGroup = {};
            let errorStateByGroup = {};
            results.forEach((currentResult) => {
                let index = currentResult.categoryId;

                if (currentResult.userNamedChildNode) {
                    index = currentResult.userNamedChildNode;
                }

                if (!completionStateByGroup[index]) {
                    completionStateByGroup[index] = [];
                }

                completionStateByGroup[index].push(currentResult.completionState);

                if (!errorStateByGroup[index]) {
                    errorStateByGroup[index] = false;
                }

                if (currentResult.hasError) {
                    errorStateByGroup[index] = currentResult.hasError;
                }
            });

            let shownStateByGroup = {};
            for (var key in completionStateByGroup) {
                shownStateByGroup[key] = "Completed";

                completionStateByGroup[key].forEach((currentResult) => {
                    if (currentResult != "Completed") {
                        shownStateByGroup[key] = "Running"
                    }
                });
            }

            for (var key in shownStateByGroup) {
                let currentResult = {};

                currentResult.hasError = ko.observable();
                currentResult.hasError(false);

                currentResult.contentCategory = key;
                if (this.resourceStrings["ContentCategory" + key]) {
                    currentResult.contentCategory = this.resourceStrings["ContentCategory" + key];
                }

                if (this.appDisplayNameList[key]) {
                    currentResult.contentCategory = this.appDisplayNameList[key].displayName;
                }

                currentResult.isRunning = (shownStateByGroup[key] == "Running");
                currentResult.localizedCompletionState = "";
                if (this.resourceStrings["CompletitonState" + shownStateByGroup[key]]){
                    currentResult.localizedCompletionState = this.resourceStrings["CompletitonState" + shownStateByGroup[key]];
                }

                if (errorStateByGroup[key]) {
                    currentResult.hasError(true);
                    currentResult.localizedCompletionState = this.resourceStrings["CompletitonStateFailed"];
                }

                let categoryNotShown = ["Provisioning", "Reboot", "InitialCustomization"];
                if ((categoryNotShown.indexOf(key) != -1) && (!currentResult.hasError())) {
                    continue;
                }

                this.provResults.push(currentResult);
            }
        }

        updateProvisioningCommandsResults(results) {
            results.forEach((currentResult) => {
                let newResult = {};

                newResult.hasError = ko.observable();

                newResult.contentCategory = this.resourceStrings["ContentCategoryScripts"];
                newResult.contentCategory += " (" + currentResult.name + ")";

                newResult.localizedCompletionState = this.resourceStrings["CompletitonState" + currentResult.completionState];
                newResult.isRunning = (currentResult.completionState == "Staged");
                newResult.hasError(currentResult.completionState == "Failed");

                this.provResults.push(newResult);
            });
        }

        checkAndSignalNoStagedResults(results) {
            let anyStaged = false;
            let anyNotStarted = false;
            let anyError = false;

            results.forEach((currentResult) => {
                if (currentResult.completionState == "Staged") {
                    anyStaged = true;
                }
                else if (currentResult.completionState == "NotStarted") {
                    anyNotStarted = true;
                }
                else if (currentResult.hasError) {
                    anyError = true;
                }
            });

            if (!anyStaged && (!anyNotStarted || anyError || this.pluginManager.isRebootRequired())) {
                this.signalNoStagedResults(true);
            }
        }

        createPromiseWaitForNoStagedResults() {
            return new WinJS.Promise((onComplete, onError) => {
                try {
                    this.signalNoStagedResults.subscribe((newValue) => {
                        if (newValue == true) {
                            onComplete();
                        }
                    });
                }
                catch (err) {
                    onError(err);
                }
            });
        }

        createPromiseAppList() {
            if (this.stopPollingResults) {
                return WinJS.Promise.as(true);
            }

            return this.pluginManager.findAppPackagesAsync().then((results) => {
                this.appDisplayNameList = results;
                return WinJS.Promise.timeout(this.pollingInterval);
            })
            .then(() => {
                return this.createPromiseAppList();
            })
            .then(null, (error) => {
                return WinJS.Promise.timeout(this.pollingInterval);
            })
            .then(() => {
                return this.createPromiseAppList();
            });
        }

        handleHotKey(ev) {
            if (ev.keyCode != 27) {
                return;
            }

            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningEscapeConfirmStart").then(() => {
                this.confirmDialogManager.show(
                    this.resourceStrings.EscapeConfirmationDialogTitle,
                    null,
                    this.resourceStrings.ConfirmationDialogCommandYes,
                    this.resourceStrings.ConfirmationDialogCommandNo,
                    this.onEscapeConfirmCheck.bind(this));
            });
        }

        onEscapeConfirmCheck(eventInfo) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningEscapeConfirmCompleted", JSON.stringify({ result: eventInfo.detail.result }));

            if (eventInfo.detail.result != WinJS.UI.ContentDialog.DismissalResult.primary) {
                return;
            }

            this.signalForceCompletion(true);
        }

        onReset() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningResetConfirmStart").then(() => {
                this.confirmDialogManager.show(
                    this.resourceStrings.ResetConfirmationDialogTitle,
                    null,
                    this.resourceStrings.ConfirmationDialogCommandYes,
                    this.resourceStrings.ConfirmationDialogCommandNo,
                    this.onResetConfirmCheck.bind(this));
            });
        }

        onResetConfirmCheck(eventInfo) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningResetConfirmCompleted", JSON.stringify({ result: eventInfo.detail.result }));

            if (eventInfo.detail.result != WinJS.UI.ContentDialog.DismissalResult.primary) {
                return;
            }

            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningSystemResetStart").then(() => {
                return this.pluginManager.initiateSystemResetAsync();
            })
            .then(() => {
                return bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningSystemResetCompleted");
            })
            .then(null, (error) => {
                return bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeProvisioningSystemResetError", core.GetJsonFromError(error));
            });
        }
    }

    ko.bindingHandlers.oobeProvHotKeys = {
        update: function (element, valueAccessor) {
            let supportHotKeys = ko.unwrap(valueAccessor());
            if (supportHotKeys) {
                let vm = ko.dataFor(element);
                element.hotkeyDownHandler = vm.handleHotKey.bind(vm);
                element.addEventListener("keydown", element.hotkeyDownHandler);
            }
            else if (element.hotkeyDownHandler) {
                element.removeEventListener("keydown", element.hotkeyDownHandler);
                element.hotkeyDownHandler = null;
            }
        }
    };

    return ProvisioningStatusViewModel;
});
